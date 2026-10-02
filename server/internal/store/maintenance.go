/**
 * 数据维护：旧事件归档为压缩 JSONL，过期审计日志与改动差异清理。
 */
package store

import (
	"compress/gzip"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

/** RetentionPolicy：事件与审计的保留策略 */
type RetentionPolicy struct {
	EventMaxAge        time.Duration
	EventMaxPerSession int64
	AuditMaxAge        time.Duration
}

/** DefaultRetention：事件 90 天或每会话 5 万条，审计 90 天 */
var DefaultRetention = RetentionPolicy{
	EventMaxAge:        90 * 24 * time.Hour,
	EventMaxPerSession: 50000,
	AuditMaxAge:        90 * 24 * time.Hour,
}

/**
 * Maintain：执行一次归档与清理
 *
 * 处理流程：
 * 1、找出每个会话中超龄或超量的事件
 * 2、写入归档目录下的压缩 JSONL 文件
 * 3、从数据库删除已归档事件
 * 4、删除过期审计记录与过期的改动差异
 */
func (s *Store) Maintain(ctx context.Context, archiveDir string, p RetentionPolicy) (int, error) {
	// 1、按会话计算归档上限序号
	cutoff := s.now().Add(-p.EventMaxAge).UnixMilli()
	rows, err := s.db.QueryContext(ctx, `SELECT id,last_seq FROM sessions`)
	if err != nil {
		return 0, err
	}
	type bound struct {
		id  string
		max int64
	}
	var bounds []bound
	for rows.Next() {
		var b bound
		var last int64
		if err := rows.Scan(&b.id, &last); err != nil {
			rows.Close()
			return 0, err
		}
		b.max = last - p.EventMaxPerSession
		bounds = append(bounds, b)
	}
	rows.Close()

	archived := 0
	for _, b := range bounds {
		var ageMax sql.NullInt64
		if err := s.db.QueryRowContext(ctx, `SELECT MAX(seq) FROM events WHERE session_id=? AND created_at<?`, b.id, cutoff).Scan(&ageMax); err != nil {
			return archived, err
		}
		upto := b.max
		if ageMax.Valid && ageMax.Int64 > upto {
			upto = ageMax.Int64
		}
		if upto <= 0 {
			continue
		}
		// 2、归档
		evs, err := s.eventsUpTo(ctx, b.id, upto)
		if err != nil {
			return archived, err
		}
		if len(evs) == 0 {
			continue
		}
		if err := writeArchive(archiveDir, b.id, evs); err != nil {
			return archived, err
		}
		// 3、删除
		if _, err := s.db.ExecContext(ctx, `DELETE FROM events WHERE session_id=? AND seq<=?`, b.id, upto); err != nil {
			return archived, err
		}
		archived += len(evs)
	}
	// 4、审计与差异
	if _, err = s.db.ExecContext(ctx, `DELETE FROM audit WHERE created_at<?`, s.now().Add(-p.AuditMaxAge).UnixMilli()); err != nil {
		return archived, err
	}
	_, err = s.db.ExecContext(ctx, `DELETE FROM turn_diffs WHERE created_at<?`, cutoff)
	return archived, err
}

/** eventsUpTo：取某会话序号不超过 upto 的全部事件 */
func (s *Store) eventsUpTo(ctx context.Context, sessionID string, upto int64) ([]Event, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT session_id,seq,type,data,created_at FROM events WHERE session_id=? AND seq<=? ORDER BY seq`, sessionID, upto)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Event
	for rows.Next() {
		var e Event
		var d string
		if err := rows.Scan(&e.Session, &e.Seq, &e.Type, &d, &e.CreatedAt); err != nil {
			return nil, err
		}
		e.Data = json.RawMessage(d)
		out = append(out, e)
	}
	return out, rows.Err()
}

/** writeArchive：以会话 ID 和首尾序号命名写入 gzip JSONL */
func writeArchive(dir, sessionID string, evs []Event) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	name := fmt.Sprintf("%s-%d-%d.jsonl.gz", sessionID, evs[0].Seq, evs[len(evs)-1].Seq)
	f, err := os.Create(filepath.Join(dir, name))
	if err != nil {
		return err
	}
	zw := gzip.NewWriter(f)
	enc := json.NewEncoder(zw)
	for _, e := range evs {
		if err := enc.Encode(e); err != nil {
			zw.Close()
			f.Close()
			return err
		}
	}
	if err := zw.Close(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
