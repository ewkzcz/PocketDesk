/**
 * 接口公共部分：统一错误格式、错误映射、JSON 读写、设备鉴权与来源限制中间件。
 */
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/netutil"
	"github.com/ewkzcz/pocketdesk/server/internal/pairing"
	"github.com/ewkzcz/pocketdesk/server/internal/render"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/session"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/terminal"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** APIVersion：接口版本号，随响应头 X-PD-API 返回 */
const APIVersion = "1"

/** apiError：带状态码的业务错误 */
type apiError struct {
	Status  int
	Code    string
	Message string
}

/** Error：实现 error */
func (e *apiError) Error() string { return e.Message }

/** errf：构造业务错误 */
func errf(status int, code, msg string) error {
	return &apiError{Status: status, Code: code, Message: msg}
}

/**
 * writeErr：把错误映射为统一格式 {"code","message"}
 *
 * 处理流程：
 * 1、业务错误原样输出
 * 2、已知错误映射为对应状态码
 * 3、未知错误记录日志，只返回通用提示
 */
func writeErr(w http.ResponseWriter, r *http.Request, err error) {
	// 1、业务错误
	var ae *apiError
	if errors.As(err, &ae) {
		writeJSON(w, ae.Status, map[string]string{"code": ae.Code, "message": ae.Message})
		return
	}
	// 2、已知错误
	type m struct {
		status int
		code   string
	}
	table := []struct {
		target error
		m
	}{
		{store.ErrNotFound, m{404, "not_found"}},
		{fs.ErrNotExist, m{404, "not_found"}},
		{terminal.ErrNotFound, m{404, "not_found"}},
		{workspace.ErrOutside, m{403, "forbidden_path"}},
		{workspace.ErrBadPath, m{400, "bad_path"}},
		{workspace.ErrReadOnly, m{403, "read_only"}},
		{workspace.ErrProtected, m{403, "read_only"}},
		{workspace.ErrConflict, m{412, "conflict"}},
		{workspace.ErrNeedIfMatch, m{428, "if_match_required"}},
		{workspace.ErrExists, m{409, "exists"}},
		{workspace.ErrNotDir, m{400, "not_dir"}},
		{workspace.ErrIsDir, m{400, "is_dir"}},
		{store.ErrDuplicate, m{409, "exists"}},
		{session.ErrDisabled, m{403, "feature_disabled"}},
		{terminal.ErrDisabled, m{403, "feature_disabled"}},
		{session.ErrUnknownKind, m{400, "unknown_kind"}},
		{session.ErrNotAgent, m{400, "not_agent"}},
		{session.ErrBusy, m{409, "busy"}},
		{session.ErrNothing, m{409, "nothing_to_retry"}},
		{session.ErrBadAction, m{400, "bad_action"}},
		{session.ErrNoDiff, m{404, "no_diff"}},
		{store.ErrAlreadyDecided, m{409, "already_decided"}},
		{render.ErrNotMarkdown, m{400, "not_markdown"}},
		{render.ErrTooLarge, m{413, "too_large"}},
		{render.ErrNoBrowser, m{503, "no_browser"}},
		{pairing.ErrInvalidCode, m{401, "invalid_code"}},
		{pairing.ErrLocked, m{429, "locked"}},
		{pairing.ErrDenied, m{403, "denied"}},
		{pairing.ErrTimeout, m{408, "timeout"}},
		{pairing.ErrNoRequest, m{404, "not_found"}},
	}
	for _, t := range table {
		if errors.Is(err, t.target) {
			msg := t.target.Error()
			if t.target == fs.ErrNotExist {
				msg = "文件不存在"
			}
			writeJSON(w, t.status, map[string]string{"code": t.code, "message": msg})
			return
		}
	}
	// 3、未知错误
	slog.Warn("请求处理失败", "method", r.Method, "path", r.URL.Path, "err", err)
	writeJSON(w, http.StatusInternalServerError, map[string]string{"code": "internal", "message": "操作失败，请稍后重试"})
}

/** writeJSON：输出 JSON */
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

/** readJSON：读取请求体 JSON，限制 1MB */
func readJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	if err := dec.Decode(v); err != nil && !errors.Is(err, io.EOF) {
		return errf(400, "bad_json", "请求内容格式错误")
	}
	return nil
}

/** ctxKey：上下文键 */
type ctxKey int

/** deviceKey：当前设备 */
const deviceKey ctxKey = 1

/** deviceOf：取当前请求的设备 */
func deviceOf(r *http.Request) store.Device {
	d, _ := r.Context().Value(deviceKey).(store.Device)
	return d
}

/** DeviceID：当前请求的设备 ID，供上传服务记录来源 */
func DeviceID(r *http.Request) string { return deviceOf(r).ID }

/** bearer：从 Authorization 头或 token 参数取令牌（浏览器 WebSocket 无法设置请求头） */
func bearer(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	}
	if r.URL.Path == "/ws" || strings.HasPrefix(r.URL.Path, "/term/") {
		return r.URL.Query().Get("token")
	}
	return ""
}

/** touchCache：设备最后在线时间每分钟最多写一次库 */
type touchCache struct {
	mu   sync.Mutex
	last map[string]time.Time
}

/** due：是否需要更新 */
func (t *touchCache) due(id string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.last == nil {
		t.last = map[string]time.Time{}
	}
	if time.Since(t.last[id]) < time.Minute {
		return false
	}
	t.last[id] = time.Now()
	return true
}

/**
 * auth：设备令牌鉴权
 *
 * 处理流程：
 * 1、取令牌并按哈希查未吊销的设备
 * 2、刷新最后在线时间（节流）
 * 3、把设备放进上下文
 */
func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 1、令牌
		tok := bearer(r)
		if tok == "" {
			writeJSON(w, 401, map[string]string{"code": "unauthorized", "message": "请先配对"})
			return
		}
		d, err := s.Store.DeviceByTokenHash(r.Context(), security.HashToken(tok))
		if err != nil {
			writeJSON(w, 401, map[string]string{"code": "unauthorized", "message": "设备未配对或已被吊销"})
			return
		}
		// 2、在线时间
		if s.touch.due(d.ID) {
			s.Store.TouchDevice(r.Context(), d.ID)
		}
		// 3、上下文
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceKey, d)))
	})
}

/** guard：只接受回环、局域网与 Tailscale 来源，并附加版本头 */
func guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !netutil.IsAllowedRemote(r.RemoteAddr) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("X-PD-API", APIVersion)
		next.ServeHTTP(w, r)
	})
}

/** audit：记录一次操作（失败只写日志） */
func (s *Server) audit(r *http.Request, action string, detail any) {
	if err := s.Store.Audit(context.WithoutCancel(r.Context()), deviceOf(r).ID, action, detail); err != nil {
		slog.Warn("写入审计失败", "err", err)
	}
}
