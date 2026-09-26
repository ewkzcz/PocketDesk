/**
 * 断点上传服务：实现 tus 1.0 核心协议与创建、终止、拼接、校验扩展，完成后按命名规则落盘。
 */
package tus

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/naming"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** 协议常量 */
const (
	Version        = "1.0.0"
	Extensions     = "creation,termination,concatenation,checksum"
	statusChecksum = 460
)

/** Target：一次上传完成后的落盘位置 */
type Target struct {
	Dir     string
	RelBase string
}

/** Resolver：根据上传元数据中的 target 解析落盘目录 */
type Resolver func(ctx context.Context, target, dateFolder string) (Target, error)

/** Completed：上传完成后的结果 */
type Completed struct {
	UploadID string `json:"uploadId"`
	Name     string `json:"name"`
	RelPath  string `json:"relPath"`
	Target   string `json:"target"`
	Size     int64  `json:"size"`
	SHA256   string `json:"sha256"`
	DeviceID string `json:"deviceId"`
	Mime     string `json:"mime"`
}

/** Progress：上传进度，用于推送给手机和桌面端 */
type Progress struct {
	UploadID string `json:"uploadId"`
	Name     string `json:"name"`
	Offset   int64  `json:"offset"`
	Length   int64  `json:"length"`
}

/** Server：tus 处理器 */
type Server struct {
	store      *store.Store
	dir        string
	basePath   string
	maxSize    int64
	resolve    Resolver
	now        func() time.Time
	locks      sync.Map
	OnComplete func(Completed)
	OnProgress func(Progress)
	DeviceOf   func(*http.Request) string
}

/** New：创建上传服务，dir 为临时文件目录 */
func New(s *store.Store, dir, basePath string, resolve Resolver) (*Server, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Server{store: s, dir: dir, basePath: strings.TrimSuffix(basePath, "/") + "/", maxSize: 1 << 40, resolve: resolve, now: time.Now}, nil
}

/** SetClock：替换时钟，仅供测试 */
func (s *Server) SetClock(fn func() time.Time) { s.now = fn }

/** ServeHTTP：按方法分发 */
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Tus-Resumable", Version)
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodOptions {
		w.Header().Set("Tus-Version", Version)
		w.Header().Set("Tus-Extension", Extensions)
		w.Header().Set("Tus-Checksum-Algorithm", "sha256")
		w.Header().Set("Tus-Max-Size", strconv.FormatInt(s.maxSize, 10))
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if v := r.Header.Get("Tus-Resumable"); v != Version {
		w.Header().Set("Tus-Version", Version)
		httpError(w, http.StatusPreconditionFailed, "unsupported_version", "协议版本不支持")
		return
	}
	id := strings.Trim(strings.TrimPrefix(r.URL.Path, s.basePath), "/")
	switch {
	case r.Method == http.MethodPost && id == "":
		s.create(w, r)
	case r.Method == http.MethodHead && id != "":
		s.head(w, r, id)
	case r.Method == http.MethodPatch && id != "":
		s.patch(w, r, id)
	case r.Method == http.MethodDelete && id != "":
		s.terminate(w, r, id)
	default:
		httpError(w, http.StatusMethodNotAllowed, "method_not_allowed", "不支持的请求")
	}
}

/** meta：上传元数据 */
type meta map[string]string

/** parseMetadata：解析 key base64,key base64 格式 */
func parseMetadata(h string) (meta, error) {
	m := meta{}
	if strings.TrimSpace(h) == "" {
		return m, nil
	}
	for _, pair := range strings.Split(h, ",") {
		parts := strings.Fields(pair)
		if len(parts) == 0 || len(parts) > 2 {
			return nil, errors.New("元数据格式错误")
		}
		v := ""
		if len(parts) == 2 {
			b, err := base64.StdEncoding.DecodeString(parts[1])
			if err != nil {
				return nil, errors.New("元数据编码错误")
			}
			v = string(b)
		}
		m[parts[0]] = v
	}
	return m, nil
}

