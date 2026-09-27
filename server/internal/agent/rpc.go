/**
 * JSON-RPC over stdio 公共部分：请求编号、等待响应、通知与回复，供 ACP 与 Codex app-server 驱动共用。
 */
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
)

/** rpcMsg：JSON-RPC 消息 */
type rpcMsg struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id,omitempty"`
	Method  string           `json:"method,omitempty"`
	Params  json.RawMessage  `json:"params,omitempty"`
	Result  json.RawMessage  `json:"result,omitempty"`
	Error   *rpcError        `json:"error,omitempty"`
}

/** rpcError：JSON-RPC 错误 */
type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

/** rpcConn：一条 JSON-RPC 连接，底层为逐行收发的子进程 */
type rpcConn struct {
	*lineProc
	rmu     sync.Mutex
	nextID  int
	pending map[string]chan rpcMsg
}

/** newRPCConn：创建连接，子进程稍后通过 attach 绑定 */
func newRPCConn() *rpcConn {
	return &rpcConn{pending: map[string]chan rpcMsg{}}
}

/** attach：绑定已启动的子进程 */
func (c *rpcConn) attach(p *lineProc) { c.lineProc = p }

/** call：发请求并等待响应 */
func (c *rpcConn) call(ctx context.Context, method string, params any, out any) error {
	c.rmu.Lock()
	c.nextID++
	id := fmt.Sprint(c.nextID)
	ch := make(chan rpcMsg, 1)
	c.pending[id] = ch
	c.rmu.Unlock()
	raw := json.RawMessage(id)
	pb, _ := json.Marshal(params)
	if err := c.writeJSON(rpcMsg{JSONRPC: "2.0", ID: &raw, Method: method, Params: pb}); err != nil {
		return err
	}
	select {
	case m := <-ch:
		if m.Error != nil {
			return errors.New(m.Error.Message)
		}
		if out != nil && len(m.Result) > 0 {
			return json.Unmarshal(m.Result, out)
		}
		return nil
	case <-c.Done():
		return errors.New("进程已退出")
	case <-ctx.Done():
		c.rmu.Lock()
		delete(c.pending, id)
		c.rmu.Unlock()
		return ctx.Err()
	}
}

/** notify：发通知 */
func (c *rpcConn) notify(method string, params any) error {
	pb, _ := json.Marshal(params)
	return c.writeJSON(rpcMsg{JSONRPC: "2.0", Method: method, Params: pb})
}

/** reply：回复对方请求 */
func (c *rpcConn) reply(id *json.RawMessage, result any, rerr *rpcError) {
	var rb json.RawMessage
	if result != nil {
		rb, _ = json.Marshal(result)
	}
	c.writeJSON(rpcMsg{JSONRPC: "2.0", ID: id, Result: rb, Error: rerr})
}

/** resolve：把响应交给等待中的请求 */
func (c *rpcConn) resolve(m rpcMsg) {
	c.rmu.Lock()
	ch, ok := c.pending[string(*m.ID)]
	delete(c.pending, string(*m.ID))
	c.rmu.Unlock()
	if ok {
		ch <- m
	}
}
