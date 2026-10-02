/**
 * 后台推送：通过 ntfy 或 Bark 转发通知，内容只包含会话类型和状态，不含代码或提示词。
 */
package notify

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

/** Config：推送配置 */
type Config struct {
	Kind  string `json:"kind"`
	URL   string `json:"url"`
	Topic string `json:"topic"`
}

/** Msg：一条通知 */
type Msg struct {
	Title string
	Body  string
	// Click：点击通知打开的地址（如 pocketdesk://open?session=…），手机 App 据此直达对应会话
	Click string
	// Urgent：需要尽快处理（待审批），推送 App 以高优先级弹出并响铃
	Urgent bool
}

/** Notifier：发送一条通知 */
type Notifier interface {
	Notify(ctx context.Context, m Msg) error
}

/** Nop：未配置推送时使用 */
type Nop struct{}

/** Notify：什么也不做 */
func (Nop) Notify(context.Context, Msg) error { return nil }

/** New：按配置创建推送器 */
func New(c Config, client *http.Client) Notifier {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	switch c.Kind {
	case "ntfy":
		if c.URL == "" {
			c.URL = "https://ntfy.sh"
		}
		if c.Topic == "" {
			return Nop{}
		}
		return &ntfy{c: c, client: client}
	case "bark":
		if c.URL == "" || c.Topic == "" {
			return Nop{}
		}
		return &bark{c: c, client: client}
	}
	return Nop{}
}

/** ntfy：POST {url}/{topic}，标题放在 Title 头，点击地址放在 Click 头，待审批用高优先级 */
type ntfy struct {
	c      Config
	client *http.Client
}

/** Notify：发送 */
func (n *ntfy) Notify(ctx context.Context, m Msg) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(n.c.URL, "/")+"/"+url.PathEscape(n.c.Topic), strings.NewReader(m.Body))
	if err != nil {
		return err
	}
	req.Header.Set("Title", mimeEncode(m.Title))
	req.Header.Set("Tags", "computer")
	if m.Click != "" {
		req.Header.Set("Click", m.Click)
	}
	if m.Urgent {
		req.Header.Set("Priority", "high")
	}
	return do(n.client, req)
}

/** bark：GET {url}/{key}/{title}/{body}，点击地址放在 url 参数，待审批设为时效性通知 */
type bark struct {
	c      Config
	client *http.Client
}

/** Notify：发送 */
func (b *bark) Notify(ctx context.Context, m Msg) error {
	q := url.Values{"group": {"PocketDesk"}}
	if m.Click != "" {
		q.Set("url", m.Click)
	}
	if m.Urgent {
		q.Set("level", "timeSensitive")
	}
	u := strings.TrimRight(b.c.URL, "/") + "/" + url.PathEscape(b.c.Topic) + "/" + url.PathEscape(m.Title) + "/" + url.PathEscape(m.Body) + "?" + q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	return do(b.client, req)
}

/** do：执行请求并检查状态码 */
func do(c *http.Client, req *http.Request) error {
	res, err := c.Do(req)
	if err != nil {
		return err
	}
	res.Body.Close()
	if res.StatusCode >= 300 {
		return fmt.Errorf("推送失败: %s", res.Status)
	}
	return nil
}

/** mimeEncode：非 ASCII 标题按 RFC 2047 编码，ntfy 支持此格式 */
func mimeEncode(s string) string {
	for _, r := range s {
		if r > 127 {
			return "=?UTF-8?B?" + b64(s) + "?="
		}
	}
	return s
}

/** b64：标准 base64 编码 */
func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
