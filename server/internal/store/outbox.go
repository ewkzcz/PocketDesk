/**
 * 发件箱表的读写：记录电脑待发给手机的文件。
 */
package store

import (
	"context"
	"database/sql"
	"errors"
)

/** 发件状态 */
const (
	OutboxPending = "pending"
	OutboxSent    = "sent"
)

/** OutboxItem：一条待发文件 */
type OutboxItem struct {
	ID           string `json:"id"`
	Path         string `json:"-"`
	Name         string `json:"name"`
	Size         int64  `json:"size"`
	SHA256       string `json:"sha256"`
	TargetDevice string `json:"targetDevice"`
	Status       string `json:"status"`
	CreatedAt    int64  `json:"createdAt"`
}

const outboxCols = `id,path,name,size,sha256,target_device,status,created_at`

/** UpsertOutbox：登记待发文件；同一路径已存在时更新大小与哈希 */
func (s *Store) UpsertOutbox(ctx context.Context, it OutboxItem) (OutboxItem, error) {
	if it.CreatedAt == 0 {
		it.CreatedAt = s.nowMs()
	}
	if it.Status == "" {
		it.Status = OutboxPending
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO outbox(`+outboxCols+`) VALUES(?,?,?,?,?,?,?,?)
		 ON CONFLICT(path) DO UPDATE SET size=excluded.size, sha256=excluded.sha256, status=excluded.status, target_device=excluded.target_device`,
		it.ID, it.Path, it.Name, it.Size, it.SHA256, it.TargetDevice, it.Status, it.CreatedAt)
	if err != nil {
		return it, err
	}
	return s.OutboxByPath(ctx, it.Path)
}

/** OutboxByPath：按文件路径查询 */
func (s *Store) OutboxByPath(ctx context.Context, path string) (OutboxItem, error) {
	return scanOutbox(s.db.QueryRowContext(ctx, `SELECT `+outboxCols+` FROM outbox WHERE path=?`, path))
}

/** OutboxItem：按 ID 查询 */
func (s *Store) OutboxItem(ctx context.Context, id string) (OutboxItem, error) {
	return scanOutbox(s.db.QueryRowContext(ctx, `SELECT `+outboxCols+` FROM outbox WHERE id=?`, id))
}

/** PendingOutbox：某设备可收的待发文件（未指定目标的对所有设备可见） */
func (s *Store) PendingOutbox(ctx context.Context, deviceID string) ([]OutboxItem, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT `+outboxCols+` FROM outbox WHERE status=? AND (target_device='' OR target_device=?) ORDER BY created_at`,
		OutboxPending, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []OutboxItem{}
	for rows.Next() {
		it, err := scanOutbox(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

/** MarkOutboxSent：标记已送达并记录新路径 */
func (s *Store) MarkOutboxSent(ctx context.Context, id, newPath string) error {
	res, err := s.db.ExecContext(ctx, `UPDATE outbox SET status=?, path=? WHERE id=? AND status=?`, OutboxSent, newPath, id, OutboxPending)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

/** DeleteOutboxByPath：源文件被移走时删除记录 */
func (s *Store) DeleteOutboxByPath(ctx context.Context, path string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM outbox WHERE path=? AND status=?`, path, OutboxPending)
	return err
}

/** scanOutbox：读取一行发件记录 */
func scanOutbox(r scanner) (OutboxItem, error) {
	var it OutboxItem
	err := r.Scan(&it.ID, &it.Path, &it.Name, &it.Size, &it.SHA256, &it.TargetDevice, &it.Status, &it.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return it, ErrNotFound
	}
	return it, err
}
