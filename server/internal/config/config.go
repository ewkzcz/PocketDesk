/**
 * 服务端配置：负责数据目录定位、配置文件读写与默认值填充。
 */
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
)

/** Features：可单独开关的功能 */
type Features struct {
	Agents   bool `json:"agents"`
	Terminal bool `json:"terminal"`
	FileEdit bool `json:"fileEdit"`
}

/** Transfer：传输相关设置 */
type Transfer struct {
	InboxDir         string `json:"inboxDir"`
	OutboxDir        string `json:"outboxDir"`
	UploadExpireDays int    `json:"uploadExpireDays"`
}

/** Render：Markdown 转 PDF 的渲染设置 */
type Render struct {
	PageSize string `json:"pageSize"`
	Browser  string `json:"browser"`
}

/** Notify：后台推送设置 */
type Notify struct {
	Kind  string `json:"kind"`
	URL   string `json:"url"`
	Topic string `json:"topic"`
}

/** Config：服务端全部可持久化配置 */
type Config struct {
	HostName          string              `json:"hostName"`
	Port              int                 `json:"port"`
	AdminPort         int                 `json:"adminPort"`
	Features          Features            `json:"features"`
	Transfer          Transfer            `json:"transfer"`
	Render            Render              `json:"render"`
	Notify            Notify              `json:"notify"`
	Agents            map[string][]string `json:"agents"`
	Models            map[string][]string `json:"models"`
	TerminalIdleHours int                 `json:"terminalIdleHours"`
}

/** DefaultModels：/model 指令弹出的可选模型，可在配置文件中改写 */
func DefaultModels() map[string][]string {
	return map[string][]string{
		"claude": {"sonnet", "opus", "haiku"},
		"codex":  {"gpt-5-codex", "gpt-5"},
		"pi":     {},
		"dsh":    {"deepseek-chat", "deepseek-reasoner"},
	}
}

/** DefaultAgents：各 Agent 的默认启动命令，可在配置文件中改写 */
func DefaultAgents() map[string][]string {
	return map[string][]string{
		"claude": {"claude"},
		"codex":  {"codex"},
		"pi":     {"pi"},
		"dsh":    {"dsh", "--profile", "acp"},
	}
}

/** Store：带锁的配置存取器，修改后立即写回磁盘 */
type Store struct {
	mu   sync.RWMutex
	path string
	cfg  Config
}

/**
 * 默认数据目录
 *
 * 处理流程：
 * 1、优先读取环境变量 POCKETDESK_HOME
 * 2、Windows 使用 %APPDATA%\PocketDesk
 * 3、其他系统使用 ~/PocketDesk/data
 */
func DefaultDataDir() (string, error) {
	// 1、环境变量覆盖，便于测试和便携部署
	if v := os.Getenv("POCKETDESK_HOME"); v != "" {
		return v, nil
	}
	// 2、Windows 放在漫游应用数据目录
	if runtime.GOOS == "windows" {
		if appData := os.Getenv("APPDATA"); appData != "" {
			return filepath.Join(appData, "PocketDesk"), nil
		}
	}
	// 3、其他系统放在用户主目录
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("定位用户主目录失败: %w", err)
	}
	return filepath.Join(home, "PocketDesk", "data"), nil
}

/**
 * 默认配置
 *
 * 处理流程：
 * 1、取主机名作为电脑名称
 * 2、收件、发件目录放在 ~/PocketDesk 下
 * 3、终端默认关闭，Agent 与文件编辑默认开启
 */
func Default() Config {
	// 1、电脑名称取系统主机名
	name, err := os.Hostname()
	if err != nil || name == "" {
		name = "PocketDesk"
	}
	// 2、收发目录
	home, _ := os.UserHomeDir()
	base := filepath.Join(home, "PocketDesk")
	// 3、组装默认值
	return Config{
		HostName:  name,
		Port:      8443,
		AdminPort: 8444,
		Features:  Features{Agents: true, Terminal: false, FileEdit: true},
		Transfer: Transfer{
			InboxDir:         filepath.Join(base, "Inbox"),
			OutboxDir:        filepath.Join(base, "Outbox"),
			UploadExpireDays: 7,
		},
		Render:            Render{PageSize: "mobile"},
		Agents:            DefaultAgents(),
		Models:            DefaultModels(),
		TerminalIdleHours: 24,
	}
}

