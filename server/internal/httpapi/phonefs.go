/**
 * 手机文件：桌面端通过手机的实时连接管理手机上的工作空间（浏览、新建文件夹、删除、重命名、上传、下载、编辑、更换目录）。
 *
 * 电脑经实时连接向手机发请求 phone.req，手机处理后回 phone.res；
 * 文件内容不走实时连接：电脑发给手机的文件由手机来取（GET /api/phone/blob/{id}），手机发给电脑的文件由手机上传（PUT 同一地址）。
 */
package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/naming"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
)

/** 手机处理普通请求的最长等待 */
const phoneCallWait = 20 * time.Second

/** 手机收取或上传一个文件的最长等待 */
const phoneBlobWait = 30 * time.Minute

/** phoneReply：手机的应答 */
type phoneReply struct {
	ID    string          `json:"id"`
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data"`
	Error string          `json:"error"`
}

/** phoneUpload：手机上传的一段内容，交给等待中的下载请求 */
type phoneUpload struct {
	body io.Reader
	size string
	done chan struct{}
}

/** phoneBlob：一次文件交换 */
type phoneBlob struct {
	device string
	// file：电脑发给手机时待手机取走的临时文件
	file string
	// in：手机发给电脑时接收上传内容
	in chan phoneUpload
}

/** phoneBridge：进行中的请求与文件交换 */
type phoneBridge struct {
	mu    sync.Mutex
	calls map[string]phoneCall
	blobs map[string]*phoneBlob
}

/** phoneCall：一个等待应答的请求 */
type phoneCall struct {
	device string
	ch     chan phoneReply
}

/**
 * phoneCall：向手机发请求并等待应答
 *
 * 处理流程：
 * 1、登记请求并推送给这台手机，手机不在线时直接报错
 * 2、等待应答或超时，手机报错时原样转给调用方
 */
