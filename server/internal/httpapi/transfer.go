/**
 * 传输接口：上传落盘位置解析、电脑发给手机的文件的下载与确认、文件传输助手（聊天化的文件互传入口）。
 */
package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/hub"
	"github.com/ewkzcz/pocketdesk/server/internal/naming"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/tus"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** 文件传输助手 */
const (
	AssistantID    = "assistant"
	AssistantKind  = "assistant"
	assistantTitle = "文件传输助手"
)

/**
 * UploadResolver：上传完成后的落盘位置
 *
 * 处理流程：
 * 1、默认、收件箱与文件传输助手：电脑收件目录下的日期文件夹
 * 2、聊天附件：会话工作目录下的 .pocketdesk/inbox/日期文件夹
 */
func UploadResolver(cfg *config.Store, st *store.Store) tus.Resolver {
	return func(ctx context.Context, target, date string) (tus.Target, error) {
		switch {
		// 1、收件箱
		case target == "" || target == "inbox" || target == AssistantID:
			return tus.Target{Dir: filepath.Join(cfg.Get().Transfer.InboxDir, date), RelBase: date}, nil
		// 2、聊天附件
		case strings.HasPrefix(target, "session:"):
			sess, err := st.Session(ctx, strings.TrimPrefix(target, "session:"))
			if err != nil {
				return tus.Target{}, errors.New("会话不存在")
			}
			ws, err := st.Workspace(ctx, sess.WorkspaceID)
			if err != nil {
				return tus.Target{}, errors.New("工作区不存在")
			}
			cwd, err := workspace.Resolve(ws.RootPath, sess.Cwd)
			if err != nil {
				return tus.Target{}, err
			}
			base := ".pocketdesk/inbox/" + date
			return tus.Target{Dir: filepath.Join(cwd, filepath.FromSlash(base)), RelBase: base}, nil
		}
		return tus.Target{}, errors.New("未知的上传目标")
	}
}

/** EnsureAssistant：确保文件传输助手会话存在 */
func (s *Server) EnsureAssistant(ctx context.Context) error {
	if _, err := s.Store.Session(ctx, AssistantID); err == nil {
		return nil
	}
	_, err := s.Store.CreateSession(ctx, store.Session{ID: AssistantID, Kind: AssistantKind, Title: assistantTitle, State: "idle"})
	return err
}

/** emit：向会话追加事件、更新摘要并推送 */
func (s *Server) emit(ctx context.Context, sid, typ string, data map[string]any, preview string) error {
	// 已被接受的操作必须记录完整，不随手机断开连接而取消
	ctx = context.WithoutCancel(ctx)
	_, err := s.Store.AppendEventThen(ctx, sid, typ, data, func(e store.Event) {
		s.Hub.Publish(hub.Message{Session: sid, Seq: e.Seq, Type: e.Type, Data: e.Data, CreatedAt: e.CreatedAt})
	})
	if err != nil {
		slog.Warn("写入事件失败", "session", sid, "err", err)
		return err
	}
	if preview != "" {
		s.Store.UpdateSession(ctx, sid, store.SessionPatch{Preview: &preview})
	}
	return nil
}

/** filePreview：文件消息的列表摘要 */
func filePreview(name, mime string) string {
	if strings.HasPrefix(mime, "image/") || isImageName(name) {
		return "[图片] " + name
	}
	return "[文件] " + name
}

/** isImageName：按扩展名判断图片 */
func isImageName(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp":
		return true
	}
	return false
}

/**
 * OnUploadComplete：上传落盘后的处理
 *
 * 处理流程：
 * 1、记录审计
 * 2、收件箱类上传写入文件传输助手
 * 3、广播传输完成
 */
func (s *Server) OnUploadComplete(c tus.Completed) {
	ctx := context.Background()
	// 1、审计
	s.Store.Audit(ctx, c.DeviceID, "upload.complete", map[string]any{"name": c.Name, "path": c.RelPath, "target": c.Target, "size": c.Size})
	// 2、文件传输助手
	if c.Target == "" || c.Target == "inbox" || c.Target == AssistantID {
		s.emit(ctx, AssistantID, "file", map[string]any{"direction": "up", "name": c.Name, "relPath": c.RelPath, "path": c.Path, "size": c.Size, "mime": c.Mime, "sha256": c.SHA256, "uploadId": c.UploadID}, filePreview(c.Name, c.Mime))
	}
	// 3、广播
	s.Hub.PublishGlobal("transfer.done", c)
}

