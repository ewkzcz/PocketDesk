/**
 * 工作区文件接口：列目录、读取（支持 Range）、带 If-Match 保存、文件操作与搜索。
 */
package httpapi

import (
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** maxSaveBytes：单次保存的最大字节数 */
const maxSaveBytes = 512 << 20

/** wsOf：路径参数中的工作区 */
func (s *Server) wsOf(r *http.Request) (store.Workspace, error) {
	return s.Store.Workspace(r.Context(), r.PathValue("id"))
}

/** list：列目录 */
func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	ws, err := s.wsOf(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	q := r.URL.Query()
	entries, err := workspace.List(ws.RootPath, q.Get("path"), workspace.ListOptions{Sort: q.Get("sort"), Desc: q.Get("order") == "desc", ShowHidden: q.Get("hidden") == "1"})
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"entries": entries, "readOnly": ws.ReadOnly})
}

/**
 * readFile：读取或下载文件
 *
 * 处理流程：
 * 1、解析路径并确认是文件
 * 2、设置 ETag，交给 ServeContent 处理 Range、If-Range 与条件请求
 * 3、记录审计并维持防休眠
 */
func (s *Server) readFile(w http.ResponseWriter, r *http.Request) {
	// 1、路径
	ws, err := s.wsOf(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	abs, err := workspace.Resolve(ws.RootPath, r.URL.Query().Get("path"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	f, err := os.Open(abs)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if info.IsDir() {
		writeErr(w, r, workspace.ErrIsDir)
		return
	}
	// 2、输出
	serveFile(w, r, f, info, filepath.Base(abs))
	// 3、审计
	if r.Method == http.MethodGet {
		if s.Power != nil && info.Size() > 8<<20 {
			s.Power.Touch()
		}
		s.audit(r, "file.read", map[string]any{"ws": ws.ID, "path": r.URL.Query().Get("path"), "range": r.Header.Get("Range")})
	}
}

/** serveFile：带 ETag 与下载文件名输出文件 */
func serveFile(w http.ResponseWriter, r *http.Request, f io.ReadSeeker, info os.FileInfo, name string) {
	w.Header().Set("ETag", workspace.ETag(info))
	w.Header().Set("Cache-Control", "no-cache")
	if r.URL.Query().Get("download") == "1" {
		w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(name))
	}
	http.ServeContent(w, r, name, info.ModTime(), f)
}

/** writable：确认工作区可写、文件编辑已开启（电脑桌面端自己操作不受开关限制）且路径合法 */
func (s *Server) writable(r *http.Request, ws store.Workspace, rels ...string) error {
	if deviceOf(r).ID != desktopDevice.ID && !s.Cfg.Get().Features.FileEdit {
		return errf(403, "feature_disabled", "电脑端已关闭文件编辑功能")
	}
	if ws.ReadOnly {
		return workspace.ErrReadOnly
	}
	for _, rel := range rels {
		if _, err := workspace.CleanRel(rel); err != nil {
			return err
		}
	}
	return nil
}

/**
 * saveFile：保存文件
 *
 * 处理流程：
 * 1、校验可写与路径
 * 2、带 If-Match 原子保存，冲突返回 412
 * 3、返回新 ETag 并记录审计
 */
func (s *Server) saveFile(w http.ResponseWriter, r *http.Request) {
	// 1、校验
	ws, err := s.wsOf(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	rel := r.URL.Query().Get("path")
	if err := s.writable(r, ws, rel); err != nil {
		writeErr(w, r, err)
		return
	}
	abs, err := workspace.Resolve(ws.RootPath, rel)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 2、保存
	tag, err := workspace.Save(abs, http.MaxBytesReader(w, r.Body, maxSaveBytes), r.Header.Get("If-Match"), r.URL.Query().Get("create") == "1")
	if err != nil {
		if err == workspace.ErrConflict {
			if info, serr := os.Stat(abs); serr == nil {
				w.Header().Set("ETag", workspace.ETag(info))
			}
		}
		writeErr(w, r, err)
		return
	}
	// 3、结果
	w.Header().Set("ETag", tag)
	s.audit(r, "file.write", map[string]any{"ws": ws.ID, "path": rel})
	writeJSON(w, 200, map[string]string{"etag": tag})
}

/**
 * ops：重命名、移动、新建文件夹、删除（移到回收站）
 *
 * 处理流程：
 * 1、校验可写，禁止对工作区根目录操作
 * 2、按操作类型执行
 * 3、记录审计并返回新路径
 */
func (s *Server) ops(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Op   string `json:"op"`
		Path string `json:"path"`
		Name string `json:"name"`
		Dest string `json:"dest"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、校验
	ws, err := s.wsOf(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if err := s.writable(r, ws, in.Path, in.Dest); err != nil {
		writeErr(w, r, err)
		return
	}
	clean, _ := workspace.CleanRel(in.Path)
	if clean == "." && in.Op != "mkdir" {
		writeErr(w, r, errf(400, "bad_path", "不能操作工作区根目录"))
		return
	}
	abs, err := workspace.Resolve(ws.RootPath, clean)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 2、执行
	var newRel string
	switch in.Op {
	case "rename":
		var name string
		name, err = workspace.Rename(abs, in.Name)
		newRel = joinRel(path.Dir(clean), name)
	case "move":
		var dest string
		dest, err = workspace.Resolve(ws.RootPath, in.Dest)
		if err == nil {
			err = workspace.Move(abs, dest)
			d, _ := workspace.CleanRel(in.Dest)
			newRel = joinRel(d, path.Base(clean))
		}
	case "mkdir":
		var name string
		name, err = workspace.Mkdir(abs, in.Name)
		newRel = joinRel(clean, name)
	case "delete":
		err = workspace.Trash(abs)
	default:
		err = errf(400, "bad_op", "不支持的操作")
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 3、结果
	s.audit(r, "file."+in.Op, map[string]any{"ws": ws.ID, "path": clean, "name": in.Name, "dest": in.Dest})
	writeJSON(w, 200, map[string]string{"path": newRel})
}

/** joinRel：拼接相对路径 */
func joinRel(dir, name string) string {
	if dir == "." || dir == "" {
		return name
	}
	return dir + "/" + name
}

/** search：全工作区文件名搜索 */
func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	ws, err := s.wsOf(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	res, err := workspace.Search(r.Context(), ws.RootPath, r.URL.Query().Get("q"), limit)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"entries": res})
}
