/**
 * 端到端集成测试：真实启动服务（HTTPS 与本机管理端口），模拟手机完成配对、文件、传输、会话、审批、事件补发、终端与吊销。
 */
package app

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/httpapi"
)

/** echoDriver：内存假 Agent，按提示词回应或请求审批 */
type echoDriver struct{}

func (echoDriver) Kind() string        { return agent.KindClaude }
func (echoDriver) SupportsSteer() bool { return false }
func (echoDriver) Start(_ context.Context, opt agent.Options) (agent.Process, error) {
	return &echoProc{opt: opt, events: make(chan agent.Event, 64), done: make(chan struct{})}, nil
}

/** echoProc：假进程 */
type echoProc struct {
	opt    agent.Options
	events chan agent.Event
	done   chan struct{}
	once   sync.Once
	mu     sync.RWMutex
	closed bool
}

func (p *echoProc) emit(t string, data map[string]any) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.closed {
		return
	}
	p.events <- agent.Event{Type: t, Data: data}
}

func (p *echoProc) Send(_ context.Context, m agent.Message) error {
	go func() {
		p.emit(agent.EvSessionID, map[string]any{"id": "echo-1"})
		if strings.HasPrefix(m.Text, "approve") {
			d, _ := p.opt.Approver.RequestApproval(context.Background(), agent.ApprovalRequest{Tool: "Bash", Kind: "command", Summary: "rm -rf tmp"})
			p.emit(agent.EvDone, map[string]any{"id": "a", "text": fmt.Sprintf("allow=%v", d.Allow)})
		} else {
			p.emit(agent.EvDelta, map[string]any{"id": "m", "text": "echo:"})
			p.emit(agent.EvDone, map[string]any{"id": "m", "text": "echo:" + m.Text})
		}
		p.emit(agent.EvTurnEnd, map[string]any{})
	}()
	return nil
}
func (p *echoProc) Steer(context.Context, agent.Message) error { return agent.ErrUnsupported }
func (p *echoProc) Interrupt() error                           { return nil }
func (p *echoProc) Events() <-chan agent.Event                 { return p.events }
func (p *echoProc) Done() <-chan struct{}                      { return p.done }
func (p *echoProc) Err() error                                 { return nil }
func (p *echoProc) Close() error {
	p.once.Do(func() {
		close(p.done)
		p.mu.Lock()
		p.closed = true
		close(p.events)
		p.mu.Unlock()
	})
	return nil
}

/** env：运行中的服务与模拟手机 */
type env struct {
	t      *testing.T
	a      *App
	base   string
	admin  string
	client *http.Client
	token  string
	ws     string
	root   string
}

