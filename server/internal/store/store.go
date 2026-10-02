/**
 * 数据库存储层：负责打开 SQLite、执行迁移，并提供各业务表的读写方法。
 */
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

/** ErrNotFound：记录不存在 */
var ErrNotFound = errors.New("记录不存在")

/** Store：数据库句柄封装 */
type Store struct {
	db  *sql.DB
	now func() time.Time

	/** 每个会话一把锁，保证事件写入与推送的顺序和序号一致 */
	emitLocks sync.Map
}

/** migrations：按顺序执行的建表语句，只追加不修改 */
var migrations = []string{
	`CREATE TABLE IF NOT EXISTS devices (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		platform TEXT NOT NULL,
		token_hash TEXT NOT NULL UNIQUE,
		created_at INTEGER NOT NULL,
		last_seen INTEGER NOT NULL,
		revoked INTEGER NOT NULL DEFAULT 0
	)`,
	`CREATE TABLE IF NOT EXISTS workspaces (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL UNIQUE,
		root_path TEXT NOT NULL,
		read_only INTEGER NOT NULL DEFAULT 0
	)`,
	`CREATE TABLE IF NOT EXISTS sessions (
		id TEXT PRIMARY KEY,
		kind TEXT NOT NULL,
		title TEXT NOT NULL DEFAULT '',
		workspace_id TEXT NOT NULL,
		cwd TEXT NOT NULL,
		model TEXT NOT NULL DEFAULT '',
		agent_session_id TEXT NOT NULL DEFAULT '',
		state TEXT NOT NULL,
		pinned INTEGER NOT NULL DEFAULT 0,
		last_seq INTEGER NOT NULL DEFAULT 0,
		preview TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS events (
		session_id TEXT NOT NULL,
		seq INTEGER NOT NULL,
		type TEXT NOT NULL,
		data TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		PRIMARY KEY (session_id, seq)
	)`,
	`CREATE TABLE IF NOT EXISTS approvals (
		id TEXT PRIMARY KEY,
		session_id TEXT NOT NULL,
		request TEXT NOT NULL,
		status TEXT NOT NULL,
		decided_by TEXT NOT NULL DEFAULT '',
		decided_at INTEGER NOT NULL DEFAULT 0,
		created_at INTEGER NOT NULL
	)`,
	`CREATE INDEX IF NOT EXISTS idx_approvals_session ON approvals(session_id, status)`,
	`CREATE TABLE IF NOT EXISTS rules (
		session_id TEXT NOT NULL,
		pattern TEXT NOT NULL,
		PRIMARY KEY (session_id, pattern)
	)`,
	`CREATE TABLE IF NOT EXISTS outbox (
		id TEXT PRIMARY KEY,
		path TEXT NOT NULL UNIQUE,
		name TEXT NOT NULL,
		size INTEGER NOT NULL,
		sha256 TEXT NOT NULL,
		target_device TEXT NOT NULL DEFAULT '',
		status TEXT NOT NULL,
		created_at INTEGER NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS audit (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		device_id TEXT NOT NULL,
		action TEXT NOT NULL,
		detail TEXT NOT NULL,
		created_at INTEGER NOT NULL
	)`,
	`CREATE INDEX IF NOT EXISTS idx_audit_time ON audit(created_at)`,
	`CREATE TABLE IF NOT EXISTS uploads (
		id TEXT PRIMARY KEY,
		length INTEGER NOT NULL,
		offset INTEGER NOT NULL,
		metadata TEXT NOT NULL,
		partial INTEGER NOT NULL DEFAULT 0,
		final_parts TEXT NOT NULL DEFAULT '',
		target TEXT NOT NULL,
		date_folder TEXT NOT NULL,
		result_name TEXT NOT NULL DEFAULT '',
		device_id TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL,
		updated_at INTEGER NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS turn_diffs (
		session_id TEXT NOT NULL,
		ref TEXT NOT NULL,
		text TEXT NOT NULL,
		created_at INTEGER NOT NULL,
		PRIMARY KEY (session_id, ref)
	)`,
}

/** columns：后来新增的列，已有数据库启动时按需补上 */
var columns = []struct{ table, name, def string }{
	{"sessions", "auto_approve", "INTEGER NOT NULL DEFAULT 0"},
	{"devices", "install_id", "TEXT NOT NULL DEFAULT ''"},
}

/**
 * 打开数据库并执行迁移
 *
 * 处理流程：
 * 1、确保数据目录存在
 * 2、打开连接并设置 WAL、忙等待、外键
 * 3、按顺序执行迁移，再补上缺少的新增列
 */
func Open(path string) (*Store, error) {
	// 1、数据目录
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("创建数据目录失败: %w", err)
	}
	// 2、连接与参数
	dsn := "file:" + filepath.ToSlash(path) + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开数据库失败: %w", err)
	}
	db.SetMaxOpenConns(1)
	// 3、迁移
	for _, m := range migrations {
		if _, err := db.Exec(m); err != nil {
			db.Close()
			return nil, fmt.Errorf("数据库迁移失败: %w", err)
		}
	}
	for _, c := range columns {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, c.table, c.name).Scan(&n); err != nil {
			db.Close()
			return nil, fmt.Errorf("数据库迁移失败: %w", err)
		}
		if n == 0 {
			if _, err := db.Exec(`ALTER TABLE ` + c.table + ` ADD COLUMN ` + c.name + ` ` + c.def); err != nil {
				db.Close()
				return nil, fmt.Errorf("数据库迁移失败: %w", err)
			}
		}
	}
	return &Store{db: db, now: time.Now}, nil
}

/** Close：关闭数据库 */
func (s *Store) Close() error { return s.db.Close() }

/** SetClock：替换时钟，仅供测试使用 */
func (s *Store) SetClock(fn func() time.Time) { s.now = fn }

/** nowMs：当前毫秒时间戳 */
func (s *Store) nowMs() int64 { return s.now().UnixMilli() }

/** tx：在事务中执行回调，出错自动回滚 */
func (s *Store) tx(ctx context.Context, fn func(*sql.Tx) error) error {
	t, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(t); err != nil {
		t.Rollback()
		return err
	}
	return t.Commit()
}

/** boolInt：布尔转整数 */
func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
