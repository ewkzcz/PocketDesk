/**
 * 可选模型：向各 Agent 实时查询当前账号可用的模型，供 /model 指令弹出。
 */
package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"strings"
	"sync"
	"time"
)

/** ModelLister：能列出可选模型的驱动 */
type ModelLister interface {
	Models(ctx context.Context, command []string) ([]string, error)
}

/** errNoModels：暂时拿不到模型列表 */
var errNoModels = errors.New("暂时无法获取模型列表")

/**
 * Models：Pi 以 --list-models 列出，每行「提供方 模型」，返回「提供方/模型」
 */
func (PiDriver) Models(ctx context.Context, command []string) ([]string, error) {
	if len(command) == 0 {
		command = []string{"pi"}
	}
	path, err := LookPath(command[0])
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, path, append(command[1:], "--list-models")...)
	cmd.Env = append(childEnv(), EnvPath()...)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	return parsePiModels(out), nil
}

/** parsePiModels：跳过表头，取前两列 */
func parsePiModels(out []byte) []string {
	var list []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	first := true
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if first {
			first = false
			if len(f) > 1 && f[0] == "provider" {
				continue
			}
		}
		if len(f) >= 2 {
			list = append(list, f[0]+"/"+f[1])
		}
	}
	return list
}

/**
 * Models：Codex 通过 app-server 的 model/list 列出，隐藏的模型不返回
 */
func (CodexDriver) Models(ctx context.Context, command []string) ([]string, error) {
	if len(command) == 0 {
		command = []string{"codex"}
	}
	c := newRPCConn()
	p, err := startLineProc(append(append([]string{}, command...), "app-server"), "", EnvPath(), func(lp *lineProc, line []byte) {
		var m rpcMsg
		if json.Unmarshal(line, &m) == nil && m.ID != nil && m.Method == "" {
			c.resolve(m)
		}
	})
	if err != nil {
		return nil, err
	}
	defer p.Close()
	c.attach(p)
	if err := c.call(ctx, "initialize", map[string]any{"clientInfo": map[string]string{"name": "pocketdesk", "version": "1.0.0"}}, nil); err != nil {
		return nil, err
	}
	c.notify("initialized", nil)
	var res struct {
		Data []struct {
			ID     string `json:"id"`
			Hidden bool   `json:"hidden"`
		} `json:"data"`
	}
	if err := c.call(ctx, "model/list", map[string]any{}, &res); err != nil {
		return nil, err
	}
	var list []string
	for _, m := range res.Data {
		if !m.Hidden {
			list = append(list, m.ID)
		}
	}
	return list, nil
}

/** acpModelCache：ACP 的可选模型只在建会话时下发，按类型缓存最近一次看到的列表 */
var acpModelCache sync.Map

/** Models：ACP 取最近一个会话下发的模型列表；还没建过会话时返回错误，由调用方退回配置 */
func (d ACPDriver) Models(context.Context, []string) ([]string, error) {
	if v, ok := acpModelCache.Load(d.Name); ok {
		return v.([]string), nil
	}
	return nil, errNoModels
}

/** acpModel：ACP 模型选项，展示名与协议取值 */
type acpModel struct {
	display string
	value   string
}

/**
 * acpModels：从 configOptions 中取出模型选项
 *
 * 处理流程：
 * 1、找到类别为 model 的选项
 * 2、展开分组；取值是字符串数组时以 / 连接作为展示名（如 deepseek-official/deepseek-v4-flash）
 */
func acpModels(raw json.RawMessage) (opts []acpModel, current string) {
	var cfg []struct {
		ID           string          `json:"id"`
		Category     string          `json:"category"`
		CurrentValue string          `json:"currentValue"`
		Options      json.RawMessage `json:"options"`
	}
	if json.Unmarshal(raw, &cfg) != nil {
		return nil, ""
	}
	type opt struct {
		Value   string `json:"value"`
		Options []opt  `json:"options"`
	}
	var walk func([]opt)
	walk = func(list []opt) {
		for _, o := range list {
			if len(o.Options) > 0 {
				walk(o.Options)
			} else if o.Value != "" {
				opts = append(opts, acpModel{display: acpModelName(o.Value), value: o.Value})
			}
		}
	}
	// 1、模型选项
	for _, c := range cfg {
		if c.Category != "model" && c.ID != "model" {
			continue
		}
		// 2、展开
		var list []opt
		json.Unmarshal(c.Options, &list)
		walk(list)
		return opts, acpModelName(c.CurrentValue)
	}
	return nil, ""
}

/** acpModelName：取值为字符串数组时以 / 连接 */
func acpModelName(v string) string {
	var parts []string
	if json.Unmarshal([]byte(v), &parts) == nil && len(parts) > 0 {
		return strings.Join(parts, "/")
	}
	return v
}

/** ModelCache：按类型缓存查询结果，避免每次弹出列表都启动一次 Agent */
type ModelCache struct {
	mu   sync.Mutex
	ttl  time.Duration
	data map[string]modelEntry
}

/** modelEntry：一次查询结果 */
type modelEntry struct {
	list []string
	at   time.Time
}

/** NewModelCache：创建缓存 */
func NewModelCache(ttl time.Duration) *ModelCache {
	return &ModelCache{ttl: ttl, data: map[string]modelEntry{}}
}

/**
 * Get：取某 Agent 的可选模型
 *
 * 处理流程：
 * 1、缓存未过期直接返回
 * 2、驱动能列出时实时查询，成功才写入缓存
 * 3、查询失败或不支持时返回 fallback
 */
func (c *ModelCache) Get(ctx context.Context, d Driver, command []string, fallback []string) []string {
	kind := d.Kind()
	// 1、缓存
	c.mu.Lock()
	if e, ok := c.data[kind]; ok && time.Since(e.at) < c.ttl {
		c.mu.Unlock()
		return e.list
	}
	c.mu.Unlock()
	// 2、查询
	if l, ok := d.(ModelLister); ok {
		if list, err := l.Models(ctx, command); err == nil && len(list) > 0 {
			c.mu.Lock()
			c.data[kind] = modelEntry{list: list, at: time.Now()}
			c.mu.Unlock()
			return list
		}
	}
	// 3、退回
	return fallback
}
