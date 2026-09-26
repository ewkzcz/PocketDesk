/**
 * 电脑上已有的 Agent 会话：用于 /resume 指令，从 Claude Code 与 Codex 的本地会话记录中挑选当前目录的会话。
 */
package agent

import (
	"bufio"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

/** History：一条可续聊的会话 */
type History struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	UpdatedAt int64  `json:"updatedAt"`
}

/** nonAlnum：Claude 项目目录名编码规则：非字母数字替换为 - */
var nonAlnum = regexp.MustCompile(`[^A-Za-z0-9]`)

/**
 * ListHistory：列出某目录下的历史会话，最多 limit 条，按更新时间倒序
 */
func ListHistory(kind, home, cwd string, limit int) []History {
	var out []History
	switch kind {
	case KindClaude:
		out = claudeHistory(home, cwd)
	case KindCodex:
		out = codexHistory(home, cwd)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt > out[j].UpdatedAt })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	if out == nil {
		out = []History{}
	}
	return out
}

/**
 * claudeHistory：~/.claude/projects/<编码后的目录>/<会话ID>.jsonl
 *
 * 处理流程：
 * 1、按目录编码规则找到项目目录
 * 2、每个 jsonl 取第一条用户消息作为标题
 */
func claudeHistory(home, cwd string) []History {
	// 1、项目目录
	dir := filepath.Join(home, ".claude", "projects", nonAlnum.ReplaceAllString(cwd, "-"))
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []History
	// 2、逐个读取
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		title := firstUserText(filepath.Join(dir, e.Name()), func(m map[string]any) string {
			if m["type"] == "summary" {
				s, _ := m["summary"].(string)
				return s
			}
			if m["type"] != "user" {
				return ""
			}
			msg, _ := m["message"].(map[string]any)
			return contentString(msg["content"])
		})
		out = append(out, History{ID: strings.TrimSuffix(e.Name(), ".jsonl"), Title: title, UpdatedAt: info.ModTime().UnixMilli()})
	}
	return out
}

/**
 * codexHistory：遍历 ~/.codex/sessions 下各日期目录的 rollout 记录，按 session_meta 中的 cwd 过滤
 */
func codexHistory(home, cwd string) []History {
	root := filepath.Join(home, ".codex", "sessions")
	var out []History
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasPrefix(d.Name(), "rollout-") || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil
		}
		id, fcwd, title := codexMeta(p)
		if id == "" || filepath.Clean(fcwd) != filepath.Clean(cwd) {
			return nil
		}
		info, _ := d.Info()
		out = append(out, History{ID: id, Title: title, UpdatedAt: info.ModTime().UnixMilli()})
		return nil
	})
	return out
}

/** codexMeta：读取会话 ID、目录与第一条用户消息 */
func codexMeta(p string) (id, cwd, title string) {
	f, err := os.Open(p)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 4<<20)
	for i := 0; sc.Scan() && i < 200; i++ {
		var m struct {
			Type    string         `json:"type"`
			Payload map[string]any `json:"payload"`
		}
		if json.Unmarshal(sc.Bytes(), &m) != nil {
			continue
		}
		switch m.Type {
		case "session_meta":
			id, _ = m.Payload["id"].(string)
			cwd, _ = m.Payload["cwd"].(string)
		case "response_item":
			if title == "" && m.Payload["type"] == "message" && m.Payload["role"] == "user" {
				t := contentString(m.Payload["content"])
				if !strings.HasPrefix(strings.TrimSpace(t), "<") {
					title = t
				}
			}
		}
		if id != "" && title != "" {
			break
		}
	}
	return id, cwd, snippet(title)
}

/** firstUserText：逐行读取，返回第一个非空标题 */
func firstUserText(p string, pick func(map[string]any) string) string {
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 4<<20)
	for i := 0; sc.Scan() && i < 200; i++ {
		var m map[string]any
		if json.Unmarshal(sc.Bytes(), &m) != nil {
			continue
		}
		if t := strings.TrimSpace(pick(m)); t != "" && !strings.HasPrefix(t, "<") {
			return snippet(t)
		}
	}
	return ""
}

/** contentString：字符串或内容块数组中的文本 */
func contentString(v any) string {
	switch c := v.(type) {
	case string:
		return c
	case []any:
		for _, it := range c {
			if m, ok := it.(map[string]any); ok {
				if t, ok := m["text"].(string); ok && t != "" {
					return t
				}
			}
		}
	}
	return ""
}

/** snippet：单行化并截断到 40 字 */
func snippet(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 40 {
		return string(r[:40]) + "…"
	}
	return s
}
