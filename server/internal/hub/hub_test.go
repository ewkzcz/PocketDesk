/**
 * 广播中心单元测试。
 */
package hub

import "testing"

func TestPublishAndSlowConsumer(t *testing.T) {
	h := New()
	fast := h.Subscribe("d1", 10)
	slow := h.Subscribe("d2", 1)
	h.PublishGlobal("host.status", map[string]int{"a": 1})
	h.PublishGlobal("host.status", map[string]int{"a": 2})
	if h.Count() != 1 {
		t.Fatalf("慢连接应被移除，剩余 %d", h.Count())
	}
	if len(fast.C) != 2 {
		t.Fatal("正常连接应收到两条")
	}
	<-slow.C
	if _, ok := <-slow.C; ok {
		t.Fatal("慢连接通道应已关闭")
	}
	if !h.Devices()["d1"] || h.Devices()["d2"] {
		t.Fatal("在线设备统计错误")
	}
	h.Unsubscribe(fast)
	h.Unsubscribe(fast)
	h.Unsubscribe(slow)
	if h.Count() != 0 {
		t.Fatal("取消订阅失败")
	}
	h.PublishGlobal("bad", func() {})
}