/**
 * 打开配置文件，不存在时写入默认配置
 *
 * 处理流程：
 * 1、确保目录存在
 * 2、读取已有文件并在默认值基础上覆盖
 * 3、补齐非法或缺失的字段后写回
 */
func Open(path string) (*Store, error) {
	// 1、目录
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("创建配置目录失败: %w", err)
	}
	s := &Store{path: path, cfg: Default()}
	// 2、读取已有配置
	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(raw, &s.cfg); err != nil {
			return nil, fmt.Errorf("解析配置文件失败: %w", err)
		}
	case errors.Is(err, os.ErrNotExist):
	default:
		return nil, fmt.Errorf("读取配置文件失败: %w", err)
	}
	// 3、兜底并写回
	s.cfg = normalize(s.cfg)
	if err := s.save(); err != nil {
		return nil, err
	}
	return s, nil
}

/** normalize：把非法取值替换为默认值 */
func normalize(c Config) Config {
	d := Default()
	if c.HostName == "" {
		c.HostName = d.HostName
	}
	if c.Port <= 0 || c.Port > 65535 {
		c.Port = d.Port
	}
	if c.AdminPort <= 0 || c.AdminPort > 65535 || c.AdminPort == c.Port {
		c.AdminPort = d.AdminPort
	}
	if c.Transfer.InboxDir == "" {
		c.Transfer.InboxDir = d.Transfer.InboxDir
	}
	if c.Transfer.OutboxDir == "" {
		c.Transfer.OutboxDir = d.Transfer.OutboxDir
	}
	if c.Transfer.UploadExpireDays <= 0 {
		c.Transfer.UploadExpireDays = d.Transfer.UploadExpireDays
	}
	if c.Render.PageSize != "a4" {
		c.Render.PageSize = "mobile"
	}
	if c.TerminalIdleHours <= 0 {
		c.TerminalIdleHours = d.TerminalIdleHours
	}
	if c.Agents == nil {
		c.Agents = map[string][]string{}
	}
	for k, v := range d.Agents {
		if len(c.Agents[k]) == 0 {
			c.Agents[k] = v
		}
	}
	if c.Models == nil {
		c.Models = map[string][]string{}
	}
	for k, v := range d.Models {
		if _, ok := c.Models[k]; !ok {
			c.Models[k] = v
		}
	}
	if c.Notify.Kind != "ntfy" && c.Notify.Kind != "bark" {
		c.Notify.Kind = ""
	}
	return c
}

/** Get：返回配置快照 */
func (s *Store) Get() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return clone(s.cfg)
}

/** clone：深拷贝配置中的引用类型，避免调用方修改共享数据 */
func clone(c Config) Config {
	agents := make(map[string][]string, len(c.Agents))
	for k, v := range c.Agents {
		agents[k] = append([]string(nil), v...)
	}
	c.Agents = agents
	models := make(map[string][]string, len(c.Models))
	for k, v := range c.Models {
		models[k] = append([]string{}, v...)
	}
	c.Models = models
	return c
}

/**
 * Update：在锁内修改配置并落盘
 *
 * 处理流程：
 * 1、复制当前配置交给回调修改
 * 2、规范化后原子写回磁盘
 */
func (s *Store) Update(fn func(*Config)) (Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// 1、修改副本
	next := clone(s.cfg)
	fn(&next)
	// 2、规范化并落盘，失败时保留旧值
	prev := s.cfg
	s.cfg = normalize(next)
	if err := s.save(); err != nil {
		s.cfg = prev
		return prev, err
	}
	return clone(s.cfg), nil
}

/** save：先写临时文件再改名，避免写一半损坏 */
func (s *Store) save() error {
	raw, err := json.MarshalIndent(s.cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return fmt.Errorf("写入配置失败: %w", err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return fmt.Errorf("替换配置失败: %w", err)
	}
	return nil
}