/**
 * create：创建上传
 *
 * 处理流程：
 * 1、解析元数据与拼接头
 * 2、拼接请求交给 concat 处理
 * 3、普通或部分上传：校验长度，确定日期文件夹，创建空临时文件
 * 4、登记并返回 Location
 */
func (s *Server) create(w http.ResponseWriter, r *http.Request) {
	// 1、元数据
	md, err := parseMetadata(r.Header.Get("Upload-Metadata"))
	if err != nil {
		httpError(w, http.StatusBadRequest, "bad_metadata", err.Error())
		return
	}
	concat := r.Header.Get("Upload-Concat")
	// 2、拼接
	if strings.HasPrefix(concat, "final;") {
		s.concat(w, r, md, strings.TrimPrefix(concat, "final;"))
		return
	}
	// 3、长度与临时文件
	length, err := strconv.ParseInt(r.Header.Get("Upload-Length"), 10, 64)
	if err != nil || length < 0 {
		httpError(w, http.StatusBadRequest, "bad_length", "缺少或非法的 Upload-Length")
		return
	}
	if length > s.maxSize {
		httpError(w, http.StatusRequestEntityTooLarge, "too_large", "文件过大")
		return
	}
	partial := concat == "partial"
	if !partial {
		if _, err := s.resolve(r.Context(), md["target"], s.dateFolder(md)); err != nil {
			httpError(w, http.StatusBadRequest, "bad_target", err.Error())
			return
		}
	}
	id := security.NewID()
	f, err := os.OpenFile(s.dataPath(id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "io_error", "创建临时文件失败")
		return
	}
	f.Close()
	// 4、登记
	raw, _ := json.Marshal(md)
	u := store.Upload{ID: id, Length: length, Metadata: string(raw), Partial: partial, Target: md["target"], DateFolder: s.dateFolder(md), DeviceID: s.device(r)}
	if _, err := s.store.CreateUpload(r.Context(), u); err != nil {
		os.Remove(s.dataPath(id))
		httpError(w, http.StatusInternalServerError, "db_error", "登记上传失败")
		return
	}
	w.Header().Set("Location", s.basePath+id)
	w.Header().Set("Upload-Offset", "0")
	if length == 0 && !partial {
		c, err := s.complete(r.Context(), u, nil)
		if err != nil {
			respondFail(w, err)
			return
		}
		respondDone(w, c, http.StatusCreated)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

/** dateFolder：优先使用客户端创建任务时的本地日期 */
func (s *Server) dateFolder(md meta) string {
	if d := md["date"]; naming.IsDateFolder(d) {
		return d
	}
	return naming.DateFolder(s.now())
}

/** device：取当前请求的设备 ID */
func (s *Server) device(r *http.Request) string {
	if s.DeviceOf == nil {
		return ""
	}
	return s.DeviceOf(r)
}

/** head：查询已收偏移 */
func (s *Server) head(w http.ResponseWriter, r *http.Request, id string) {
	u, err := s.store.Upload(r.Context(), id)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.Header().Set("Upload-Offset", strconv.FormatInt(u.Offset, 10))
	w.Header().Set("Upload-Length", strconv.FormatInt(u.Length, 10))
	if u.Partial {
		w.Header().Set("Upload-Concat", "partial")
	}
	if u.ResultName != "" {
		w.Header().Set("X-PD-Name", url(u.ResultName))
	}
	w.WriteHeader(http.StatusOK)
}

/**
 * patch：按偏移追加数据
 *
 * 处理流程：
 * 1、获取上传锁，校验内容类型与偏移
 * 2、边写边计算块哈希，不超过声明长度
 * 3、带校验头时比对，不一致则回退到写前偏移
 * 4、更新偏移并推送进度，写满且非部分上传时落盘
 */
func (s *Server) patch(w http.ResponseWriter, r *http.Request, id string) {
	// 1、锁与校验
	mu := s.lock(id)
	if !mu.TryLock() {
		httpError(w, http.StatusConflict, "locked", "该上传正在进行中")
		return
	}
	defer mu.Unlock()
	if r.Header.Get("Content-Type") != "application/offset+octet-stream" {
		httpError(w, http.StatusUnsupportedMediaType, "bad_content_type", "内容类型错误")
		return
	}
	u, err := s.store.Upload(r.Context(), id)
	if err != nil {
		httpError(w, http.StatusNotFound, "not_found", "上传不存在或已过期")
		return
	}
	offset, err := strconv.ParseInt(r.Header.Get("Upload-Offset"), 10, 64)
	if err != nil || offset != u.Offset {
		w.Header().Set("Upload-Offset", strconv.FormatInt(u.Offset, 10))
		httpError(w, http.StatusConflict, "offset_mismatch", "偏移不一致")
		return
	}
	if u.ResultName != "" {
		w.Header().Set("Upload-Offset", strconv.FormatInt(u.Offset, 10))
		w.Header().Set("X-PD-Name", url(u.ResultName))
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if u.Offset == u.Length && !u.Partial {
		// 数据已收齐但上次落盘失败，重新尝试落盘
		w.Header().Set("Upload-Offset", strconv.FormatInt(u.Offset, 10))
		c, err := s.complete(r.Context(), u, nil)
		if err != nil {
			respondFail(w, err)
			return
		}
		respondDone(w, c, http.StatusNoContent)
		return
	}
	algo, want, err := parseChecksum(r.Header.Get("Upload-Checksum"))
	if err != nil {
		httpError(w, http.StatusBadRequest, "bad_checksum_header", err.Error())
		return
	}
	// 2、写入
	f, err := os.OpenFile(s.dataPath(id), os.O_WRONLY, 0o600)
	if err != nil {
		httpError(w, http.StatusNotFound, "not_found", "临时文件缺失")
		return
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		f.Close()
		httpError(w, http.StatusInternalServerError, "io_error", "定位失败")
		return
	}
	var h hash.Hash
	var dst io.Writer = f
	if algo != "" {
		h = sha256.New()
		dst = io.MultiWriter(f, h)
	}
	n, copyErr := io.Copy(dst, io.LimitReader(r.Body, u.Length-offset))
	// 3、块校验
	if h != nil && copyErr == nil && !equalBytes(h.Sum(nil), want) {
		f.Truncate(offset)
		f.Close()
		w.Header().Set("Upload-Offset", strconv.FormatInt(offset, 10))
		httpError(w, statusChecksum, "checksum_mismatch", "分块校验失败")
		return
	}
	if h != nil && copyErr != nil {
		f.Truncate(offset)
		n = 0
	}
	syncErr := f.Sync()
	f.Close()
	if syncErr != nil && copyErr == nil {
		copyErr = syncErr
	}
	// 4、偏移、进度与完成
	newOffset := offset + n
	if err := s.store.SetUploadOffset(context.WithoutCancel(r.Context()), id, newOffset); err != nil {
		httpError(w, http.StatusInternalServerError, "db_error", "保存偏移失败")
		return
	}
	u.Offset = newOffset
	s.progress(u)
	if copyErr != nil {
		return
	}
	w.Header().Set("Upload-Offset", strconv.FormatInt(newOffset, 10))
	if newOffset == u.Length && !u.Partial {
		c, err := s.complete(r.Context(), u, nil)
		if err != nil {
			respondFail(w, err)
			return
		}
		respondDone(w, c, http.StatusNoContent)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

/** progress：推送进度 */
func (s *Server) progress(u store.Upload) {
	if s.OnProgress == nil {
		return
	}
	var md meta
	json.Unmarshal([]byte(u.Metadata), &md)
	s.OnProgress(Progress{UploadID: u.ID, Name: md["filename"], Offset: u.Offset, Length: u.Length})
}

/**
 * concat：把多个部分上传拼接成完整文件
 *
 * 处理流程：
 * 1、解析部分上传 ID，确认全部存在且已写满
 * 2、按顺序拼接到新的临时文件
 * 3、登记最终上传并落盘，成功后清理部分上传
 */
func (s *Server) concat(w http.ResponseWriter, r *http.Request, md meta, list string) {
	// 1、部分上传
	var parts []store.Upload
	var total int64
	for _, p := range strings.Fields(list) {
		pid := path.Base(p)
		u, err := s.store.Upload(r.Context(), pid)
		if err != nil || !u.Partial {
			httpError(w, http.StatusBadRequest, "bad_part", "分段不存在: "+pid)
			return
		}
		if u.Offset != u.Length {
			httpError(w, http.StatusBadRequest, "part_incomplete", "分段未完成: "+pid)
			return
		}
		parts = append(parts, u)
		total += u.Length
	}
	if len(parts) == 0 {
		httpError(w, http.StatusBadRequest, "bad_part", "缺少分段")
		return
	}
	if _, err := s.resolve(r.Context(), md["target"], s.dateFolder(md)); err != nil {
		httpError(w, http.StatusBadRequest, "bad_target", err.Error())
		return
	}
	// 2、拼接
	id := security.NewID()
	out, err := os.OpenFile(s.dataPath(id), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "io_error", "创建临时文件失败")
		return
	}
	for _, p := range parts {
		in, err := os.Open(s.dataPath(p.ID))
		if err == nil {
			_, err = io.Copy(out, in)
			in.Close()
		}
		if err != nil {
			out.Close()
			os.Remove(s.dataPath(id))
			httpError(w, http.StatusInternalServerError, "io_error", "拼接失败")
			return
		}
	}
	out.Sync()
	out.Close()
	// 3、登记与落盘
	raw, _ := json.Marshal(md)
	u := store.Upload{ID: id, Length: total, Offset: total, Metadata: string(raw), Target: md["target"], DateFolder: s.dateFolder(md), DeviceID: s.device(r)}
	if _, err := s.store.CreateUpload(r.Context(), u); err != nil {
		os.Remove(s.dataPath(id))
		httpError(w, http.StatusInternalServerError, "db_error", "登记上传失败")
		return
	}
	w.Header().Set("Location", s.basePath+id)
	w.Header().Set("Upload-Offset", strconv.FormatInt(total, 10))
	c, err := s.complete(r.Context(), u, parts)
	if err != nil {
		respondFail(w, err)
		return
	}
	respondDone(w, c, http.StatusCreated)
}

/** failure：落盘阶段的错误响应 */
type failure struct {
	status int
	code   string
	msg    string
}

/** Error：实现 error 接口 */
func (f *failure) Error() string { return f.msg }

/** respondDone：把完成结果写入响应头并输出状态码 */
func respondDone(w http.ResponseWriter, c Completed, status int) {
	w.Header().Set("X-PD-Name", url(c.Name))
	w.Header().Set("X-PD-Path", url(c.RelPath))
	w.WriteHeader(status)
}

/** respondFail：输出落盘失败 */
func respondFail(w http.ResponseWriter, err error) {
	var f *failure
	if errors.As(err, &f) {
		httpError(w, f.status, f.code, f.msg)
		return
	}
	httpError(w, http.StatusInternalServerError, "io_error", err.Error())
}

/**
 * complete：校验整文件哈希并按命名规则落盘
 *
 * 处理流程：
 * 1、若元数据带 sha256，计算并比对，不一致删除临时文件
 * 2、解析目标目录，确定文件名（无名时用时间戳）
 * 3、原子落盘并记录结果名
 * 4、清理分段并回调
 */
func (s *Server) complete(ctx context.Context, u store.Upload, parts []store.Upload) (Completed, error) {
	ctx = context.WithoutCancel(ctx)
	var md meta
	json.Unmarshal([]byte(u.Metadata), &md)
	// 1、整文件哈希
	sum, err := fileSHA256(s.dataPath(u.ID))
	if err != nil {
		return Completed{}, &failure{http.StatusInternalServerError, "io_error", "读取临时文件失败"}
	}
	if want := strings.ToLower(md["sha256"]); want != "" && want != sum {
		os.Remove(s.dataPath(u.ID))
		s.store.DeleteUpload(ctx, u.ID)
		return Completed{}, &failure{statusChecksum, "checksum_mismatch", "整文件校验失败"}
	}
	// 2、目标与名字
	tgt, err := s.resolve(ctx, u.Target, u.DateFolder)
	if err != nil {
		return Completed{}, &failure{http.StatusBadRequest, "bad_target", err.Error()}
	}
	name := strings.TrimSpace(md["filename"])
	if name == "" {
		name = naming.TimestampName(s.now(), md["filetype"])
	}
	// 3、落盘
	final, err := naming.Place(s.dataPath(u.ID), tgt.Dir, name)
	if err != nil {
		return Completed{}, &failure{http.StatusInternalServerError, "io_error", "保存文件失败"}
	}
	s.store.SetUploadResult(ctx, u.ID, final)
	c := Completed{UploadID: u.ID, Name: final, RelPath: path.Join(tgt.RelBase, final), Target: u.Target, Size: u.Length, SHA256: sum, DeviceID: u.DeviceID, Mime: md["filetype"]}
	// 4、清理与回调
	for _, p := range parts {
		os.Remove(s.dataPath(p.ID))
		s.store.DeleteUpload(ctx, p.ID)
	}
	if s.OnComplete != nil {
		s.OnComplete(c)
	}
	return c, nil
}

/** terminate：终止上传并删除临时文件 */
func (s *Server) terminate(w http.ResponseWriter, r *http.Request, id string) {
	if _, err := s.store.Upload(r.Context(), id); err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	os.Remove(s.dataPath(id))
	s.store.DeleteUpload(r.Context(), id)
	w.WriteHeader(http.StatusNoContent)
}

/** Expire：清理超过 age 未完成的上传，返回清理数量 */
func (s *Server) Expire(ctx context.Context, age time.Duration) (int, error) {
	ids, err := s.store.StaleUploads(ctx, s.now().Add(-age).UnixMilli())
	if err != nil {
		return 0, err
	}
	for _, id := range ids {
		os.Remove(s.dataPath(id))
		s.store.DeleteUpload(ctx, id)
	}
	return len(ids), nil
}

/** dataPath：临时文件路径 */
func (s *Server) dataPath(id string) string { return filepath.Join(s.dir, id+".bin") }

/** lock：每个上传一把锁 */
func (s *Server) lock(id string) *sync.Mutex {
	v, _ := s.locks.LoadOrStore(id, &sync.Mutex{})
	return v.(*sync.Mutex)
}

/** parseChecksum：解析 "sha256 <base64>"，空头返回空算法 */
func parseChecksum(h string) (string, []byte, error) {
	if h == "" {
		return "", nil, nil
	}
	parts := strings.Fields(h)
	if len(parts) != 2 || parts[0] != "sha256" {
		return "", nil, errors.New("仅支持 sha256 校验")
	}
	b, err := base64.StdEncoding.DecodeString(parts[1])
	if err != nil || len(b) != sha256.Size {
		return "", nil, errors.New("校验值格式错误")
	}
	return parts[0], b, nil
}

/** fileSHA256：计算文件的 SHA-256 十六进制 */
func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

/** equalBytes：定长比较 */
func equalBytes(a, b []byte) bool {
	return security.EqualConstant(string(a), string(b))
}

/** url：响应头中的文件名做百分号编码，避免非 ASCII 字符 */
func url(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		if c >= 0x21 && c <= 0x7e && c != '%' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

/** httpError：统一 JSON 错误格式 */
func httpError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"code": code, "message": msg})
}