func (s *Server) phoneCall(ctx context.Context, device, op string, args any, wait time.Duration) (json.RawMessage, error) {
	// 1、推送
	id := security.NewID()
	ch := make(chan phoneReply, 1)
	b := &s.phone
	b.mu.Lock()
	if b.calls == nil {
		b.calls = map[string]phoneCall{}
	}
	b.calls[id] = phoneCall{device: device, ch: ch}
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.calls, id)
		b.mu.Unlock()
	}()
	if !s.Hub.PublishTo(device, "phone.req", map[string]any{"id": id, "op": op, "args": args}) {
		return nil, errf(409, "phone_offline", "手机不在线，请在手机上打开 PocketDesk")
	}
	// 2、等待
	t := time.NewTimer(wait)
	defer t.Stop()
	select {
	case r := <-ch:
		if !r.OK {
			return nil, errf(400, "phone_error", r.Error)
		}
		return r.Data, nil
	case <-t.C:
		return nil, errf(504, "phone_timeout", "手机没有响应，请确认手机上的 PocketDesk 在前台")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

/** onPhoneReply：实时连接收到手机的应答，只接受发给这台手机的请求 */
func (s *Server) onPhoneReply(device string, raw []byte) {
	var r phoneReply
	if json.Unmarshal(raw, &r) != nil {
		return
	}
	b := &s.phone
	b.mu.Lock()
	c, ok := b.calls[r.ID]
	b.mu.Unlock()
	if ok && c.device == device {
		select {
		case c.ch <- r:
		default:
		}
	}
}

/** addBlob：登记一次文件交换 */
func (s *Server) addBlob(bl *phoneBlob) string {
	id := security.NewID()
	b := &s.phone
	b.mu.Lock()
	if b.blobs == nil {
		b.blobs = map[string]*phoneBlob{}
	}
	b.blobs[id] = bl
	b.mu.Unlock()
	return id
}

/** dropBlob：结束一次文件交换 */
func (s *Server) dropBlob(id string) {
	b := &s.phone
	b.mu.Lock()
	delete(b.blobs, id)
	b.mu.Unlock()
}

/** blobFor：取当前设备的文件交换 */
func (s *Server) blobFor(r *http.Request) (*phoneBlob, bool) {
	b := &s.phone
	b.mu.Lock()
	bl, ok := b.blobs[r.PathValue("id")]
	b.mu.Unlock()
	return bl, ok && bl.device == deviceOf(r).ID
}

/** phoneBlobGet：手机取走电脑发来的文件 */
func (s *Server) phoneBlobGet(w http.ResponseWriter, r *http.Request) {
	bl, ok := s.blobFor(r)
	if !ok || bl.file == "" {
		writeErr(w, r, errf(404, "not_found", "文件不存在"))
		return
	}
	http.ServeFile(w, r, bl.file)
}

/** phoneBlobPut：手机上传文件，内容直接转给等待中的桌面端下载 */
func (s *Server) phoneBlobPut(w http.ResponseWriter, r *http.Request) {
	bl, ok := s.blobFor(r)
	if !ok || bl.in == nil {
		writeErr(w, r, errf(404, "not_found", "请求已失效"))
		return
	}
	done := make(chan struct{})
	select {
	case bl.in <- phoneUpload{body: r.Body, size: r.Header.Get("Content-Length"), done: done}:
	case <-r.Context().Done():
		return
	case <-time.After(phoneCallWait):
		writeErr(w, r, errf(410, "gone", "请求已失效"))
		return
	}
	select {
	case <-done:
	case <-r.Context().Done():
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** phoneOps：桌面端可直接转给手机的操作 */
var phoneOps = map[string]bool{"info": true, "list": true, "mkdir": true, "delete": true, "rename": true, "browse": true, "setRoot": true}

/** adminPhones：已配对的手机与在线状态 */
func (s *Server) adminPhones(w http.ResponseWriter, r *http.Request) {
	devs, err := s.Store.Devices(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	online := s.Hub.Devices()
	out := []map[string]any{}
	for _, d := range devs {
		if !d.Revoked && d.Platform != "web" {
			out = append(out, map[string]any{"id": d.ID, "name": d.Name, "platform": d.Platform, "online": online[d.ID]})
		}
	}
	writeJSON(w, 200, out)
}

/** adminPhoneCall：浏览、新建文件夹、删除、重命名、选择与更换工作空间目录 */
func (s *Server) adminPhoneCall(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Op   string         `json:"op"`
		Args map[string]any `json:"args"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	if !phoneOps[in.Op] {
		writeErr(w, r, errf(400, "bad_op", "不支持的操作"))
		return
	}
	data, err := s.phoneCall(r.Context(), r.PathValue("dev"), in.Op, in.Args, phoneCallWait)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if in.Op != "info" && in.Op != "list" && in.Op != "browse" {
		s.audit(r, "phone."+in.Op, in.Args)
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Write(data)
}

/**
 * phonePull：请手机把一个文件上传过来，交给 sink 处理
 *
 * 处理流程：
 * 1、登记文件交换，请手机上传
 * 2、收到上传后交给 sink；手机报错或超时时返回错误
 */
func (s *Server) phonePull(r *http.Request, dev, p string, sink func(up phoneUpload) error) error {
	// 1、请手机上传
	in := make(chan phoneUpload)
	id := s.addBlob(&phoneBlob{device: dev, in: in})
	defer s.dropBlob(id)
	errc := make(chan error, 1)
	go func() {
		_, err := s.phoneCall(context.WithoutCancel(r.Context()), dev, "push", map[string]string{"id": id, "path": p}, phoneBlobWait)
		errc <- err
	}()
	// 2、交给 sink
	select {
	case up := <-in:
		defer close(up.done)
		return sink(up)
	case err := <-errc:
		if err == nil {
			err = errf(502, "phone_error", "手机没有发送文件")
		}
		return err
	case <-time.After(phoneCallWait):
		return errf(504, "phone_timeout", "手机没有响应，请确认手机上的 PocketDesk 在前台")
	case <-r.Context().Done():
		return r.Context().Err()
	}
}

/** adminPhoneFile：从手机取一个文件给浏览器，用于预览与编辑 */
func (s *Server) adminPhoneFile(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Query().Get("path")
	err := s.phonePull(r, r.PathValue("dev"), p, func(up phoneUpload) error {
		name := path.Base(p)
		w.Header().Set("Cache-Control", "no-store")
		if up.size != "" {
			w.Header().Set("Content-Length", up.size)
		}
		if ct := mime.TypeByExtension(filepath.Ext(name)); ct != "" {
			w.Header().Set("Content-Type", ct)
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'")
		w.Header().Set("Content-Disposition", mime.FormatMediaType("inline", map[string]string{"filename": name}))
		io.Copy(w, up.body)
		return nil
	})
	if err != nil && r.Context().Err() == nil {
		writeErr(w, r, err)
	}
}

/**
 * adminPhoneFetch：把手机上的文件存到电脑收件目录的日期文件夹，open 为真时用默认程序打开，否则在文件管理器中显示
 *
 * 处理流程：
 * 1、手机上传的内容先写临时文件，按命名规则落盘
 * 2、打开或定位
 */
func (s *Server) adminPhoneFetch(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Path string `json:"path"`
		Open bool   `json:"open"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、落盘
	dir := filepath.Join(s.Cfg.Get().Transfer.InboxDir, naming.DateFolder(time.Now()))
	var saved string
	err := s.phonePull(r, r.PathValue("dev"), in.Path, func(up phoneUpload) error {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		tmp, err := os.CreateTemp(dir, ".pd-phone-*")
		if err != nil {
			return err
		}
		_, err = io.Copy(tmp, up.body)
		tmp.Close()
		if err != nil {
			os.Remove(tmp.Name())
			return errf(502, "phone_error", "接收中断，请重试")
		}
		name, err := naming.Place(tmp.Name(), dir, path.Base(in.Path))
		if err != nil {
			os.Remove(tmp.Name())
			return err
		}
		saved = filepath.Join(dir, name)
		return nil
	})
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 2、打开或定位
	if err := s.open(saved, !in.Open); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "phone.fetch", map[string]string{"path": in.Path, "saved": saved})
	writeJSON(w, 200, map[string]string{"path": saved})
}

/**
 * adminPhoneUpload：把文件传到手机工作空间的某个目录，overwrite=1 时覆盖同名文件（保存编辑）
 *
 * 处理流程：
 * 1、逐个把表单里的文件存成临时文件
 * 2、请手机来取并写入目标目录，返回手机上最终的文件名
 */
func (s *Server) adminPhoneUpload(w http.ResponseWriter, r *http.Request) {
	dev, q := r.PathValue("dev"), r.URL.Query()
	overwrite, _ := strconv.ParseBool(q.Get("overwrite"))
	mr, err := r.MultipartReader()
	if err != nil {
		writeErr(w, r, errf(400, "bad_form", "请选择要上传的文件"))
		return
	}
	tmpDir := filepath.Join(s.DataDir, "tmp")
	os.MkdirAll(tmpDir, 0o700)
	var names []string
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
		// 1、临时文件
		tmp, err := os.CreateTemp(tmpDir, "phone-*")
		if err != nil {
			part.Close()
			writeErr(w, r, err)
			return
		}
		_, err = io.Copy(tmp, http.MaxBytesReader(w, part, 2<<30))
		tmp.Close()
		part.Close()
		if err != nil {
			os.Remove(tmp.Name())
			writeErr(w, r, errf(400, "upload_failed", name+"：上传中断"))
			return
		}
		// 2、手机来取
		id := s.addBlob(&phoneBlob{device: dev, file: tmp.Name()})
		data, err := s.phoneCall(r.Context(), dev, "pull", map[string]any{"id": id, "dir": q.Get("dir"), "name": name, "overwrite": overwrite}, phoneBlobWait)
		s.dropBlob(id)
		os.Remove(tmp.Name())
		if err != nil {
			writeErr(w, r, err)
			return
		}
		var got struct {
			Name string `json:"name"`
		}
		json.Unmarshal(data, &got)
		names = append(names, got.Name)
	}
	s.audit(r, "phone.upload", map[string]any{"dir": q.Get("dir"), "names": names})
	writeJSON(w, 200, map[string]any{"names": names})
}
