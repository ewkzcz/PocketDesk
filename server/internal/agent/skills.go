/**
 * Skills：列出 Claude Code 与 Codex 已安装的 skill，查看说明，按 Agent 自带的开关启用或停用，
 * 并把选中的 skill 随下一条消息交给 Agent 使用。
 */
package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/ewkzcz/pocketdesk/server/internal/confdir"
)

/** Skill：一个已安装的 skill */
type Skill struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	// Path：SKILL.md 的绝对路径
	Path string `json:"path"`
	// Scope：user 本机全局，project 当前项目，system Agent 自带
	Scope   string `json:"scope"`
	Enabled bool   `json:"enabled"`
}

/** SkillRef：随消息使用的 skill */
type SkillRef struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

/** ErrNoSkill：没有这个 skill */
var ErrNoSkill = errors.New("没有找到这个 skill")

/** claudeSettingsMu：串行修改 Claude 用户设置 */
var claudeSettingsMu sync.Mutex

/**
 * ListSkills：某 Agent 在某目录下可用的 skill
 *
 * Claude Code：配置目录（默认 ~/.claude）下的 skills 与项目 .claude/skills 下的 SKILL.md，启用状态取用户设置里的 skillOverrides。
 * Codex：通过 app-server 的 skills/list 查询，包含启用状态。
 */
func ListSkills(ctx context.Context, kind, home, cwd string, command []string) ([]Skill, error) {
	var out []Skill
	switch kind {
	case KindClaude:
		off := claudeOverrides(home)
		add := func(root, scope string) {
			dirs, _ := os.ReadDir(root)
			for _, d := range dirs {
				p := filepath.Join(root, d.Name(), "SKILL.md")
				if _, err := os.Stat(p); err != nil {
					continue
				}
				name, desc := skillMeta(p)
				if name == "" {
					name = d.Name()
				}
				out = append(out, Skill{Name: name, Description: desc, Path: p, Scope: scope, Enabled: off[name] != "off"})
			}
		}
		add(filepath.Join(confdir.Claude(home), "skills"), "user")
		if cwd != "" && filepath.Clean(cwd) != filepath.Clean(home) {
			add(filepath.Join(cwd, ".claude", "skills"), "project")
		}
	case KindCodex:
		list, err := codexSkills(ctx, command, cwd)
		if err != nil {
			return nil, err
		}
		out = list
	default:
		return nil, ErrUnsupported
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Scope != out[j].Scope {
			return scopeRank(out[i].Scope) < scopeRank(out[j].Scope)
		}
		return out[i].Name < out[j].Name
	})
	if out == nil {
		out = []Skill{}
	}
	return out, nil
}

/** scopeRank：项目的排前面，Agent 自带的排最后 */
func scopeRank(s string) int {
	switch s {
	case "project", "repo":
		return 0
	case "user":
		return 1
	}
	return 2
}

/** skillMeta：读取 SKILL.md 开头的 name 与 description */
func skillMeta(p string) (name, desc string) {
	b, err := os.ReadFile(p)
	if err != nil {
		return "", ""
	}
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	if !sc.Scan() || strings.TrimSpace(sc.Text()) != "---" {
		return "", ""
	}
	for sc.Scan() {
		l := sc.Text()
		if strings.TrimSpace(l) == "---" {
			break
		}
		k, v, ok := strings.Cut(l, ":")
		if !ok || strings.HasPrefix(l, " ") {
			continue
		}
		v = strings.Trim(strings.TrimSpace(v), `"'`)
		switch strings.TrimSpace(k) {
		case "name":
			name = v
		case "description":
			desc = v
		}
	}
	return name, desc
}

/** claudeSettingsPath：Claude Code 用户设置文件 */
func claudeSettingsPath(home string) string {
	return filepath.Join(confdir.Claude(home), "settings.json")
}

/** claudeOverrides：用户设置里的 skillOverrides */
func claudeOverrides(home string) map[string]string {
	out := map[string]string{}
	b, err := os.ReadFile(claudeSettingsPath(home))
	if err != nil {
		return out
	}
	var s struct {
		SkillOverrides map[string]string `json:"skillOverrides"`
	}
	json.Unmarshal(b, &s)
	for k, v := range s.SkillOverrides {
		out[k] = v
	}
	return out
}

/**
 * SetSkill：启用或停用一个 skill
 *
 * Claude Code：在用户设置的 skillOverrides 中把它设为 off，启用时去掉这一项（其余设置原样保留）。
 * Codex：调用 app-server 的 skills/config/write。
 */
