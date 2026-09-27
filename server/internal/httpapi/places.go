/**
 * 位置管理（手机端）：工作区列表（含内置「此电脑」与默认工作目录）、用文件夹选择器添加或删除工作区、
 * 更换默认工作目录，查看与更换电脑上的收件目录。
 */
package httpapi

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** wsView：手机上看到的工作区 */
type wsView struct {
	store.Workspace
	IsDefault bool `json:"isDefault"`
	System    bool `json:"system"`
	// Home：「此电脑」中用户个人文件夹的相对路径，打开时默认定位到这里
	Home string `json:"home,omitempty"`
}

/** computerRel：电脑上的绝对路径转为「此电脑」中的相对路径 */
func computerRel(abs string) string {
	root := filepath.ToSlash(store.ComputerRoot())
	return strings.TrimPrefix(strings.TrimPrefix(filepath.ToSlash(abs), root), "/")
}

/**
 * workspaces：工作区列表
 *
 * 处理流程：
 * 1、第一个是「此电脑」，带上个人文件夹位置
 * 2、其余为已登记的工作区，标出默认工作目录并排在前面
 */
func (s *Server) workspaces(w http.ResponseWriter, r *http.Request) {
	list, err := s.Store.Workspaces(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、此电脑
	home, _ := os.UserHomeDir()
	out := []wsView{{Workspace: store.Computer(), System: true, Home: computerRel(home)}}
	// 2、登记的工作区
	def := filepath.Clean(s.Cfg.Get().DefaultWorkspace)
	var rest []wsView
	for _, x := range list {
		v := wsView{Workspace: x, IsDefault: filepath.Clean(x.RootPath) == def}
		if v.IsDefault {
			out = append(out, v)
		} else {
			rest = append(rest, v)
		}
	}
	writeJSON(w, 200, append(out, rest...))
}

/** dirOf：请求中的目录须为电脑上已存在的文件夹 */
func dirOf(p string) (string, error) {
	p = strings.TrimSpace(p)
	if p == "" || !filepath.IsAbs(p) {
		return "", errf(400, "bad_path", "请选择电脑上的文件夹")
	}
	p = filepath.Clean(p)
	info, err := os.Stat(p)
	if err != nil || !info.IsDir() {
		return "", errf(400, "not_dir", "文件夹不存在")
	}
	return p, nil
}

/**
 * addWorkspace：把电脑上的文件夹添加为工作区
 *
 * 处理流程：
 * 1、校验文件夹，已登记过时直接返回
 * 2、名称默认取文件夹名，重名时加序号
 */
func (s *Server) addWorkspace(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Path string `json:"path"`
		Name string `json:"name"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、文件夹
	p, err := dirOf(in.Path)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	list, err := s.Store.Workspaces(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	for _, x := range list {
		if filepath.Clean(x.RootPath) == p {
			writeJSON(w, 200, x)
			return
		}
	}
	// 2、名称
	base := strings.TrimSpace(in.Name)
	if base == "" {
		base = filepath.Base(p)
	}
	ws := store.Workspace{ID: security.NewID()[:12], Name: base, RootPath: p}
	for i := 2; ; i++ {
		err = s.Store.SaveWorkspace(r.Context(), ws)
		if !errors.Is(err, store.ErrDuplicate) || i > 99 {
			break
		}
		ws.Name = fmt.Sprintf("%s %d", base, i)
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "workspace.add", map[string]string{"path": p})
	writeJSON(w, 201, ws)
}

/** removeWorkspace：移除工作区（只移除登记，不动文件）；「此电脑」与默认工作目录不能移除 */
func (s *Server) removeWorkspace(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	ws, err := s.Store.Workspace(r.Context(), id)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if id == store.ComputerID || filepath.Clean(ws.RootPath) == filepath.Clean(s.Cfg.Get().DefaultWorkspace) {
		writeErr(w, r, errf(400, "protected", "此电脑与默认工作目录不能移除"))
		return
	}
	if err := s.Store.DeleteWorkspace(r.Context(), id); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "workspace.remove", map[string]string{"path": ws.RootPath})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** setDefaultWorkspace：更换默认工作目录，收件目录原本跟随默认工作目录时一起更换 */
func (s *Server) setDefaultWorkspace(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Path string `json:"path"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	p, err := dirOf(in.Path)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if _, err := s.Cfg.Update(func(c *config.Config) {
		if filepath.Clean(c.Transfer.InboxDir) == filepath.Clean(c.DefaultWorkspace) {
			c.Transfer.InboxDir = p
		}
		c.DefaultWorkspace = p
	}); err != nil {
		writeErr(w, r, err)
		return
	}
	ws, err := s.Store.EnsureDefault(r.Context(), p, security.NewID()[:12])
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "workspace.default", map[string]string{"path": p})
	writeJSON(w, 200, ws)
}

/** dirsView：电脑上的收发目录与默认工作目录 */
func (s *Server) dirsView() map[string]string {
	c := s.Cfg.Get()
	return map[string]string{"inboxDir": c.Transfer.InboxDir, "defaultWorkspace": c.DefaultWorkspace}
}

/** dirs：查看电脑上的收件目录与默认工作目录 */
func (s *Server) dirs(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.dirsView())
}

/**
 * setDirs：更换收件目录，立即生效
 *
 * 处理流程：
 * 1、目录不存在时创建
 * 2、写入配置
 */
func (s *Server) setDirs(w http.ResponseWriter, r *http.Request) {
	var in struct {
		InboxDir  *string `json:"inboxDir"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、目录
	for _, p := range []*string{in.InboxDir} {
		if p == nil {
			continue
		}
		if !filepath.IsAbs(*p) {
			writeErr(w, r, errf(400, "bad_path", "请选择电脑上的文件夹"))
			return
		}
		*p = filepath.Clean(*p)
		if err := os.MkdirAll(*p, 0o755); err != nil {
			writeErr(w, r, err)
			return
		}
	}
	// 2、生效
	if _, err := s.Cfg.Update(func(c *config.Config) {
		if in.InboxDir != nil {
			c.Transfer.InboxDir = *in.InboxDir
		}
	}); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "transfer.dirs", s.dirsView())
	writeJSON(w, 200, s.dirsView())
}
