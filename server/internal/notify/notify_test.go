/**
 * 推送模块单元测试（本地模拟 ntfy 与 Bark 服务）。
 */
package notify

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNtfyAndBark(t *testing.T) {
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = append(got, r.Method+" "+r.URL.EscapedPath()+" "+r.Header.Get("Title")+" "+string(b))
		if strings.Contains(r.URL.Path, "fail") {
			w.WriteHeader(500)
		}
	}))
	defer srv.Close()
	ctx := context.Background()
	if err := New(Config{Kind: "ntfy", URL: srv.URL, Topic: "pd"}, nil).Notify(ctx, "CC 会话需要审批", "请在手机上处理"); err != nil {
		t.Fatal(err)
	}
	if err := New(Config{Kind: "bark", URL: srv.URL, Topic: "key"}, nil).Notify(ctx, "CX", "done"); err != nil {
		t.Fatal(err)
	}
	if err := New(Config{Kind: "ntfy", URL: srv.URL, Topic: "fail"}, nil).Notify(ctx, "a", "b"); err == nil {
		t.Fatal("服务端错误应返回错误")
	}
	if !strings.HasPrefix(got[0], "POST /pd =?UTF-8?B?") || !strings.HasSuffix(got[0], "请在手机上处理") {
		t.Fatalf("ntfy 请求 %s", got[0])
	}
	if got[1] != "GET /key/CX/done  " {
		t.Fatalf("bark 请求 %q", got[1])
	}
	if _, ok := New(Config{}, nil).(Nop); !ok {
		t.Fatal("未配置应为空推送")
	}
	if _, ok := New(Config{Kind: "ntfy"}, nil).(Nop); !ok {
		t.Fatal("缺少主题应为空推送")
	}
	if New(Config{}, nil).Notify(ctx, "", "") != nil {
		t.Fatal("空推送不应报错")
	}
}