/** freePort：取一个空闲端口 */
func freePort(t *testing.T) int {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

/**
 * start：准备数据目录与端口并启动服务，手机端客户端按证书指纹固定
 */
func start(t *testing.T) *env {
	t.Helper()
	dir := t.TempDir()
	port, adminPort := freePort(t), freePort(t)
	home := t.TempDir()
	cfg := map[string]any{"hostName": "TestMac", "port": port, "adminPort": adminPort, "transfer": map[string]any{"inboxDir": filepath.Join(home, "Inbox")}}
	b, _ := json.Marshal(cfg)
	os.WriteFile(filepath.Join(dir, "config.json"), b, 0o600)
	a, err := New(Options{DataDir: dir, Version: "test", Registry: agent.NewRegistry(echoDriver{}), ListenAddr: func() []string { return []string{"127.0.0.1"} }, NoMDNS: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	fp := a.Identity.Fingerprint
	tr := &http.Transport{TLSClientConfig: &tls.Config{
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			sum := sha256.Sum256(raw[0])
			if hex.EncodeToString(sum[:]) != fp {
				return errors.New("证书指纹不一致")
			}
			return nil
		},
	}}
	e := &env{t: t, a: a, base: fmt.Sprintf("https://127.0.0.1:%d", port), admin: fmt.Sprintf("http://127.0.0.1:%d", adminPort), client: &http.Client{Transport: tr, Timeout: 30 * time.Second}}
	e.ws = fmt.Sprintf("wss://127.0.0.1:%d", port)
	e.root = t.TempDir()
	for i := 0; i < 100; i++ {
		if res, err := e.client.Get(e.base + "/api/host"); err == nil {
			res.Body.Close()
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	return e
}

/** do：手机端请求 */
func (e *env) do(method, path string, body any, hdr map[string]string) (*http.Response, []byte) {
	e.t.Helper()
	var r io.Reader
	if b, ok := body.([]byte); ok {
		r = bytes.NewReader(b)
	} else if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.base+path, r)
	if e.token != "" {
		req.Header.Set("Authorization", "Bearer "+e.token)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	res, err := e.client.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	out, _ := io.ReadAll(res.Body)
	return res, out
}

/** adminDo：桌面端请求 */
func (e *env) adminDo(method, path string, body any, out any) int {
	e.t.Helper()
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.admin+path, r)
	req.Header.Set("X-PD-Key", e.a.AdminKey)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	if out != nil {
		json.NewDecoder(res.Body).Decode(out)
	}
	return res.StatusCode
}

/**
 * pair：桌面生成配对码，手机提交，桌面允许，手机拿到令牌
 */
func (e *env) pair(name string) string {
	e.t.Helper()
	var p struct {
		Code   string `json:"code"`
		QRText string `json:"qrText"`
	}
	e.adminDo("POST", "/admin/api/pair/start", nil, &p)
	raw, _ := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(p.QRText, "PD1:"))
	var qr struct {
		F string `json:"f"`
		C string `json:"c"`
	}
	json.Unmarshal(raw, &qr)
	if qr.F != e.a.Identity.Fingerprint || qr.C != p.Code {
		e.t.Fatalf("二维码内容 %s", raw)
	}
	type result struct {
		token string
		err   error
	}
	ch := make(chan result, 1)
	go func() {
		save := e.token
		e.token = ""
		res, body := e.do("POST", "/api/pair", map[string]string{"code": p.Code, "name": name, "platform": "android"}, nil)
		e.token = save
		var out struct {
			Token string `json:"token"`
		}
		json.Unmarshal(body, &out)
		if res.StatusCode != 200 {
			ch <- result{err: fmt.Errorf("配对 %d %s", res.StatusCode, body)}
			return
		}
		ch <- result{token: out.Token}
	}()
	var st struct {
		Pending []struct {
			ID string `json:"id"`
		} `json:"pending"`
	}
	for i := 0; i < 200 && len(st.Pending) == 0; i++ {
		time.Sleep(10 * time.Millisecond)
		e.adminDo("GET", "/admin/api/state", nil, &st)
	}
	if len(st.Pending) == 0 {
		e.t.Fatal("桌面端没有收到配对请求")
	}
	e.adminDo("POST", "/admin/api/pair/"+st.Pending[0].ID, map[string]bool{"allow": true}, nil)
	r := <-ch
	if r.err != nil {
		e.t.Fatal(r.err)
	}
	return r.token
}

/** dial：建立 WebSocket 连接 */
func (e *env) dial(path string) *websocket.Conn {
	e.t.Helper()
	d := websocket.Dialer{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	c, res, err := d.Dial(e.ws+path, http.Header{"Authorization": {"Bearer " + e.token}})
	if err != nil {
		if res != nil {
			b, _ := io.ReadAll(res.Body)
			e.t.Fatalf("连接失败 %d %s", res.StatusCode, b)
		}
		e.t.Fatal(err)
	}
	return c
}

/** wsMsg：事件消息 */
type wsMsg struct {
	Session string          `json:"session"`
	Seq     int64           `json:"seq"`
	Type    string          `json:"type"`
	Data    json.RawMessage `json:"data"`
}

/** readUntil：读消息直到满足条件 */
func readUntil(t *testing.T, c *websocket.Conn, match func(wsMsg) bool) []wsMsg {
	t.Helper()
	var got []wsMsg
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		var m wsMsg
		if err := c.ReadJSON(&m); err != nil {
			t.Fatalf("读取失败 %v，已收到 %d 条", err, len(got))
		}
		got = append(got, m)
		if match(m) {
			return got
		}
	}
}

func TestEndToEnd(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	e := start(t)

	// 未配对访问被拒绝
	if res, _ := e.do("GET", "/api/host", nil, nil); res.StatusCode != 401 || res.Header.Get("X-PD-API") != "1" {
		t.Fatalf("未配对 %d", res.StatusCode)
	}
	// 错误配对码
	if res, _ := e.do("POST", "/api/pair", map[string]string{"code": "AAAA-AAAA"}, nil); res.StatusCode != 401 {
		t.Fatalf("错误配对码 %d", res.StatusCode)
	}
	e.token = e.pair("测试手机")
	res, body := e.do("GET", "/api/host", nil, nil)
	if res.StatusCode != 200 || !strings.Contains(string(body), `"name":"TestMac"`) {
		t.Fatalf("电脑信息 %d %s", res.StatusCode, body)
	}

	t.Run("工作区文件", func(t *testing.T) { workspaceFlow(t, e) })
	t.Run("此电脑与位置管理", func(t *testing.T) { placesFlow(t, e) })
	t.Run("上传与文件传输助手", func(t *testing.T) { uploadFlow(t, e) })
	t.Run("发往手机", func(t *testing.T) { outboxFlow(t, e) })
	t.Run("桌面端文件传输助手", func(t *testing.T) { desktopAssistantFlow(t, e) })
	t.Run("桌面端管理手机文件", func(t *testing.T) { phoneFilesFlow(t, e) })
	t.Run("桌面端与手机共用会话接口", func(t *testing.T) { desktopSharedFlow(t, e) })
	t.Run("会话与审批", func(t *testing.T) { sessionFlow(t, e) })
	t.Run("终端", func(t *testing.T) { terminalFlow(t, e) })
	t.Run("管理入口防护", func(t *testing.T) { adminGuardFlow(t, e) })

	// 日志导出
	if res, body := e.do("POST", "/api/logs", nil, nil); res.StatusCode != 200 || !bytes.HasPrefix(body, []byte("PK")) {
		t.Fatalf("日志导出 %d", res.StatusCode)
	}
	// 吊销后立即失效
	var st struct {
		Devices []struct {
			ID string `json:"id"`
		} `json:"devices"`
	}
	e.adminDo("GET", "/admin/api/state", nil, &st)
	if code := e.adminDo("POST", "/admin/api/devices/"+st.Devices[0].ID+"/remove", nil, nil); code != 400 {
		t.Fatal("未吊销的设备不能直接删除")
	}
	e.adminDo("DELETE", "/admin/api/devices/"+st.Devices[0].ID, nil, nil)
	if res, _ := e.do("GET", "/api/host", nil, nil); res.StatusCode != 401 {
		t.Fatal("吊销后应无法访问")
	}
	// 吊销后可以从列表中删除
	if code := e.adminDo("POST", "/admin/api/devices/"+st.Devices[0].ID+"/remove", nil, nil); code != 200 {
		t.Fatalf("删除已吊销设备 %d", code)
	}
	st.Devices = nil
	e.adminDo("GET", "/admin/api/state", nil, &st)
	if len(st.Devices) != 0 {
		t.Fatal("删除后仍在列表中")
	}
}

/** workspaceFlow：列目录、读写、冲突、文件操作、搜索、越界 */
func workspaceFlow(t *testing.T, e *env) {
	root := e.root
	os.MkdirAll(filepath.Join(root, "20261002"), 0o755)
	os.MkdirAll(filepath.Join(root, "20261001"), 0o755)
	os.WriteFile(filepath.Join(root, "20261001", "会议纪要.md"), []byte("# 纪要\n"), 0o644)
	var ws struct {
		ID string `json:"id"`
	}
	if code := e.adminDo("POST", "/admin/api/workspaces", map[string]any{"name": "notes", "rootPath": root}, &ws); code != 200 {
		t.Fatalf("添加工作区 %d", code)
	}
	if code := e.adminDo("POST", "/admin/api/workspaces", map[string]any{"name": "x", "rootPath": "relative"}, nil); code != 400 {
		t.Fatal("相对路径应拒绝")
	}
	p := "/api/ws/" + ws.ID
	_, body := e.do("GET", p+"/list", nil, nil)
	if !strings.Contains(string(body), `"name":"20261001"`) || strings.Index(string(body), "20261001") > strings.Index(string(body), "20261002") {
		t.Fatalf("列目录 %s", body)
	}
	res, _ := e.do("PUT", p+"/file?path=a.txt&create=1", []byte("hello world"), nil)
	if res.StatusCode != 200 {
		t.Fatalf("新建文件 %d", res.StatusCode)
	}
	tag := res.Header.Get("ETag")
	res, body = e.do("GET", p+"/file?path=a.txt", nil, map[string]string{"Range": "bytes=6-"})
	if res.StatusCode != 206 || string(body) != "world" || res.Header.Get("ETag") != tag {
		t.Fatalf("Range 读取 %d %q", res.StatusCode, body)
	}
	if res, _ = e.do("PUT", p+"/file?path=a.txt", []byte("v2"), map[string]string{"If-Match": tag}); res.StatusCode != 200 {
		t.Fatalf("带 If-Match 保存 %d", res.StatusCode)
	}
	res, body = e.do("PUT", p+"/file?path=a.txt", []byte("v3"), map[string]string{"If-Match": tag})
	if res.StatusCode != 412 || !strings.Contains(string(body), "conflict") {
		t.Fatalf("旧 ETag 应冲突 %d %s", res.StatusCode, body)
	}
	if res, _ = e.do("PUT", p+"/file?path=a.txt", []byte("v3"), nil); res.StatusCode != 428 {
		t.Fatal("缺少 If-Match 应拒绝")
	}
	if res, _ = e.do("GET", p+"/file?path=../../etc/passwd", nil, nil); res.StatusCode != 403 {
		t.Fatalf("越界读取 %d", res.StatusCode)
	}
	if res, body = e.do("POST", p+"/ops", map[string]string{"op": "mkdir", "path": ".", "name": "docs"}, nil); res.StatusCode != 200 {
		t.Fatalf("新建文件夹 %d %s", res.StatusCode, body)
	}
	if res, body = e.do("POST", p+"/ops", map[string]string{"op": "rename", "path": "a.txt", "name": "b.txt"}, nil); res.StatusCode != 200 || !strings.Contains(string(body), `"path":"b.txt"`) {
		t.Fatalf("重命名 %s", body)
	}
	if res, _ = e.do("POST", p+"/ops", map[string]string{"op": "move", "path": "b.txt", "dest": "docs"}, nil); res.StatusCode != 200 {
		t.Fatal("移动失败")
	}
	if runtime.GOOS == "linux" {
		if res, _ = e.do("POST", p+"/ops", map[string]string{"op": "delete", "path": "docs/b.txt"}, nil); res.StatusCode != 200 {
			t.Fatal("删除失败")
		}
		if _, err := os.Stat(filepath.Join(root, "docs", "b.txt")); !os.IsNotExist(err) {
			t.Fatal("文件应移到回收站")
		}
	}
	if res, _ = e.do("POST", p+"/ops", map[string]string{"op": "delete", "path": "."}, nil); res.StatusCode != 400 {
		t.Fatal("不能删除根目录")
	}
	_, body = e.do("GET", p+"/search?q=纪要", nil, nil)
	if !strings.Contains(string(body), "20261001/会议纪要.md") {
		t.Fatalf("搜索 %s", body)
	}
	// 文件页上传到当前目录
	res = e.tusUpload(t, []byte("up"), map[string]string{"filename": "上传.txt", "target": "ws:" + ws.ID + ":docs/新目录"})
	if b, _ := os.ReadFile(filepath.Join(root, "docs", "新目录", "上传.txt")); string(b) != "up" {
		t.Fatal("上传到工作区目录失败")
	}
	resolve := httpapi.UploadResolver(e.a.Cfg, e.a.Store)
	if _, err := resolve(context.Background(), "ws:"+ws.ID+":../外面", ""); err == nil {
		t.Fatal("上传不能跳出工作区")
	}
	// 只读工作区
	e.adminDo("POST", "/admin/api/workspaces", map[string]any{"id": ws.ID, "name": "notes", "rootPath": root, "readOnly": true}, nil)
	if res, _ = e.do("PUT", p+"/file?path=c.txt&create=1", []byte("x"), nil); res.StatusCode != 403 {
		t.Fatal("只读工作区不应可写")
	}
	if _, err := resolve(context.Background(), "ws:"+ws.ID+":docs", ""); err == nil {
		t.Fatal("只读工作区不应可上传")
	}
}

/** tusCreate：创建上传 */
func (e *env) tusUpload(t *testing.T, data []byte, meta map[string]string) *http.Response {
	var parts []string
	for k, v := range meta {
		parts = append(parts, k+" "+base64.StdEncoding.EncodeToString([]byte(v)))
	}
	res, body := e.do("POST", "/files/", nil, map[string]string{"Tus-Resumable": "1.0.0", "Upload-Length": fmt.Sprint(len(data)), "Upload-Metadata": strings.Join(parts, ",")})
	if res.StatusCode != 201 {
		t.Fatalf("创建上传 %d %s", res.StatusCode, body)
	}
	loc := res.Header.Get("Location")
	sum := sha256.Sum256(data)
	res, body = e.do("PATCH", loc, data, map[string]string{"Tus-Resumable": "1.0.0", "Upload-Offset": "0", "Content-Type": "application/offset+octet-stream", "Upload-Checksum": "sha256 " + base64.StdEncoding.EncodeToString(sum[:])})
	if res.StatusCode != 204 {
		t.Fatalf("上传 %d %s", res.StatusCode, body)
	}
	return res
}

/** uploadFlow：上传到收件箱并出现在文件传输助手；文字消息存为 txt */
func uploadFlow(t *testing.T, e *env) {
	res := e.tusUpload(t, []byte("png-data"), map[string]string{"filename": "截图.png", "filetype": "image/png", "target": "assistant", "date": "20261001"})
	name, _ := url.PathUnescape(res.Header.Get("X-PD-Path"))
	if name != "20261001/截图.png" {
		t.Fatalf("落盘路径 %s", name)
	}
	inbox := e.a.Cfg.Get().Transfer.InboxDir
	if b, _ := os.ReadFile(filepath.Join(inbox, "20261001", "截图.png")); string(b) != "png-data" {
		t.Fatal("收件箱内容不一致")
	}
	if res, _ := e.do("POST", "/api/assistant/messages", map[string]string{"text": "记一下"}, nil); res.StatusCode != 200 {
		t.Fatal("发文字失败")
	}
	_, body := e.do("GET", "/api/sessions/assistant/events?after=0", nil, nil)
	if !strings.Contains(string(body), `"type":"file"`) || !strings.Contains(string(body), "记一下") || !strings.Contains(string(body), `"path":"`+e.a.Cfg.Get().Transfer.InboxDir) {
		t.Fatalf("文件传输助手事件 %s", body)
	}
	_, body = e.do("GET", "/api/sessions", nil, nil)
	if !strings.Contains(string(body), `你：记一下`) {
		t.Fatalf("会话摘要 %s", body)
	}
	e.a.API.PauseTransfers(true)
	if res, _ := e.do("POST", "/files/", nil, map[string]string{"Tus-Resumable": "1.0.0", "Upload-Length": "1"}); res.StatusCode != 503 {
		t.Fatal("暂停时应返回 503")
	}
	e.a.API.PauseTransfers(false)
}

/** outboxFlow：命令行发送、手机分段下载、确认后归档 */
func outboxFlow(t *testing.T, e *env) {
	src := filepath.Join(t.TempDir(), "报销单.pdf")
	os.WriteFile(src, []byte("0123456789"), 0o644)
	var sent []struct {
		ID string `json:"id"`
	}
	if code := e.adminDo("POST", "/admin/api/send", map[string]any{"paths": []string{src}, "to": "测试手机"}, &sent); code != 200 || len(sent) != 1 {
		t.Fatalf("发送 %d", code)
	}
	// 电脑上也留一份：复制到收件目录的日期文件夹
	if b, _ := os.ReadFile(filepath.Join(e.a.Cfg.Get().Transfer.InboxDir, time.Now().Format("20060102"), "报销单.pdf")); string(b) != "0123456789" {
		t.Fatal("未复制到收件目录")
	}
	_, body := e.do("GET", "/api/outbox", nil, nil)
	if !strings.Contains(string(body), sent[0].ID) {
		t.Fatalf("待收列表 %s", body)
	}
	res, body := e.do("GET", "/api/outbox/"+sent[0].ID+"/file", nil, map[string]string{"Range": "bytes=0-3"})
	if res.StatusCode != 206 || string(body) != "0123" || res.Header.Get("X-PD-SHA256") == "" {
		t.Fatalf("分段下载 %d %q", res.StatusCode, body)
	}
	tag := res.Header.Get("ETag")
	res, body = e.do("GET", "/api/outbox/"+sent[0].ID+"/file", nil, map[string]string{"Range": "bytes=4-", "If-Range": tag})
	if res.StatusCode != 206 || string(body) != "456789" {
		t.Fatalf("续传 %d %q", res.StatusCode, body)
	}
	res, body = e.do("GET", "/api/outbox/"+sent[0].ID+"/file", nil, map[string]string{"Range": "bytes=4-", "If-Range": `"stale"`})
	if res.StatusCode != 200 || string(body) != "0123456789" {
		t.Fatalf("文件变化后应返回完整文件 %d", res.StatusCode)
	}
	if res, _ = e.do("POST", "/api/outbox/"+sent[0].ID+"/ack", nil, nil); res.StatusCode != 200 {
		t.Fatal("确认失败")
	}
	if _, body = e.do("GET", "/api/outbox", nil, nil); strings.Contains(string(body), sent[0].ID) {
		t.Fatal("确认后不应再出现")
	}
	if code := e.adminDo("POST", "/admin/api/send", map[string]any{"paths": []string{src}, "to": "不存在"}, nil); code != 404 {
		t.Fatal("未知设备应报错")
	}
}

/** adminRaw：带任意请求体调用管理接口 */
func (e *env) adminRaw(method, path string, body io.Reader, ctype string) (int, []byte) {
	e.t.Helper()
	req, _ := http.NewRequest(method, e.admin+path, body)
	req.Header.Set("X-PD-Key", e.a.AdminKey)
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, b
}

/** multipartFiles：构造上传表单 */
func multipartFiles(files map[string]string) (io.Reader, string) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for name, content := range files {
		fw, _ := mw.CreateFormFile("file", name)
		fw.Write([]byte(content))
	}
	mw.Close()
	return &buf, mw.FormDataContentType()
}

/** desktopAssistantFlow：桌面端发文字、发文件，手机端收到记录，桌面端能取回记录里的文件 */
func desktopAssistantFlow(t *testing.T, e *env) {
	if code := e.adminDo("POST", "/admin/api/assistant/text", map[string]string{"text": "电脑这边发一句"}, nil); code != 200 {
		t.Fatalf("发文字 %d", code)
	}
	body, ct := multipartFiles(map[string]string{"粘贴图片.png": "png-bytes"})
	if code, b := e.adminRaw("POST", "/admin/api/assistant/files", body, ct); code != 200 || !strings.Contains(string(b), "粘贴图片.png") {
		t.Fatalf("发文件 %d %s", code, b)
	}
	// 手机端的文件传输助手里能看到两条，文件同时留在电脑收件目录
	_, evs := e.do("GET", "/api/sessions/assistant/events?after=0", nil, nil)
	if !strings.Contains(string(evs), `"type":"msg.host"`) || !strings.Contains(string(evs), "电脑这边发一句") || !strings.Contains(string(evs), `"direction":"down"`) || !strings.Contains(string(evs), "粘贴图片.png") {
		t.Fatalf("手机端记录 %s", evs)
	}
	if b, _ := os.ReadFile(filepath.Join(e.a.Cfg.Get().Transfer.InboxDir, time.Now().Format("20060102"), "粘贴图片.png")); string(b) != "png-bytes" {
		t.Fatal("电脑收件目录里没有这份文件")
	}
	// 桌面端取记录与文件
	var list []struct {
		Seq  int64           `json:"seq"`
		Type string          `json:"type"`
		Data json.RawMessage `json:"data"`
	}
	if code := e.adminDo("GET", "/admin/api/assistant/events", nil, &list); code != 200 || len(list) == 0 {
		t.Fatalf("桌面端记录 %d", code)
	}
	var seq int64
	for _, ev := range list {
		if ev.Type == "file" && strings.Contains(string(ev.Data), "粘贴图片.png") {
			seq = ev.Seq
		}
	}
	code, b := e.adminRaw("GET", fmt.Sprintf("/admin/api/assistant/file?seq=%d", seq), nil, "")
	if code != 200 || string(b) != "png-bytes" {
		t.Fatalf("桌面端取文件 %d %q", code, b)
	}
	if code, _ := e.adminRaw("GET", "/admin/api/assistant/file?seq=99999", nil, ""); code != 404 {
		t.Fatal("不存在的记录应 404")
	}
}

/**
 * phoneFilesFlow：桌面端管理手机文件
 *
 * 处理流程：
 * 1、手机不在线时直接报错
 * 2、模拟手机：连上实时连接，按请求列目录、上传文件、收取文件
 * 3、桌面端列目录、下载、上传，不支持的操作被拒绝
 */
func phoneFilesFlow(t *testing.T, e *env) {
	var phones []struct {
		ID     string `json:"id"`
		Online bool   `json:"online"`
	}
	e.adminDo("GET", "/admin/api/phones", nil, &phones)
	if len(phones) == 0 {
		t.Fatal("没有已配对的手机")
	}
	dev := phones[0].ID
	// 1、不在线
	if code := e.adminDo("POST", "/admin/api/phone/"+dev+"/call", map[string]any{"op": "list", "args": map[string]string{"path": ""}}, nil); code != 409 {
		t.Fatalf("手机不在线应报错 %d", code)
	}
	// 2、模拟手机
	c := e.dial("/ws")
	defer c.Close()
	c.WriteJSON(map[string]any{"type": "hello", "cursors": map[string]int64{}})
	readUntil(t, c, func(m wsMsg) bool { return m.Type == "ready" })
	received := make(chan string, 1)
	go func() {
		for {
			var m wsMsg
			if c.ReadJSON(&m) != nil {
				return
			}
			if m.Type != "phone.req" {
				continue
			}
			var req struct {
				ID   string         `json:"id"`
				Op   string         `json:"op"`
				Args map[string]any `json:"args"`
			}
			json.Unmarshal(m.Data, &req)
			reply := map[string]any{"type": "phone.res", "id": req.ID, "ok": true}
			switch req.Op {
			case "list":
				reply["data"] = map[string]any{"entries": []map[string]any{{"name": "照片.jpg", "isDir": false, "size": 3}}}
			case "push":
				e.do("PUT", "/api/phone/blob/"+req.Args["id"].(string), []byte("jpg"), nil)
			case "pull":
				_, b := e.do("GET", "/api/phone/blob/"+req.Args["id"].(string), nil, nil)
				received <- req.Args["dir"].(string) + "/" + req.Args["name"].(string) + "=" + string(b)
				reply["data"] = map[string]string{"name": req.Args["name"].(string)}
			default:
				reply = map[string]any{"type": "phone.res", "id": req.ID, "ok": false, "error": "手机上没有这个文件夹"}
			}
			c.WriteJSON(reply)
		}
	}()
	// 3、桌面端操作
	var opened []string
	e.a.API.Opener = func(p string, reveal bool) error {
		opened = append(opened, fmt.Sprintf("%s %v", filepath.Base(p), reveal))
		return nil
	}
	code, b := e.adminRaw("POST", "/admin/api/phone/"+dev+"/call", strings.NewReader(`{"op":"list","args":{"path":""}}`), "application/json")
	if code != 200 || !strings.Contains(string(b), "照片.jpg") {
		t.Fatalf("列目录 %d %s", code, b)
	}
	if code, b = e.adminRaw("GET", "/admin/api/phone/"+dev+"/file?path=照片.jpg", nil, ""); code != 200 || string(b) != "jpg" {
		t.Fatalf("下载 %d %q", code, b)
	}
	// 存到电脑收件目录并在文件管理器中显示
	var saved struct {
		Path string `json:"path"`
	}
	if code = e.adminDo("POST", "/admin/api/phone/"+dev+"/fetch", map[string]any{"path": "照片.jpg"}, &saved); code != 200 {
		t.Fatalf("存到电脑 %d", code)
	}
	if b, _ := os.ReadFile(saved.Path); string(b) != "jpg" || !strings.HasPrefix(saved.Path, e.a.Cfg.Get().Transfer.InboxDir) || len(opened) != 1 || opened[0] != "照片.jpg true" {
		t.Fatalf("存到电脑 %s %v", saved.Path, opened)
	}
	body, ct := multipartFiles(map[string]string{"报告.pdf": "pdf"})
	if code, b = e.adminRaw("POST", "/admin/api/phone/"+dev+"/upload?dir=资料", body, ct); code != 200 || !strings.Contains(string(b), "报告.pdf") {
		t.Fatalf("上传 %d %s", code, b)
	}
	if got := <-received; got != "资料/报告.pdf=pdf" {
		t.Fatalf("手机收到 %s", got)
	}
	if code, b = e.adminRaw("POST", "/admin/api/phone/"+dev+"/call", strings.NewReader(`{"op":"mkdir","args":{"path":"x","name":"y"}}`), "application/json"); code != 400 || !strings.Contains(string(b), "手机上没有这个文件夹") {
		t.Fatalf("手机报错应原样返回 %d %s", code, b)
	}
	if code = e.adminDo("POST", "/admin/api/phone/"+dev+"/call", map[string]any{"op": "push"}, nil); code != 400 {
		t.Fatal("不支持的操作应拒绝")
	}
	// 其他设备不能取走这次交换的文件
	if res, _ := e.do("GET", "/api/phone/blob/不存在", nil, nil); res.StatusCode != 404 {
		t.Fatal("不存在的交换应 404")
	}
}

/** desktopSharedFlow：桌面端以「电脑」身份使用与手机相同的会话接口，手机能看到桌面端发的消息 */
func desktopSharedFlow(t *testing.T, e *env) {
	var sessions []struct {
		ID string `json:"id"`
	}
	if code := e.adminDo("GET", "/admin/p/api/sessions", nil, &sessions); code != 200 || len(sessions) == 0 {
		t.Fatalf("桌面端会话列表 %d", code)
	}
	if code := e.adminDo("POST", "/admin/p/api/assistant/messages", map[string]string{"text": "桌面端共用接口发的", "clientId": "desk-1"}, nil); code != 200 {
		t.Fatalf("桌面端发消息 %d", code)
	}
	_, body := e.do("GET", "/api/sessions/assistant/events?after=0", nil, nil)
	if !strings.Contains(string(body), "桌面端共用接口发的") {
		t.Fatalf("手机端应看到桌面端发的消息 %s", body)
	}
	// 桌面端新建 Agent 会话并添加附件，路径与手机端一致
	var wsList []struct {
		ID       string `json:"id"`
		RootPath string `json:"rootPath"`
		System   bool   `json:"system"`
	}
	e.adminDo("GET", "/admin/p/api/ws", nil, &wsList)
	wsID := ""
	for _, w := range wsList {
		if _, err := os.Stat(w.RootPath); err == nil && !w.System {
			wsID = w.ID
		}
	}
	var sess struct {
		ID string `json:"id"`
	}
	if code := e.adminDo("POST", "/admin/p/api/sessions", map[string]string{"kind": "claude", "workspaceId": wsID, "cwd": "."}, &sess); code != 201 && code != 200 {
		t.Fatalf("桌面端新建会话 %d", code)
	}
	body2, ct := multipartFiles(map[string]string{"粘贴图片.png": "img"})
	code, b := e.adminRaw("POST", "/admin/api/sessions/"+sess.ID+"/attach", body2, ct)
	if code != 200 || !strings.Contains(string(b), ".pocketdesk/inbox/") || !strings.Contains(string(b), "粘贴图片.png") {
		t.Fatalf("桌面端添加附件 %d %s", code, b)
	}
	// 未带管理凭证不能访问
	res, err := http.Get(e.admin + "/admin/p/api/sessions")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 401 && res.StatusCode != 403 {
		t.Fatalf("未带凭证应拒绝 %d", res.StatusCode)
	}
	// 实时通道：同源页面可连，跨站页面被拒
	d := websocket.Dialer{}
	hdr := http.Header{"X-PD-Key": {e.a.AdminKey}, "Origin": {e.admin}}
	c, _, err := d.Dial(strings.Replace(e.admin, "http", "ws", 1)+"/admin/p/ws", hdr)
	if err != nil {
		t.Fatalf("桌面端实时通道 %v", err)
	}
	c.WriteJSON(map[string]any{"type": "hello", "cursors": map[string]int64{}})
	readUntil(t, c, func(m wsMsg) bool { return m.Type == "ready" })
	c.Close()
	hdr.Set("Origin", "http://evil.example")
	if _, _, err := d.Dial(strings.Replace(e.admin, "http", "ws", 1)+"/admin/p/ws", hdr); err == nil {
		t.Fatal("跨站页面不应连上")
	}
}

/** sessionFlow：新建会话、WebSocket 收事件、审批、断线补发 */
func sessionFlow(t *testing.T, e *env) {
	var wsList []struct {
		ID string `json:"id"`
	}
	_, body := e.do("GET", "/api/ws", nil, nil)
	json.Unmarshal(body, &wsList)
	res, body := e.do("POST", "/api/sessions", map[string]string{"kind": "claude", "workspaceId": wsList[0].ID, "cwd": "."}, nil)
	var sess struct {
		ID string `json:"id"`
	}
	json.Unmarshal(body, &sess)
	if res.StatusCode != 201 {
		t.Fatalf("新建会话 %d %s", res.StatusCode, body)
	}
	c := e.dial("/ws")
	defer c.Close()
	c.WriteJSON(map[string]any{"type": "hello", "cursors": map[string]int64{sess.ID: 0}})
	readUntil(t, c, func(m wsMsg) bool { return m.Type == "ready" })
	e.do("POST", "/api/sessions/"+sess.ID+"/messages", map[string]string{"text": "hi"}, nil)
	got := readUntil(t, c, func(m wsMsg) bool { return m.Type == "state" && strings.Contains(string(m.Data), "idle") && m.Seq > 2 })
	var sawDone bool
	for _, m := range got {
		if m.Type == "msg.done" && strings.Contains(string(m.Data), "echo:hi") {
			sawDone = true
		}
	}
	if !sawDone {
		t.Fatalf("未收到回复 %+v", got)
	}
	e.do("POST", "/api/sessions/"+sess.ID+"/messages", map[string]string{"text": "approve it"}, nil)
	got = readUntil(t, c, func(m wsMsg) bool { return m.Type == "approval.request" })
	var ap struct {
		ID string `json:"id"`
	}
	json.Unmarshal(got[len(got)-1].Data, &ap)
	if res, _ := e.do("POST", "/api/approvals/"+ap.ID, map[string]string{"action": "allow"}, nil); res.StatusCode != 200 {
		t.Fatal("审批失败")
	}
	got = readUntil(t, c, func(m wsMsg) bool { return m.Type == "msg.done" })
	if !strings.Contains(string(got[len(got)-1].Data), "allow=true") {
		t.Fatalf("审批结果未送达 %s", got[len(got)-1].Data)
	}
	lastSeen := got[len(got)-1].Seq
	c.Close()
	// 断线期间继续产生事件，重连后按游标只补发缺失部分
	e.do("POST", "/api/sessions/"+sess.ID+"/messages", map[string]string{"text": "offline"}, nil)
	time.Sleep(300 * time.Millisecond)
	c2 := e.dial("/ws")
	defer c2.Close()
	c2.WriteJSON(map[string]any{"type": "hello", "cursors": map[string]int64{sess.ID: lastSeen}})
	got = readUntil(t, c2, func(m wsMsg) bool { return m.Type == "ready" })
	prev := lastSeen
	for _, m := range got[:len(got)-1] {
		if m.Seq != prev+1 {
			t.Fatalf("补发序号不连续 %d -> %d", prev, m.Seq)
		}
		prev = m.Seq
	}
	replayed := false
	for _, m := range got {
		if m.Type == "msg.done" && strings.Contains(string(m.Data), "echo:offline") {
			replayed = true
		}
	}
	if !replayed {
		t.Fatal("补发缺少断线期间的回复")
	}
	// 同一编号重发（网络超时后重试）只记录一次
	for i := 0; i < 2; i++ {
		if res, _ := e.do("POST", "/api/sessions/"+sess.ID+"/messages", map[string]string{"text": "dup", "clientId": "dup-1"}, nil); res.StatusCode >= 300 {
			t.Fatalf("重发应返回成功 %d", res.StatusCode)
		}
		if res, _ := e.do("POST", "/api/assistant/messages", map[string]string{"text": "dup", "clientId": "dup-2"}, nil); res.StatusCode >= 300 {
			t.Fatalf("文件传输助手重发应返回成功 %d", res.StatusCode)
		}
	}
	for sid, cid := range map[string]string{sess.ID: "dup-1", "assistant": "dup-2"} {
		_, body := e.do("GET", "/api/sessions/"+sid+"/events?after=0&limit=5000", nil, nil)
		if n := strings.Count(string(body), `"clientId":"`+cid+`"`); n != 1 {
			t.Fatalf("%s 重发的消息应只记录一次，实际 %d 次", sid, n)
		}
	}
	// 落后超过上限时不补发，手机改为按需拉取最近一段
	for i := 0; i < 1100; i++ {
		if _, err := e.a.Store.AppendEvent(context.Background(), sess.ID, "system", map[string]string{"text": "x"}); err != nil {
			t.Fatal(err)
		}
	}
	c3 := e.dial("/ws")
	defer c3.Close()
	c3.WriteJSON(map[string]any{"type": "hello", "cursors": map[string]int64{sess.ID: lastSeen}})
	if got = readUntil(t, c3, func(m wsMsg) bool { return m.Type == "ready" }); len(got) != 1 {
		t.Fatalf("落后太多时不应补发，实际补发 %d 条", len(got)-1)
	}
	if res, _ := e.do("POST", "/api/approvals/"+ap.ID, map[string]string{"action": "deny"}, nil); res.StatusCode != 409 {
		t.Fatal("重复审批应返回 409")
	}
	if res, _ := e.do("GET", "/api/sessions/"+sess.ID+"/diff", nil, nil); res.StatusCode != 200 {
		t.Fatal("改动接口")
	}
	if res, _ := e.do("DELETE", "/api/sessions/"+sess.ID, nil, nil); res.StatusCode != 400 {
		t.Fatal("Agent 会话不应在电脑端删除")
	}
}

/** terminalFlow：默认关闭，开启后可执行命令并通过 WebSocket 收到输出 */
func terminalFlow(t *testing.T, e *env) {
	var wsList []struct {
		ID string `json:"id"`
	}
	_, body := e.do("GET", "/api/ws", nil, nil)
	json.Unmarshal(body, &wsList)
	if res, _ := e.do("POST", "/api/sessions", map[string]any{"kind": "terminal", "workspaceId": wsList[0].ID}, nil); res.StatusCode != 403 {
		t.Fatal("终端默认应关闭")
	}
	if runtime.GOOS != "linux" {
		return
	}
	t.Setenv("SHELL", "/bin/sh")
	e.adminDo("PATCH", "/admin/api/config", map[string]any{"features": map[string]bool{"agents": true, "terminal": true, "fileEdit": true}}, nil)
	res, body := e.do("POST", "/api/sessions", map[string]any{"kind": "terminal", "workspaceId": wsList[0].ID, "cols": 100, "rows": 30, "command": "echo pd-$((6*7))"}, nil)
	var sess struct {
		ID string `json:"id"`
	}
	json.Unmarshal(body, &sess)
	if res.StatusCode != 201 {
		t.Fatalf("新建终端 %d %s", res.StatusCode, body)
	}
	c := e.dial("/term/" + sess.ID)
	c.WriteMessage(websocket.TextMessage, []byte(`{"type":"resize","cols":80,"rows":20}`))
	var out strings.Builder
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	for !strings.Contains(out.String(), "pd-42") {
		typ, b, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("终端输出 %q %v", out.String(), err)
		}
		if typ == websocket.BinaryMessage {
			out.Write(b)
		}
	}
	c.WriteMessage(websocket.BinaryMessage, []byte("exit\r"))
	c.Close()
	if res, _ := e.do("DELETE", "/api/sessions/"+sess.ID, nil, nil); res.StatusCode != 200 {
		t.Fatal("结束终端")
	}
}

