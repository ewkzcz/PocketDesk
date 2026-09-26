/**
 * 事件推送中心：把会话事件与全局事件广播给所有在线连接，慢连接直接断开由客户端按序号补拉。
 */
package hub

import (
	"encoding/json"
	"sync"
)

/** Message：推送给手机的一条消息 */
type Message struct {
	Session string          `json:"session,omitempty"`
	Seq     int64           `json:"seq,omitempty"`
	Type    string          `json:"type"`
	Data    json.RawMessage `json:"data"`
}

/** Sub：一个订阅者 */
type Sub struct {
	C      chan Message
	Device string
	closed bool
}

/** Hub：广播中心 */
type Hub struct {
	mu   sync.Mutex
	subs map[*Sub]struct{}
}

/** New：创建广播中心 */
func New() *Hub { return &Hub{subs: map[*Sub]struct{}{}} }

/** Subscribe：新增订阅，buffer 为缓冲条数 */
func (h *Hub) Subscribe(device string, buffer int) *Sub {
	s := &Sub{C: make(chan Message, buffer), Device: device}
	h.mu.Lock()
	h.subs[s] = struct{}{}
	h.mu.Unlock()
	return s
}

/** Unsubscribe：取消订阅并关闭通道 */
func (h *Hub) Unsubscribe(s *Sub) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.subs[s]; ok {
		delete(h.subs, s)
		if !s.closed {
			s.closed = true
			close(s.C)
		}
	}
}

/**
 * Publish：非阻塞广播
 *
 * 处理流程：
 * 1、逐个订阅者尝试写入
 * 2、缓冲已满的订阅者被移除并关闭通道，连接随之断开
 */
func (h *Hub) Publish(m Message) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for s := range h.subs {
		select {
		// 1、写入
		case s.C <- m:
		// 2、慢连接断开
		default:
			delete(h.subs, s)
			s.closed = true
			close(s.C)
		}
	}
}

/** PublishGlobal：广播不属于具体会话的事件 */
func (h *Hub) PublishGlobal(typ string, data any) {
	raw, err := json.Marshal(data)
	if err != nil {
		return
	}
	h.Publish(Message{Type: typ, Data: raw})
}

/** Count：在线连接数 */
func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs)
}

/** Devices：在线设备 ID 集合 */
func (h *Hub) Devices() map[string]bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := map[string]bool{}
	for s := range h.subs {
		out[s.Device] = true
	}
	return out
}
