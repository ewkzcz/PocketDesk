/**
 * 资料库接口：收藏、剪切板、提示词、自定义通讯录模板的增删改查，图片与文件内容单独上传下载，手机与电脑共用。
 */
package httpapi

import (
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** libraryBlobMax：单个图片或文件内容的大小上限 */
const libraryBlobMax = 25 << 20

/** libraryClipKeep：剪切板保留的最近条数（置顶的不计） */
const libraryClipKeep = 200

/** libraryKinds：支持的资料类型（收藏、剪切板、提示词、自定义的通讯录模板） */
var libraryKinds = map[string]bool{"fav": true, "clip": true, "prompt": true, "preset": true}

/** libraryKind：校验并返回资料类型 */
func libraryKind(v string) (string, error) {
	if !libraryKinds[v] {
		return "", errf(400, "bad_kind", "不支持的资料类型")
	}
	return v, nil
}

/** libraryChanged：通知所有端刷新这一类资料 */
func (s *Server) libraryChanged(kind string) {
	s.Hub.PublishGlobal("library.changed", map[string]string{"kind": kind})
}

/** libraryList：某一类资料 */
func (s *Server) libraryList(w http.ResponseWriter, r *http.Request) {
	kind, err := libraryKind(r.URL.Query().Get("kind"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	list, err := s.Store.Library(r.Context(), kind, limit)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, list)
}

/**
 * libraryAdd：新增一条文字资料
 *
 * 处理流程：
 * 1、校验类型，文字资料不能为空
 * 2、写库，剪切板只保留最近的若干条
 * 3、通知各端刷新
 */
func (s *Server) libraryAdd(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Kind   string `json:"kind"`
		Title  string `json:"title"`
		Body   string `json:"body"`
		Mime   string `json:"mime"`
		Name   string `json:"name"`
		Meta   string `json:"meta"`
		Pinned bool   `json:"pinned"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、校验
	kind, err := libraryKind(in.Kind)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if strings.TrimSpace(in.Body) == "" && strings.TrimSpace(in.Title) == "" {
		writeErr(w, r, errf(400, "empty", "内容不能为空"))
		return
	}
	if in.Mime == "" {
		in.Mime = "text/plain"
	}
	// 2、写库
	x, err := s.Store.AddLibrary(r.Context(), store.LibraryItem{ID: security.NewID(), Kind: kind, Title: in.Title, Body: in.Body, Mime: in.Mime, Name: in.Name, Meta: in.Meta, Pinned: in.Pinned}, nil)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.afterLibraryAdd(r, kind)
	writeJSON(w, 201, x)
}

/** afterLibraryAdd：剪切板修剪旧条目，并通知各端 */
func (s *Server) afterLibraryAdd(r *http.Request, kind string) {
	if kind == "clip" {
		s.Store.TrimLibrary(r.Context(), kind, libraryClipKeep)
	}
	s.libraryChanged(kind)
}

/**
 * libraryAddBlob：新增一条带图片或文件内容的资料，内容直接放在请求体里
 *
 * 类型、名称、标题、说明从地址参数取。
 */
func (s *Server) libraryAddBlob(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	kind, err := libraryKind(q.Get("kind"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, libraryBlobMax+1))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if len(data) == 0 {
		writeErr(w, r, errf(400, "empty", "内容不能为空"))
		return
	}
	if len(data) > libraryBlobMax {
		writeErr(w, r, errf(413, "too_large", "内容太大，最大 25 MB"))
		return
	}
	mime := q.Get("mime")
	if mime == "" {
		mime = "application/octet-stream"
	}
	// 名称在地址里编码了两层（避免特殊字符被吃掉），解不开时按原样使用
	name := q.Get("name")
	if n, err := url.QueryUnescape(name); err == nil {
		name = n
	}
	x, err := s.Store.AddLibrary(r.Context(), store.LibraryItem{ID: security.NewID(), Kind: kind, Title: q.Get("title"), Mime: mime, Name: name, Meta: q.Get("meta")}, data)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.afterLibraryAdd(r, kind)
	writeJSON(w, 201, x)
}

/** libraryBlob：下载图片或文件内容 */
func (s *Server) libraryBlob(w http.ResponseWriter, r *http.Request) {
	x, err := s.Store.LibraryItem(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	b, err := s.Store.LibraryBlob(r.Context(), x.ID)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if len(b) == 0 {
		writeErr(w, r, errf(404, "not_found", "这条资料没有文件内容"))
		return
	}
	w.Header().Set("Content-Type", x.Mime)
	w.Header().Set("Content-Length", strconv.Itoa(len(b)))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Write(b)
}

/** libraryPatch：修改标题、正文、说明或置顶 */
func (s *Server) libraryPatch(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Title  *string `json:"title"`
		Body   *string `json:"body"`
		Meta   *string `json:"meta"`
		Pinned *bool   `json:"pinned"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	x, err := s.Store.UpdateLibrary(r.Context(), r.PathValue("id"), store.LibraryPatch{Title: in.Title, Body: in.Body, Meta: in.Meta, Pinned: in.Pinned})
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.libraryChanged(x.Kind)
	writeJSON(w, 200, x)
}

/** libraryDelete：删除一条资料 */
func (s *Server) libraryDelete(w http.ResponseWriter, r *http.Request) {
	x, err := s.Store.LibraryItem(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if err := s.Store.DeleteLibrary(r.Context(), x.ID); err != nil {
		writeErr(w, r, err)
		return
	}
	s.libraryChanged(x.Kind)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** libraryClear：清空某一类里未置顶的资料 */
func (s *Server) libraryClear(w http.ResponseWriter, r *http.Request) {
	kind, err := libraryKind(r.URL.Query().Get("kind"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	n, err := s.Store.ClearLibrary(r.Context(), kind)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.libraryChanged(kind)
	writeJSON(w, 200, map[string]int64{"deleted": n})
}