/** adminGuardFlow：管理入口只认本机、正确 Host 与密钥 */
func adminGuardFlow(t *testing.T, e *env) {
	res, _ := http.Get(e.admin + "/admin/api/state")
	if res.StatusCode != 401 {
		t.Fatalf("无密钥 %d", res.StatusCode)
	}
	req, _ := http.NewRequest("GET", e.admin+"/admin/api/state", nil)
	req.Host = "evil.example"
	req.Header.Set("X-PD-Key", e.a.AdminKey)
	res, _ = http.DefaultClient.Do(req)
	if res.StatusCode != 403 {
		t.Fatalf("DNS 重绑定 Host 应拒绝 %d", res.StatusCode)
	}
	jar := &cookieJar{}
	cl := &http.Client{Jar: jar}
	res, _ = cl.Get(e.admin + "/?k=" + e.a.AdminKey)
	if res.StatusCode != 200 || !jar.has("pd_admin") {
		t.Fatalf("密钥换 Cookie %d", res.StatusCode)
	}
	res, _ = cl.Get(e.admin + "/admin/api/state")
	if res.StatusCode != 200 {
		t.Fatalf("Cookie 访问 %d", res.StatusCode)
	}
	res, _ = cl.Get(e.admin + "/?k=wrong")
	if res.StatusCode != 403 {
		t.Fatal("错误密钥应拒绝")
	}
	res, body := e.do("GET", "/pwa/app.js", nil, nil)
	if res.StatusCode != 200 || !bytes.Contains(body, []byte("hello")) {
		t.Fatal("应急网页脚本")
	}
	res, _ = e.do("GET", "/pwa/icons.js", nil, nil)
	if res.StatusCode != 200 {
		t.Fatal("公共图标脚本")
	}
}

