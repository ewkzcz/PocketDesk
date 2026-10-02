/**
 * 电脑上的会话记录：列出 Claude Code 与 Codex 在任意目录下的会话，读取会话里的对话，
 * 供手机接着电脑上没有聊完的会话继续，并在电脑上又聊了几句后补上新增的对话。
 */
package agent

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/confdir"
)

/** External：电脑上的一条会话 */
type External struct {
	Kind      string `json:"kind"`
	ID        string `json:"id"`
	Title     string `json:"title"`
	Cwd       string `json:"cwd"`
	UpdatedAt int64  `json:"updatedAt"`
}

/** ErrNoTranscript：找不到会话记录 */
var ErrNoTranscript = errors.New("电脑上找不到这个会话的记录")

/** fileAt：会话记录文件与修改时间 */
type fileAt struct {
	path string
	mod  time.Time
}

/**
 * ListExternal：电脑上最近的 Claude Code 与 Codex 会话，按更新时间倒序，最多 limit 条
 *
 * 处理流程：
 * 1、收集两种会话记录文件，按修改时间取最近的一批
 * 2、逐个读出会话 ID、目录与标题，没有用户消息的空会话跳过
 */
func ListExternal(home string, kinds []string, limit int) []External {
	// 1、文件
	var files []struct {
		kind string
		fileAt
	}
	for _, k := range kinds {
		for _, f := range transcriptFiles(k, home) {
			files = append(files, struct {
				kind string
				fileAt
			}{k, f})
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.After(files[j].mod) })
	// 2、读取
	out := []External{}
	for _, f := range files {
		if len(out) >= limit {
			break
		}
		var e External
		switch f.kind {
		case KindClaude:
			e = claudeExternal(f.path)
		case KindCodex:
			id, cwd, title := codexMeta(f.path)
			e = External{ID: id, Cwd: cwd, Title: title}
		}
		if e.ID == "" || e.Title == "" || e.Cwd == "" {
			continue
		}
		e.Kind, e.UpdatedAt = f.kind, f.mod.UnixMilli()
		out = append(out, e)
	}
	return out
}

/** transcriptFiles：某种 Agent 的全部会话记录文件 */
func transcriptFiles(kind, home string) []fileAt {
	var out []fileAt
	switch kind {
	case KindClaude:
		matches, _ := filepath.Glob(filepath.Join(confdir.Claude(home), "projects", "*", "*.jsonl"))
		for _, p := range matches {
			if info, err := os.Stat(p); err == nil {
				out = append(out, fileAt{p, info.ModTime()})
			}
		}
	case KindCodex:
		filepath.WalkDir(filepath.Join(confdir.Codex(home), "sessions"), func(p string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() || !strings.HasPrefix(d.Name(), "rollout-") || !strings.HasSuffix(d.Name(), ".jsonl") {
				return nil
			}
			if info, err := d.Info(); err == nil {
				out = append(out, fileAt{p, info.ModTime()})
			}
			return nil
		})
	}
	return out
}

/** claudeExternal：Claude 会话的 ID、目录与标题（自定义标题优先，其次摘要，再次第一条用户消息） */
func claudeExternal(p string) External {
	e := External{ID: strings.TrimSuffix(filepath.Base(p), ".jsonl")}
	f, err := os.Open(p)
	if err != nil {
		return e
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 16<<20)
	var first, custom string
	for i := 0; sc.Scan() && i < 400; i++ {
		var m struct {
			Type        string          `json:"type"`
			Cwd         string          `json:"cwd"`
			IsMeta      bool            `json:"isMeta"`
			IsSidechain bool            `json:"isSidechain"`
			Summary     string          `json:"summary"`
			CustomTitle string          `json:"customTitle"`
			Title       string          `json:"title"`
			Message     json.RawMessage `json:"message"`
		}
		if json.Unmarshal(sc.Bytes(), &m) != nil {
			continue
		}
		if e.Cwd == "" && m.Cwd != "" {
			e.Cwd = m.Cwd
		}
		switch m.Type {
		case "custom-title":
			custom = firstNonEmpty(m.CustomTitle, m.Title)
		case "summary":
			if custom == "" {
				custom = m.Summary
			}
		case "user":
			if first == "" && !m.IsMeta && !m.IsSidechain {
				var msg struct {
					Content any `json:"content"`
				}
				json.Unmarshal(m.Message, &msg)
				if t := strings.TrimSpace(contentString(msg.Content)); t != "" && !injected(t) {
					first = t
				}
			}
		}
		if e.Cwd != "" && first != "" && custom != "" {
			break
		}
	}
	e.Title = snippet(firstNonEmpty(custom, first))
	return e
}