func SetSkill(ctx context.Context, kind, home, cwd string, command []string, name, path string, enabled bool) error {
	switch kind {
	case KindClaude:
		return setClaudeSkill(home, name, enabled)
	case KindCodex:
		return codexSkillWrite(ctx, command, cwd, path, enabled)
	}
	return ErrUnsupported
}

/** setClaudeSkill：修改 Claude 用户设置中的 skillOverrides，先写临时文件再替换 */
func setClaudeSkill(home, name string, enabled bool) error {
	claudeSettingsMu.Lock()
	defer claudeSettingsMu.Unlock()
	p := claudeSettingsPath(home)
	var s map[string]json.RawMessage
	b, err := os.ReadFile(p)
	if err == nil {
		if err := json.Unmarshal(b, &s); err != nil {
			return errors.New("Claude Code 的设置文件格式不正确，未修改")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if s == nil {
		s = map[string]json.RawMessage{}
	}
	over := map[string]string{}
	if raw, ok := s["skillOverrides"]; ok {
		json.Unmarshal(raw, &over)
	}
	if enabled {
		delete(over, name)
	} else {
		over[name] = "off"
	}
	if len(over) == 0 {
		delete(s, "skillOverrides")
	} else {
		raw, _ := json.Marshal(over)
		s["skillOverrides"] = raw
	}
	out, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp := p + ".pocketdesk-tmp"
	if err := os.WriteFile(tmp, append(out, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

/** withCodexApp：临时启动一个 app-server 完成握手后执行 fn */
func withCodexApp(ctx context.Context, command []string, fn func(c *rpcConn) error) error {
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
		return err
	}
	defer p.Close()
	c.attach(p)
	if err := c.call(ctx, "initialize", map[string]any{"clientInfo": map[string]string{"name": "pocketdesk", "version": "1.0.0"}}, nil); err != nil {
		return err
	}
	c.notify("initialized", nil)
	return fn(c)
}

/** codexSkills：skills/list，按目录返回技能 */
func codexSkills(ctx context.Context, command []string, cwd string) ([]Skill, error) {
	var out []Skill
	err := withCodexApp(ctx, command, func(c *rpcConn) error {
		params := map[string]any{"forceReload": true}
		if cwd != "" {
			params["cwds"] = []string{cwd}
		}
		var res struct {
			Data []struct {
				Skills []struct {
					Name             string `json:"name"`
					Description      string `json:"description"`
					ShortDescription string `json:"shortDescription"`
					Path             string `json:"path"`
					Scope            string `json:"scope"`
					Enabled          bool   `json:"enabled"`
				} `json:"skills"`
			} `json:"data"`
		}
		if err := c.call(ctx, "skills/list", params, &res); err != nil {
			return err
		}
		seen := map[string]bool{}
		for _, d := range res.Data {
			for _, s := range d.Skills {
				if seen[s.Path] {
					continue
				}
				seen[s.Path] = true
				desc := s.Description
				if desc == "" {
					desc = s.ShortDescription
				}
				scope := s.Scope
				if scope == "repo" {
					scope = "project"
				}
				out = append(out, Skill{Name: s.Name, Description: desc, Path: s.Path, Scope: scope, Enabled: s.Enabled})
			}
		}
		return nil
	})
	return out, err
}

/** codexSkillWrite：skills/config/write，按路径启用或停用 */
func codexSkillWrite(ctx context.Context, command []string, _ string, path string, enabled bool) error {
	return withCodexApp(ctx, command, func(c *rpcConn) error {
		return c.call(ctx, "skills/config/write", map[string]any{"path": path, "enabled": enabled}, nil)
	})
}

/** ReadSkill：读取 SKILL.md 全文，只允许读取列表中的 skill */
func ReadSkill(list []Skill, path string) (string, error) {
	for _, s := range list {
		if s.Path == path {
			b, err := os.ReadFile(path)
			if err != nil {
				return "", err
			}
			if len(b) > 512<<10 {
				b = b[:512<<10]
			}
			return string(b), nil
		}
	}
	return "", ErrNoSkill
}

/** SkillPrompt：不支持原生 skill 输入的 Agent，把选中的 skill 写进提示词 */
func SkillPrompt(kind string, skills []SkillRef, text string) string {
	if len(skills) == 0 {
		return text
	}
	names := make([]string, 0, len(skills))
	for _, s := range skills {
		names = append(names, s.Name)
	}
	if kind == KindClaude && len(skills) == 1 {
		// Claude Code 的 skill 可以直接以斜杠指令调用
		return "/" + skills[0].Name + " " + text
	}
	return "请使用以下 skill 完成任务：" + strings.Join(names, "、") + "\n\n" + text
}
