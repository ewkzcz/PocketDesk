/**
 * 桌面端文件传输助手：查看记录、发文字、发文件（含粘贴的图片）给手机，预览、下载或在电脑上打开记录里的文件。
 */
package httpapi

import (
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** adminAssistantEvents：文件传输助手的记录，after 之后的全部或最近 200 条 */
func (s *Server) adminAssistantEvents(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var evs []store.Event
	var err error
	if a := q.Get("after"); a != "" {
		after, _ := strconv.ParseInt(a, 10, 64)
		evs, err = s.Store.EventsAfter(r.Context(), AssistantID, after, 500)
	} else {
		evs, err = s.Store.EventsBefore(r.Context(), AssistantID, 1<<62, 200)
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, evs)
}

/** adminAssistantText：电脑发文字给手机 */
func (s *Server) adminAssistantText(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Text string `json:"text"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	if strings.TrimSpace(in.Text) == "" {
		writeErr(w, r, errf(400, "empty", "消息不能为空"))
		return
	}
	if err := s.emit(r.Context(), AssistantID, "msg.host", map[string]any{"text": in.Text}, "电脑："+firstLine(in.Text)); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "assistant.host_text", map[string]int{"len": len(in.Text)})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/**
 * adminAssistantFiles：电脑发文件给手机
 *
 * 处理流程：
 * 1、逐个读取表单里的文件（最多 2GB）
 * 2、存到收件目录日期文件夹并登记待发，手机在线时自动接收
 */
func (s *Server) adminAssistantFiles(w http.ResponseWriter, r *http.Request) {
	// 1、表单
	mr, err := r.MultipartReader()
	if err != nil {
		writeErr(w, r, errf(400, "bad_form", "请选择要发送的文件"))
		return
	}
	var sent []store.OutboxItem
	for {
		part, err := mr.NextPart()
		if err != nil {
			break
		}
		name := filepath.Base(part.FileName())
		if part.FormName() != "file" || name == "" || name == "." {
			part.Close()
			continue
		}
		// 2、发送
		it, err := s.Outbox.SendReader(r.Context(), http.MaxBytesReader(w, part, 2<<30), name, "")
		part.Close()
		if err != nil {
			writeErr(w, r, errf(400, "send_failed", name+"："+err.Error()))
			return
		}
		sent = append(sent, it)
	}
	if len(sent) == 0 {
		writeErr(w, r, errf(400, "empty", "请选择要发送的文件"))
		return
	}
	s.audit(r, "assistant.host_files", map[string]int{"count": len(sent)})
	writeJSON(w, 200, sent)
}

/** assistantPath：记录里某条文件消息对应的电脑上的文件，只认记录中出现过的路径 */
func (s *Server) assistantPath(r *http.Request, seq int64) (string, string, error) {
	evs, err := s.Store.EventsAfter(r.Context(), AssistantID, seq-1, 1)
	if err != nil || len(evs) == 0 || evs[0].Seq != seq {
		return "", "", errf(404, "not_found", "记录不存在")
	}
	var d struct {
		Name string `json:"name"`
		Path string `json:"path"`
		File struct {
			Name string `json:"name"`
			Path string `json:"path"`
		} `json:"file"`
	}
	json.Unmarshal(evs[0].Data, &d)
	p, name := d.Path, d.Name
	if p == "" {
		p, name = d.File.Path, d.File.Name
	}
	if p == "" {
		return "", "", errf(404, "not_found", "文件不在电脑上")
	}
	if info, err := os.Stat(p); err != nil || info.IsDir() {
		return "", "", errf(404, "not_found", "文件已被移动或删除")
	}
	return p, name, nil
}

/** adminAssistantFile：预览或下载记录里的文件，dl=1 时作为附件下载 */
func (s *Server) adminAssistantFile(w http.ResponseWriter, r *http.Request) {
	seq, _ := strconv.ParseInt(r.URL.Query().Get("seq"), 10, 64)
	p, name, err := s.assistantPath(r, seq)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	f, err := os.Open(p)
	if err != nil {
		writeErr(w, r, errf(404, "not_found", "文件已被移动或删除"))
		return
	}
	defer f.Close()
	info, _ := f.Stat()
	serveUserFile(w, r, name, info.ModTime(), f)
}

/** adminAssistantOpen：在电脑上用默认程序打开记录里的文件，reveal 为真时在文件管理器中显示 */
func (s *Server) adminAssistantOpen(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Seq    int64 `json:"seq"`
		Reveal bool  `json:"reveal"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	p, _, err := s.assistantPath(r, in.Seq)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if err := s.open(p, in.Reveal); err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** serveUserFile：输出用户文件；放在沙箱里，网页、SVG 等文件里的脚本不能以管理页身份运行 */
func serveUserFile(w http.ResponseWriter, r *http.Request, name string, mod time.Time, f io.ReadSeeker) {
	disp := "inline"
	if r.URL.Query().Get("dl") == "1" {
		disp = "attachment"
	}
	if ct := mime.TypeByExtension(filepath.Ext(name)); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'")
	w.Header().Set("Content-Disposition", mime.FormatMediaType(disp, map[string]string{"filename": name}))
	http.ServeContent(w, r, name, mod, f)
}

/** open：打开或定位电脑上的文件 */
func (s *Server) open(p string, reveal bool) error {
	if s.Opener != nil {
		return s.Opener(p, reveal)
	}
	return openLocal(p, reveal)
}

/** openLocal：用默认程序打开电脑上的文件，reveal 为真时在文件管理器中显示 */
func openLocal(p string, reveal bool) error {
	var cmd *exec.Cmd
	switch {
	case runtime.GOOS == "darwin" && reveal:
		cmd = exec.Command("open", "-R", p)
	case runtime.GOOS == "darwin":
		cmd = exec.Command("open", p)
	case runtime.GOOS == "windows" && reveal:
		cmd = exec.Command("explorer", "/select,", p)
	case runtime.GOOS == "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", p)
	case reveal:
		cmd = exec.Command("xdg-open", filepath.Dir(p))
	default:
		cmd = exec.Command("xdg-open", p)
	}
	if err := cmd.Start(); err != nil {
		return errf(500, "open_failed", "无法打开文件")
	}
	go cmd.Wait()
	return nil
}
