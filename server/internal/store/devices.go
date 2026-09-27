/**
 * 已配对设备表的读写。
 */
package store

import (
	"context"
	"database/sql"
	"errors"
)

/** Device：已配对的手机 */
type Device struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	TokenHash string `json:"-"`
	CreatedAt int64  `json:"createdAt"`
	LastSeen  int64  `json:"lastSeen"`
	Revoked   bool   `json:"revoked"`
}

/** CreateDevice：登记新设备 */
func (s *Store) CreateDevice(ctx context.Context, d Device) (Device, error) {
	now := s.nowMs()
	d.CreatedAt, d.LastSeen = now, now
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO devices(id,name,platform,token_hash,created_at,last_seen,revoked) VALUES(?,?,?,?,?,?,0)`,
		d.ID, d.Name, d.Platform, d.TokenHash, d.CreatedAt, d.LastSeen)
	return d, err
}

/** DeviceByTokenHash：按令牌哈希查未吊销的设备 */
func (s *Store) DeviceByTokenHash(ctx context.Context, hash string) (Device, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id,name,platform,token_hash,created_at,last_seen,revoked FROM devices WHERE token_hash=? AND revoked=0`, hash)
	return scanDevice(row)
}

/** Device：按 ID 查设备 */
func (s *Store) Device(ctx context.Context, id string) (Device, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id,name,platform,token_hash,created_at,last_seen,revoked FROM devices WHERE id=?`, id)
	return scanDevice(row)
}

/** Devices：全部设备，按最近在线倒序 */
func (s *Store) Devices(ctx context.Context) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id,name,platform,token_hash,created_at,last_seen,revoked FROM devices ORDER BY revoked, last_seen DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

/** TouchDevice：刷新最后在线时间 */
func (s *Store) TouchDevice(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE devices SET last_seen=? WHERE id=?`, s.nowMs(), id)
	return err
}

/** DeleteRevokedDevice：删除已吊销的设备记录（未吊销的不能直接删除） */
func (s *Store) DeleteRevokedDevice(ctx context.Context, id string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM devices WHERE id=? AND revoked=1`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

/** RevokeDevice：吊销设备令牌 */
func (s *Store) RevokeDevice(ctx context.Context, id string) error {
	res, err := s.db.ExecContext(ctx, `UPDATE devices SET revoked=1 WHERE id=?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

/** scanner：兼容 Row 与 Rows */
type scanner interface{ Scan(dest ...any) error }

/** scanDevice：读取一行设备记录 */
func scanDevice(r scanner) (Device, error) {
	var d Device
	var revoked int
	err := r.Scan(&d.ID, &d.Name, &d.Platform, &d.TokenHash, &d.CreatedAt, &d.LastSeen, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return d, ErrNotFound
	}
	d.Revoked = revoked == 1
	return d, err
}
