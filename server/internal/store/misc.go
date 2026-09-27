/**
 * 审计日志、上传记录两张表的读写。
 */
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

/** AuditEntry：一条操作审计 */
type AuditEntry struct {
	ID        int64           `json:"id"`
	DeviceID  string          `json:"deviceId"`
	Action    string          `json:"action"`
	Detail    json.RawMessage `json:"detail"`
	CreatedAt int64           `json:"createdAt"`
}

/** Audit：记录一次操作 */
func (s *Store) Audit(ctx context.Context, deviceID, action string, detail any) error {
	raw, err := json.Marshal(detail)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO audit(device_id,action,detail,created_at) VALUES(?,?,?,?)`,
		deviceID, action, string(raw), s.nowMs())
	return err
}

/** AuditEntries：最近的审计记录，倒序 */
func (s *Store) AuditEntries(ctx context.Context, limit int) ([]AuditEntry, error) {
	if limit <= 0 || limit > 1000 {
		limit = 200
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id,device_id,action,detail,created_at FROM audit ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AuditEntry{}
	for rows.Next() {
		var a AuditEntry
		var d string
		if err := rows.Scan(&a.ID, &a.DeviceID, &a.Action, &d, &a.CreatedAt); err != nil {
			return nil, err
		}
		a.Detail = json.RawMessage(d)
		out = append(out, a)
	}
	return out, rows.Err()
}

/** Upload：一次 tus 上传的服务端记录 */
type Upload struct {
	ID         string
	Length     int64
	Offset     int64
	Metadata   string
	Partial    bool
	FinalParts string
	Target     string
	DateFolder string
	ResultName string
	DeviceID   string
	CreatedAt  int64
	UpdatedAt  int64
}

const uploadCols = `id,length,offset,metadata,partial,final_parts,target,date_folder,result_name,device_id,created_at,updated_at`

/** CreateUpload：登记新上传 */
func (s *Store) CreateUpload(ctx context.Context, u Upload) (Upload, error) {
	now := s.nowMs()
	u.CreatedAt, u.UpdatedAt = now, now
	_, err := s.db.ExecContext(ctx, `INSERT INTO uploads(`+uploadCols+`) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		u.ID, u.Length, u.Offset, u.Metadata, boolInt(u.Partial), u.FinalParts, u.Target, u.DateFolder, u.ResultName, u.DeviceID, u.CreatedAt, u.UpdatedAt)
	return u, err
}

/** Upload：按 ID 查询 */
func (s *Store) Upload(ctx context.Context, id string) (Upload, error) {
	var u Upload
	var partial int
	err := s.db.QueryRowContext(ctx, `SELECT `+uploadCols+` FROM uploads WHERE id=?`, id).
		Scan(&u.ID, &u.Length, &u.Offset, &u.Metadata, &partial, &u.FinalParts, &u.Target, &u.DateFolder, &u.ResultName, &u.DeviceID, &u.CreatedAt, &u.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return u, ErrNotFound
	}
	u.Partial = partial == 1
	return u, err
}

/** SetUploadOffset：更新已收偏移 */
func (s *Store) SetUploadOffset(ctx context.Context, id string, offset int64) error {
	_, err := s.db.ExecContext(ctx, `UPDATE uploads SET offset=?, updated_at=? WHERE id=?`, offset, s.nowMs(), id)
	return err
}

/** SetUploadResult：记录最终落盘文件名 */
func (s *Store) SetUploadResult(ctx context.Context, id, name string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE uploads SET result_name=?, updated_at=? WHERE id=?`, name, s.nowMs(), id)
	return err
}

/** DeleteUpload：删除上传记录 */
func (s *Store) DeleteUpload(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM uploads WHERE id=?`, id)
	return err
}

/** StaleUploads：更新时间早于 before 且未完成的上传 */
func (s *Store) StaleUploads(ctx context.Context, before int64) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM uploads WHERE updated_at<? AND result_name=''`, before)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
