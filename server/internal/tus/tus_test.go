/**
 * 断点上传服务单元测试：覆盖分块校验、断点续传、拼接、整文件校验与清理。
 */
package tus

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** env：测试环境 */
type env struct {
	srv   *Server
	http  *httptest.Server
	inbox string
	done  []Completed
}

/** newEnv：搭建带内存目标目录的上传服务 */
func newEnv(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	e := &env{inbox: t.TempDir()}
	s, err := New(st, t.TempDir(), "/files/", func(_ context.Context, target, date string) (Target, error) {
		if target == "bad" {
			return Target{}, errors.New("目标不存在")
		}
		return Target{Dir: filepath.Join(e.inbox, date), RelBase: date}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	s.OnComplete = func(c Completed) { e.done = append(e.done, c) }
	e.srv = s
	e.http = httptest.NewServer(s)
	t.Cleanup(e.http.Close)
	return e
}

/** md：构造 Upload-Metadata 头 */
func md(kv ...string) string {
	var parts []string
	for i := 0; i < len(kv); i += 2 {
		parts = append(parts, kv[i]+" "+base64.StdEncoding.EncodeToString([]byte(kv[i+1])))
	}
	return strings.Join(parts, ",")
}

/** do：发送带 tus 头的请求 */
func (e *env) do(t *testing.T, method, p string, body io.Reader, hdr map[string]string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(method, e.http.URL+p, body)
	req.Header.Set("Tus-Resumable", Version)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	return res
}

/** create：创建上传并返回路径 */
func (e *env) create(t *testing.T, length int, hdr map[string]string) string {
	t.Helper()
	h := map[string]string{"Upload-Length": strconv.Itoa(length)}
	for k, v := range hdr {
		h[k] = v
	}
	res := e.do(t, "POST", "/files/", nil, h)
	if res.StatusCode != 201 {
		t.Fatalf("创建失败 %d", res.StatusCode)
	}
	return res.Header.Get("Location")
}

/** patch：上传一块 */
func (e *env) patch(t *testing.T, loc string, offset int, data []byte, checksum bool) *http.Response {
	h := map[string]string{"Content-Type": "application/offset+octet-stream", "Upload-Offset": strconv.Itoa(offset)}
	if checksum {
		sum := sha256.Sum256(data)
		h["Upload-Checksum"] = "sha256 " + base64.StdEncoding.EncodeToString(sum[:])
	}
	return e.do(t, "PATCH", loc, bytes.NewReader(data), h)
}

func TestOptionsAndVersion(t *testing.T) {
	e := newEnv(t)
	req, _ := http.NewRequest("OPTIONS", e.http.URL+"/files/", nil)
	res, _ := http.DefaultClient.Do(req)
	if res.StatusCode != 204 || !strings.Contains(res.Header.Get("Tus-Extension"), "concatenation") || res.Header.Get("Tus-Checksum-Algorithm") != "sha256" {
		t.Fatalf("OPTIONS 头异常 %v", res.Header)
	}
	req, _ = http.NewRequest("POST", e.http.URL+"/files/", nil)
	res, _ = http.DefaultClient.Do(req)
	if res.StatusCode != 412 {
		t.Fatalf("缺少版本头应返回 412，实际 %d", res.StatusCode)
	}
}

func TestChunkedUploadWithChecksumAndDate(t *testing.T) {
	e := newEnv(t)
	data := bytes.Repeat([]byte("pocketdesk"), 1000)
	whole := sha256.Sum256(data)
	loc := e.create(t, len(data), map[string]string{"Upload-Metadata": md("filename", "报告.pdf", "date", "20261001", "sha256", hex.EncodeToString(whole[:]))})
	if res := e.patch(t, loc, 0, data[:4000], true); res.StatusCode != 204 || res.Header.Get("Upload-Offset") != "4000" {
		t.Fatalf("第一块 %d %s", res.StatusCode, res.Header.Get("Upload-Offset"))
	}
	res := e.patch(t, loc, 4000, data[4000:], true)
	if res.StatusCode != 204 {
		t.Fatalf("第二块 %d", res.StatusCode)
	}
	if res.Header.Get("X-PD-Path") != "20261001/%E6%8A%A5%E5%91%8A.pdf" {
		t.Fatalf("结果路径 %s", res.Header.Get("X-PD-Path"))
	}
	got, err := os.ReadFile(filepath.Join(e.inbox, "20261001", "报告.pdf"))
	if err != nil || !bytes.Equal(got, data) {
		t.Fatal("落盘内容不一致")
	}
	if len(e.done) != 1 || e.done[0].SHA256 != hex.EncodeToString(whole[:]) {
		t.Fatal("完成回调异常")
	}
	head := e.do(t, "HEAD", loc, nil, nil)
	if head.Header.Get("X-PD-Name") == "" {
		t.Fatal("完成后 HEAD 应能查到结果名")
	}
	if again := e.patch(t, loc, len(data), nil, false); again.StatusCode != 204 {
		t.Fatalf("重复完成请求应幂等 %d", again.StatusCode)
	}
}

func TestChunkChecksumMismatchKeepsOffset(t *testing.T) {
	e := newEnv(t)
	loc := e.create(t, 10, nil)
	h := map[string]string{"Content-Type": "application/offset+octet-stream", "Upload-Offset": "0", "Upload-Checksum": "sha256 " + base64.StdEncoding.EncodeToString(make([]byte, 32))}
	res := e.do(t, "PATCH", loc, strings.NewReader("0123456789"), h)
	if res.StatusCode != 460 {
		t.Fatalf("校验失败应返回 460，实际 %d", res.StatusCode)
	}
	head := e.do(t, "HEAD", loc, nil, nil)
	if head.Header.Get("Upload-Offset") != "0" {
		t.Fatal("校验失败后偏移应保持不变")
	}
	if res := e.patch(t, loc, 5, []byte("x"), false); res.StatusCode != 409 {
		t.Fatalf("偏移不一致应 409，实际 %d", res.StatusCode)
	}
}

/** brokenReader：读到一半报错，模拟断网 */
type brokenReader struct {
	data []byte
	n    int
}

func (b *brokenReader) Read(p []byte) (int, error) {
	if b.n >= len(b.data) {
		return 0, errors.New("网络中断")
	}
	c := copy(p, b.data[b.n:])
	b.n += c
	return c, nil
}

func TestResumeAfterInterruption(t *testing.T) {
	e := newEnv(t)
	data := bytes.Repeat([]byte("a"), 100000)
	loc := e.create(t, len(data), map[string]string{"Upload-Metadata": md("filename", "big.bin")})
	req, _ := http.NewRequest("PATCH", e.http.URL+loc, &brokenReader{data: data[:30000]})
	req.Header.Set("Tus-Resumable", Version)
	req.Header.Set("Content-Type", "application/offset+octet-stream")
	req.Header.Set("Upload-Offset", "0")
	req.ContentLength = int64(len(data))
	if res, err := http.DefaultClient.Do(req); err == nil {
		res.Body.Close()
	}
	var off int
	for i := 0; i < 50; i++ {
		off, _ = strconv.Atoi(e.do(t, "HEAD", loc, nil, nil).Header.Get("Upload-Offset"))
		if off > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if off <= 0 || off > 30000 {
		t.Fatalf("中断后偏移 %d", off)
	}
	if res := e.patch(t, loc, off, data[off:], true); res.StatusCode != 204 {
		t.Fatalf("续传失败 %d", res.StatusCode)
	}
	got, _ := os.ReadFile(filepath.Join(e.inbox, e.done[0].RelPath))
	if !bytes.Equal(got, data) {
		t.Fatal("续传后内容不一致")
	}
}

func TestWholeFileChecksumMismatch(t *testing.T) {
	e := newEnv(t)
	loc := e.create(t, 3, map[string]string{"Upload-Metadata": md("filename", "a.txt", "sha256", strings.Repeat("0", 64))})
	if res := e.patch(t, loc, 0, []byte("abc"), false); res.StatusCode != 460 {
		t.Fatalf("整文件校验失败应 460，实际 %d", res.StatusCode)
	}
	if res := e.do(t, "HEAD", loc, nil, nil); res.StatusCode != 404 {
		t.Fatal("校验失败后应删除上传")
	}
}

func TestNamelessUsesTimestampAndDedupes(t *testing.T) {
	e := newEnv(t)
	now := time.Date(2026, 10, 1, 9, 30, 15, 0, time.Local)
	e.srv.SetClock(func() time.Time { return now })
	for i := 0; i < 2; i++ {
		loc := e.create(t, 2, map[string]string{"Upload-Metadata": md("filetype", "text/plain")})
		e.patch(t, loc, 0, []byte("hi"), false)
	}
	if e.done[0].Name != "20261001-093015-000.txt" || e.done[1].Name != "20261001-093015-000-1.txt" {
		t.Fatalf("时间戳命名 %s %s", e.done[0].Name, e.done[1].Name)
	}
}

func TestConcatenation(t *testing.T) {
	e := newEnv(t)
	parts := []string{"alpha-", "beta-", "gamma"}
	var locs []string
	for _, p := range parts {
		loc := e.create(t, len(p), map[string]string{"Upload-Concat": "partial"})
		if res := e.patch(t, loc, 0, []byte(p), true); res.StatusCode != 204 {
			t.Fatalf("分段上传 %d", res.StatusCode)
		}
		locs = append(locs, loc)
	}
	if len(e.done) != 0 {
		t.Fatal("分段不应单独落盘")
	}
	res := e.do(t, "POST", "/files/", nil, map[string]string{"Upload-Concat": "final;" + strings.Join(locs, " "), "Upload-Metadata": md("filename", "joined.txt")})
	if res.StatusCode != 201 {
		t.Fatalf("拼接 %d", res.StatusCode)
	}
	got, _ := os.ReadFile(filepath.Join(e.inbox, e.done[0].RelPath))
	if string(got) != "alpha-beta-gamma" {
		t.Fatalf("拼接内容 %q", got)
	}
	if e.do(t, "HEAD", locs[0], nil, nil).StatusCode != 404 {
		t.Fatal("拼接后应清理分段")
	}
}

func TestConcatRejectsIncompletePart(t *testing.T) {
	e := newEnv(t)
	loc := e.create(t, 5, map[string]string{"Upload-Concat": "partial"})
	res := e.do(t, "POST", "/files/", nil, map[string]string{"Upload-Concat": "final;" + loc})
	if res.StatusCode != 400 {
		t.Fatalf("未完成分段应拒绝 %d", res.StatusCode)
	}
}

func TestZeroLengthAndBadTarget(t *testing.T) {
	e := newEnv(t)
	res := e.do(t, "POST", "/files/", nil, map[string]string{"Upload-Length": "0", "Upload-Metadata": md("filename", "empty.txt")})
	if res.StatusCode != 201 || res.Header.Get("X-PD-Name") != "empty.txt" {
		t.Fatalf("空文件 %d %s", res.StatusCode, res.Header.Get("X-PD-Name"))
	}
	res = e.do(t, "POST", "/files/", nil, map[string]string{"Upload-Length": "1", "Upload-Metadata": md("target", "bad")})
	if res.StatusCode != 400 {
		t.Fatalf("非法目标应拒绝 %d", res.StatusCode)
	}
	res = e.do(t, "POST", "/files/", nil, map[string]string{"Upload-Length": "x"})
	if res.StatusCode != 400 {
		t.Fatal("非法长度应拒绝")
	}
	res = e.do(t, "POST", "/files/", nil, map[string]string{"Upload-Length": "1", "Upload-Metadata": "k !!!"})
	if res.StatusCode != 400 {
		t.Fatal("非法元数据应拒绝")
	}
}

func TestTerminateAndExpire(t *testing.T) {
	e := newEnv(t)
	loc := e.create(t, 5, nil)
	if res := e.do(t, "DELETE", loc, nil, nil); res.StatusCode != 204 {
		t.Fatal("终止失败")
	}
	if res := e.do(t, "HEAD", loc, nil, nil); res.StatusCode != 404 {
		t.Fatal("终止后仍存在")
	}
	e.create(t, 5, nil)
	n, err := e.srv.Expire(context.Background(), -time.Hour)
	if err != nil || n != 1 {
		t.Fatalf("清理数量 %d %v", n, err)
	}
	if res := e.patch(t, "/files/nope", 0, []byte("x"), false); res.StatusCode != 404 {
		t.Fatal("不存在的上传应 404")
	}
	req := e.do(t, "PATCH", loc, strings.NewReader("x"), map[string]string{"Content-Type": "text/plain", "Upload-Offset": "0"})
	if req.StatusCode != 415 {
		t.Fatal("错误内容类型应 415")
	}
}
