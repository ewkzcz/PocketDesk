/**
 * 实时通道：事件 WebSocket（按序号补发后推实时事件，25 秒心跳）与终端 WebSocket（原始字节流）。
 */
package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/ewkzcz/pocketdesk/server/internal/hub"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** 心跳参数 */
const (
	pingPeriod = 25 * time.Second
	readWait   = 60 * time.Second
	writeWait  = 10 * time.Second
)

/** upgrader：WebSocket 升级器；鉴权已由令牌完成，不再校验来源 */
var upgrader = websocket.Upgrader{
	ReadBufferSize:  16 * 1024,
	WriteBufferSize: 64 * 1024,
	CheckOrigin:     func(*http.Request) bool { return true },
}

/** wsConn：串行写的连接 */
type wsConn struct {
	c  *websocket.Conn
	mu sync.Mutex
}

/** writeJSON：写一条文本消息 */
func (w *wsConn) writeJSON(v any) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.c.SetWriteDeadline(time.Now().Add(writeWait))
	return w.c.WriteJSON(v)
}

/** writeBinary：写一条二进制消息 */
func (w *wsConn) writeBinary(b []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.c.SetWriteDeadline(time.Now().Add(writeWait))
	return w.c.WriteMessage(websocket.BinaryMessage, b)
}

/**
 * eventSocket：事件通道
 *
 * 处理流程：
 * 1、升级连接并先订阅实时事件，避免补发期间漏事件
 * 2、等待 hello，按各会话游标补发缺失事件
 * 3、转发实时事件，跳过补发中已发送过的序号
 * 4、25 秒发一次心跳，60 秒没收到任何消息判定断线
 */
func (s *Server) eventSocket(w http.ResponseWriter, r *http.Request) {
	// 1、升级与订阅
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn := &wsConn{c: c}
	defer c.Close()
	sub := s.Hub.Subscribe(deviceOf(r).ID, 1024)
	defer s.Hub.Unsubscribe(sub)
	s.Hub.PublishGlobal("host.status", map[string]any{"online": s.Hub.Devices()})
	// 2、hello 与补发
	c.SetReadDeadline(time.Now().Add(readWait))
	var hello struct {
		Type    string           `json:"type"`
		Cursors map[string]int64 `json:"cursors"`
	}
	if err := c.ReadJSON(&hello); err != nil || hello.Type != "hello" {
		return
	}
	sent := map[string]int64{}
	for sid, cur := range hello.Cursors {
		last, err := s.replay(r.Context(), conn, sid, cur)
		if err != nil {
			return
		}
		sent[sid] = last
	}
	if conn.writeJSON(map[string]any{"type": "ready", "apiVersion": APIVersion}) != nil {
		return
	}
	// 读循环：刷新超时、应答心跳
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			c.SetReadDeadline(time.Now().Add(readWait))
			var m struct {
				Type string `json:"type"`
			}
			if err := c.ReadJSON(&m); err != nil {
				return
			}
			if m.Type == "ping" {
				conn.writeJSON(map[string]string{"type": "pong"})
			}
		}
	}()
	// 3、4、实时转发与心跳
	tick := time.NewTicker(pingPeriod)
	defer tick.Stop()
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			if conn.writeJSON(map[string]string{"type": "ping"}) != nil {
				return
			}
		case m, ok := <-sub.C:
			if !ok {
				return
			}
			if m.Session != "" && m.Seq > 0 && m.Seq <= sent[m.Session] {
				continue
			}
			if m.Session != "" && m.Seq > 0 {
				sent[m.Session] = m.Seq
			}
			if conn.writeJSON(m) != nil {
				return
			}
		}
	}
}

/** replay：补发某会话 after 之后的全部事件，返回最后序号 */
func (s *Server) replay(ctx context.Context, conn *wsConn, sid string, after int64) (int64, error) {
	last := after
	for {
		evs, err := s.Store.EventsAfter(ctx, sid, last, 500)
		if err != nil {
			if err == store.ErrNotFound {
				return last, nil
			}
			return last, err
		}
		for _, e := range evs {
			if err := conn.writeJSON(hub.Message{Session: e.Session, Seq: e.Seq, Type: e.Type, Data: e.Data, CreatedAt: e.CreatedAt}); err != nil {
				return last, err
			}
			last = e.Seq
		}
		if len(evs) < 500 {
			return last, nil
		}
	}
}

/**
 * termSocket：终端通道
 *
 * 处理流程：
 * 1、检查终端开关并连接终端
 * 2、先回放缓冲，再转发实时输出
 * 3、二进制帧为键盘输入，文本帧为 resize 控制消息
 */
func (s *Server) termSocket(w http.ResponseWriter, r *http.Request) {
	// 1、连接
	if !s.Cfg.Get().Features.Terminal {
		writeJSON(w, 403, map[string]string{"code": "feature_disabled", "message": "电脑端未开启终端功能"})
		return
	}
	t, err := s.Terms.Get(r.PathValue("id"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn := &wsConn{c: c}
	defer c.Close()
	buf, ch, err := t.Attach()
	if err != nil {
		conn.writeJSON(map[string]string{"type": "exit"})
		return
	}
	defer t.Detach(ch)
	s.audit(r, "terminal.attach", map[string]string{"id": t.ID})
	// 2、回放
	for len(buf) > 0 {
		n := min(len(buf), 64*1024)
		if conn.writeBinary(buf[:n]) != nil {
			return
		}
		buf = buf[n:]
	}
	// 3、输入
	go func() {
		for {
			c.SetReadDeadline(time.Now().Add(readWait))
			typ, data, err := c.ReadMessage()
			if err != nil {
				t.Detach(ch)
				return
			}
			if typ == websocket.BinaryMessage {
				t.Input(data)
				continue
			}
			var m struct {
				Type string `json:"type"`
				Cols int    `json:"cols"`
				Rows int    `json:"rows"`
			}
			if json.Unmarshal(data, &m) != nil {
				continue
			}
			switch m.Type {
			case "resize":
				t.Resize(m.Cols, m.Rows)
			case "ping":
				conn.writeJSON(map[string]string{"type": "pong"})
			}
		}
	}()
	tick := time.NewTicker(pingPeriod)
	defer tick.Stop()
	for {
		select {
		case <-tick.C:
			if conn.writeJSON(map[string]string{"type": "ping"}) != nil {
				return
			}
		case b, ok := <-ch:
			if !ok {
				select {
				case <-t.Done():
					conn.writeJSON(map[string]string{"type": "exit"})
				default:
				}
				return
			}
			if conn.writeBinary(b) != nil {
				return
			}
		}
	}
}