/** cookieJar：最简 Cookie 容器 */
type cookieJar struct {
	mu sync.Mutex
	cs []*http.Cookie
}

func (j *cookieJar) SetCookies(_ *url.URL, cs []*http.Cookie) {
	j.mu.Lock()
	j.cs = append(j.cs, cs...)
	j.mu.Unlock()
}
func (j *cookieJar) Cookies(*url.URL) []*http.Cookie {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.cs
}
func (j *cookieJar) has(name string) bool {
	for _, c := range j.Cookies(nil) {
		if c.Name == name {
			return true
		}
	}
	return false
}

/** placesFlow：「此电脑」可浏览任意目录；用文件夹添加、移除工作区；默认工作目录；收发目录立即生效 */
func placesFlow(t *testing.T, e *env) {
	type ws struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		RootPath  string `json:"rootPath"`
		IsDefault bool   `json:"isDefault"`
		System    bool   `json:"system"`
		Home      string `json:"home"`
	}
	list := func() []ws {
		var l []ws
		_, body := e.do("GET", "/api/ws", nil, nil)
		json.Unmarshal(body, &l)
		return l
	}
	// 1、第一个是此电脑，能列出工作区之外的目录
	l := list()
	if len(l) == 0 || !l[0].System || l[0].ID != "computer" || l[0].Home == "" {
		t.Fatalf("工作区列表 %+v", l)
	}
	outside := t.TempDir()
	os.WriteFile(filepath.Join(outside, "外部.txt"), []byte("x"), 0o644)
	res, body := e.do("GET", "/api/ws/computer/list?path="+url.QueryEscape(strings.TrimPrefix(filepath.ToSlash(outside), "/")), nil, nil)
	if res.StatusCode != 200 || !strings.Contains(string(body), "外部.txt") {
		t.Fatalf("此电脑列目录 %d %s", res.StatusCode, body)
	}
	// 2、添加工作区：重复添加返回同一个，名称取文件夹名
	proj := filepath.Join(t.TempDir(), "我的项目")
	os.MkdirAll(proj, 0o755)
	var added ws
	res, body = e.do("POST", "/api/ws", map[string]string{"path": proj}, nil)
	json.Unmarshal(body, &added)
	if res.StatusCode != 201 || added.Name != "我的项目" {
		t.Fatalf("添加 %d %s", res.StatusCode, body)
	}
	if res, _ = e.do("POST", "/api/ws", map[string]string{"path": proj}, nil); res.StatusCode != 200 {
		t.Fatal("重复添加应返回已有工作区")
	}
	if res, _ = e.do("POST", "/api/ws", map[string]string{"path": "relative/dir"}, nil); res.StatusCode != 400 {
		t.Fatal("相对路径应拒绝")
	}
	// 3、默认工作目录：设为新文件夹后排在此电脑之后，且不能移除；收件目录原本跟随默认工作目录时一起更换
	e.a.Cfg.Update(func(c *config.Config) { c.Transfer.InboxDir = c.DefaultWorkspace })
	if res, body = e.do("PUT", "/api/ws/default", map[string]string{"path": proj}, nil); res.StatusCode != 200 {
		t.Fatalf("设默认 %d %s", res.StatusCode, body)
	}
	l = list()
	if len(l) < 2 || !l[1].IsDefault || l[1].RootPath != proj {
		t.Fatalf("默认工作目录 %+v", l)
	}
	if res, _ = e.do("DELETE", "/api/ws/"+l[1].ID, nil, nil); res.StatusCode != 400 {
		t.Fatal("默认工作目录不能移除")
	}
	if res, _ = e.do("DELETE", "/api/ws/computer", nil, nil); res.StatusCode != 400 {
		t.Fatal("此电脑不能移除")
	}
	other := filepath.Join(t.TempDir(), "临时")
	os.MkdirAll(other, 0o755)
	var o ws
	_, body = e.do("POST", "/api/ws", map[string]string{"path": other}, nil)
	json.Unmarshal(body, &o)
	if res, _ = e.do("DELETE", "/api/ws/"+o.ID, nil, nil); res.StatusCode != 200 {
		t.Fatal("移除工作区失败")
	}
	// 4、收件目录：查看与更换
	var dirs map[string]string
	_, body = e.do("GET", "/api/dirs", nil, nil)
	json.Unmarshal(body, &dirs)
	if dirs["inboxDir"] != proj || dirs["defaultWorkspace"] != proj {
		t.Fatalf("目录 %v", dirs)
	}
	if _, ok := dirs["outboxDir"]; ok {
		t.Fatal("不应再有发件目录")
	}
	newIn := filepath.Join(t.TempDir(), "收件")
	if res, body = e.do("PUT", "/api/dirs", map[string]string{"inboxDir": newIn}, nil); res.StatusCode != 200 || !strings.Contains(string(body), "收件") {
		t.Fatalf("更换收件目录 %d %s", res.StatusCode, body)
	}
}