/** firstNonEmpty：第一个非空字符串 */
func firstNonEmpty(xs ...string) string {
	for _, x := range xs {
		if strings.TrimSpace(x) != "" {
			return x
		}
	}
	return ""
}

/** TranscriptPath：会话记录文件位置 */
func TranscriptPath(kind, home, id string) (string, error) {
	if id == "" || strings.ContainsAny(id, `/\`) {
		return "", ErrNoTranscript
	}
	switch kind {
	case KindClaude:
		if m, _ := filepath.Glob(filepath.Join(confdir.Claude(home), "projects", "*", id+".jsonl")); len(m) > 0 {
			return m[0], nil
		}
	case KindCodex:
		var found string
		filepath.WalkDir(filepath.Join(confdir.Codex(home), "sessions"), func(p string, d fs.DirEntry, err error) error {
			if err == nil && !d.IsDir() && strings.HasSuffix(d.Name(), "-"+id+".jsonl") {
				found = p
				return fs.SkipAll
			}
			return nil
		})
		if found != "" {
			return found, nil
		}
	}
	return "", ErrNoTranscript
}

/** Entry：会话记录里的一条对话 */
type Entry struct {
	// Role：user 用户消息、assistant 回复、tool 工具调用
	Role    string
	Text    string
	Tool    string
	Kind    string
	Summary string
	Input   map[string]any
	Output  string
	IsError bool
	At      int64
	// callID：工具调用编号，用于把结果对应回调用
	callID string
}

/**
 * ReadTranscript：从 offset 处读到文件末尾，返回其中的对话和读到的位置
 *
 * 处理流程：
 * 1、从指定位置逐行读取，只处理完整的行（最后半行留到下次）
 * 2、按 Agent 类型解析为用户消息、回复与工具调用，工具结果合并到对应调用
 */
func ReadTranscript(kind, path string, offset int64) ([]Entry, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, offset, ErrNoTranscript
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return nil, offset, err
	}
	// 1、逐行
	r := bufio.NewReaderSize(f, 256*1024)
	var out []Entry
	calls := map[string]int{}
	pos := offset
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			break
		}
		pos += int64(len(line))
		// 2、解析
		var es []Entry
		switch kind {
		case KindClaude:
			es = claudeEntries(line)
		case KindCodex:
			es = codexEntries(line)
		}
		for _, e := range es {
			if e.Role == "result" {
				if i, ok := calls[e.callID]; ok {
					out[i].Output, out[i].IsError = e.Output, e.IsError
				}
				continue
			}
			if e.Role == "tool" && e.callID != "" {
				calls[e.callID] = len(out)
			}
			out = append(out, e)
		}
	}
	return out, pos, nil
}

/** parseTime：记录里的时间（RFC3339） */
func parseTime(s string) int64 {
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return t.UnixMilli()
	}
	return 0
}

/** claudeEntries：Claude 记录的一行 */
func claudeEntries(line []byte) []Entry {
	var m struct {
		Type        string `json:"type"`
		IsMeta      bool   `json:"isMeta"`
		IsSidechain bool   `json:"isSidechain"`
		Timestamp   string `json:"timestamp"`
		Message     struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &m) != nil || m.IsMeta || m.IsSidechain || (m.Type != "user" && m.Type != "assistant") {
		return nil
	}
	at := parseTime(m.Timestamp)
	var text string
	if json.Unmarshal(m.Message.Content, &text) == nil {
		if t := strings.TrimSpace(text); m.Type == "user" && t != "" && !injected(t) {
			return []Entry{{Role: "user", Text: t, At: at}}
		}
		return nil
	}
	var blocks []block
	if json.Unmarshal(m.Message.Content, &blocks) != nil {
		return nil
	}
	var out []Entry
	for _, b := range blocks {
		switch b.Type {
		case "text":
			t := strings.TrimSpace(b.Text)
			if t == "" || m.Type == "user" && injected(t) {
				continue
			}
			role := "assistant"
			if m.Type == "user" {
				role = "user"
			}
			out = append(out, Entry{Role: role, Text: t, At: at})
		case "tool_use":
			out = append(out, Entry{Role: "tool", Tool: b.Name, Kind: toolKind(b.Name), Summary: toolSummary(b.Name, b.Input), Input: b.Input, At: at, callID: b.ID})
		case "tool_result":
			out = append(out, Entry{Role: "result", Output: Truncate(contentText(b.Content), 8000), IsError: b.IsError, callID: b.ToolUseID})
		}
	}
	return out
}

/** codexEntries：Codex 记录的一行 */
func codexEntries(line []byte) []Entry {
	var m struct {
		Type      string `json:"type"`
		Timestamp string `json:"timestamp"`
		Payload   struct {
			Type      string          `json:"type"`
			Role      string          `json:"role"`
			Content   json.RawMessage `json:"content"`
			Name      string          `json:"name"`
			Arguments string          `json:"arguments"`
			Input     string          `json:"input"`
			CallID    string          `json:"call_id"`
			Output    json.RawMessage `json:"output"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &m) != nil || m.Type != "response_item" {
		return nil
	}
	p := m.Payload
	at := parseTime(m.Timestamp)
	switch p.Type {
	case "message":
		if p.Role != "user" && p.Role != "assistant" {
			return nil
		}
		var parts []struct {
			Text string `json:"text"`
		}
		json.Unmarshal(p.Content, &parts)
		var texts []string
		for _, x := range parts {
			if t := strings.TrimSpace(x.Text); t != "" && !(p.Role == "user" && injected(t)) {
				texts = append(texts, t)
			}
		}
		if len(texts) == 0 {
			return nil
		}
		return []Entry{{Role: p.Role, Text: strings.Join(texts, "\n\n"), At: at}}
	case "function_call", "custom_tool_call", "local_shell_call":
		summary := p.Name
		in := map[string]any{}
		if p.Arguments != "" {
			if json.Unmarshal([]byte(p.Arguments), &in) == nil {
				if c, ok := in["cmd"].(string); ok {
					summary = c
				} else if c, ok := in["command"].(string); ok {
					summary = c
				}
			}
		} else if p.Input != "" {
			in["input"] = Truncate(p.Input, 4000)
			if m := jsCmd.FindStringSubmatch(p.Input); m != nil {
				var c string
				if json.Unmarshal([]byte(`"`+m[1]+`"`), &c) == nil {
					summary = c
				}
			}
		}
		kind := "other"
		if p.Name == "shell" || p.Name == "exec_command" || p.Name == "exec" || p.Name == "local_shell" || summary != p.Name {
			kind = "command"
		} else if p.Name == "apply_patch" {
			kind = "edit"
		}
		return []Entry{{Role: "tool", Tool: p.Name, Kind: kind, Summary: snippetN(summary, 200), Input: in, At: at, callID: p.CallID}}
	case "function_call_output", "custom_tool_call_output":
		var s string
		if json.Unmarshal(p.Output, &s) != nil {
			var parts []struct {
				Text string `json:"text"`
			}
			json.Unmarshal(p.Output, &parts)
			var b strings.Builder
			for _, x := range parts {
				b.WriteString(x.Text)
			}
			s = b.String()
		}
		return []Entry{{Role: "result", Output: Truncate(s, 8000), callID: p.CallID}}
	}
	return nil
}

/** injected：Agent 自己塞进会话的说明（环境信息、AGENTS.md、命令包装等），不是用户说的话 */
func injected(t string) bool {
	t = strings.TrimSpace(t)
	return strings.HasPrefix(t, "<") || strings.HasPrefix(t, "# AGENTS.md instructions") || strings.Contains(t, "<INSTRUCTIONS>")
}

/** jsCmd：Codex 以脚本调用命令时，脚本里的命令文本 */
var jsCmd = regexp.MustCompile(`cmd:\s*"((?:[^"\\]|\\.)*)"`)

/** snippetN：单行化并截断到 n 个字符 */
func snippetN(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}