/** OnOutboxNew：电脑有新文件要发给手机 */
func (s *Server) OnOutboxNew(it store.OutboxItem) {
	ctx := context.Background()
	s.emit(ctx, AssistantID, "file", map[string]any{"direction": "down", "outboxId": it.ID, "name": it.Name, "path": it.Path, "size": it.Size, "sha256": it.SHA256, "targetDevice": it.TargetDevice}, filePreview(it.Name, ""))
	s.Hub.PublishGlobal("outbox.new", it)
}

/** OnUploadProgress：电脑端视角的上传进度 */
func (s *Server) OnUploadProgress(p tus.Progress) {
	s.Hub.PublishGlobal("transfer.progress", p)
}

/** outboxList：当前设备可收的待发文件 */
func (s *Server) outboxList(w http.ResponseWriter, r *http.Request) {
	list, err := s.Store.PendingOutbox(r.Context(), deviceOf(r).ID)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, list)
}

/** outboxItem：取当前设备可见的发件记录 */
func (s *Server) outboxItem(r *http.Request) (store.OutboxItem, error) {
	it, err := s.Store.OutboxItem(r.Context(), r.PathValue("id"))
	if err != nil {
		return it, err
	}
	if it.TargetDevice != "" && it.TargetDevice != deviceOf(r).ID {
		return it, store.ErrNotFound
	}
	return it, nil
}

/** outboxFile：下载待发文件，支持 Range 与 If-Range */
func (s *Server) outboxFile(w http.ResponseWriter, r *http.Request) {
	it, err := s.outboxItem(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if s.paused() {
		w.Header().Set("Retry-After", "60")
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"code": "paused", "message": "电脑端已暂停传输"})
		return
	}
	f, err := os.Open(it.Path)
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
	if s.Power != nil {
		s.Power.Touch()
	}
	w.Header().Set("X-PD-SHA256", it.SHA256)
	serveFile(w, r, f, info, it.Name)
}

/** outboxAck：手机确认收到 */
func (s *Server) outboxAck(w http.ResponseWriter, r *http.Request) {
	it, err := s.outboxItem(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if err := s.Outbox.Ack(r.Context(), it.ID); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "outbox.ack", map[string]any{"id": it.ID, "name": it.Name})
	s.Hub.PublishGlobal("outbox.sent", map[string]string{"id": it.ID})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/**
 * assistantText：在文件传输助手里发文字，文字同时存为收件目录下的 txt 文件
 *
 * 处理流程：
 * 1、校验内容，同一编号的重发直接返回成功
 * 2、写入临时文件后按时间戳命名落盘
 * 3、写入会话事件
 */
func (s *Server) assistantText(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Text     string `json:"text"`
		ClientID string `json:"clientId"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、校验；网络超时后重发的同一条消息直接视为成功
	if strings.TrimSpace(in.Text) == "" {
		writeErr(w, r, errf(400, "empty", "消息不能为空"))
		return
	}
	s.textMu.Lock()
	defer s.textMu.Unlock()
	if s.recentText.Has(in.ClientID) {
		writeJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	// 2、落盘
	now := time.Now()
	date := naming.DateFolder(now)
	dir := filepath.Join(s.Cfg.Get().Transfer.InboxDir, date)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		writeErr(w, r, err)
		return
	}
	tmp, err := os.CreateTemp(dir, ".pd-text-*")
	if err != nil {
		writeErr(w, r, err)
		return
	}
	tmp.WriteString(in.Text)
	tmp.Close()
	name, err := naming.Place(tmp.Name(), dir, naming.TimestampName(now, "text/plain"))
	if err != nil {
		os.Remove(tmp.Name())
		writeErr(w, r, err)
		return
	}
	// 3、事件
	if err := s.emit(r.Context(), AssistantID, "msg.user", map[string]any{"text": in.Text, "clientId": in.ClientID, "file": map[string]string{"name": name, "relPath": date + "/" + name, "path": filepath.Join(dir, name)}}, "你："+firstLine(in.Text)); err != nil {
		writeErr(w, r, err)
		return
	}
	// 记录成功后才登记编号，失败时手机重发会重新处理
	s.recentText.Add(in.ClientID)
	s.audit(r, "assistant.text", map[string]any{"file": date + "/" + name})
	writeJSON(w, 200, map[string]string{"name": name})
}

/** firstLine：第一行，最多 60 字 */
func firstLine(s string) string {
	s = strings.TrimSpace(strings.SplitN(s, "\n", 2)[0])
	if r := []rune(s); len(r) > 60 {
		return string(r[:60]) + "…"
	}
	return s
}
