/**
 * 审批表与「总是允许」规则表的读写。
 */
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

/** 审批状态 */
const (
	ApprovalPending = "pending"
	ApprovalAllowed = "allowed"
	ApprovalDenied  = "denied"
	ApprovalExpired = "expired"
)

/** Approval：一次待用户确认的操作 */
type Approval struct {
	ID        string          `json:"id"`
	SessionID string          `json:"sessionId"`
	Request   json.RawMessage `json:"request"`
	Status    string          `json:"status"`
	DecidedBy string          `json:"decidedBy"`
	DecidedAt int64           `json:"decidedAt"`
	CreatedAt int64           `json:"createdAt"`
}

/** CreateApproval：登记待审批请求 */
func (s *Store) CreateApproval(ctx context.Context, a Approval) (Approval, error) {
	a.Status = ApprovalPending
	a.CreatedAt = s.nowMs()
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO approvals(id,session_id,request,status,created_at) VALUES(?,?,?,?,?)`,
		a.ID, a.SessionID, string(a.Request), a.Status, a.CreatedAt)
	return a, err
}

/** Approval：按 ID 查询 */
func (s *Store) Approval(ctx context.Context, id string) (Approval, error) {
	var a Approval
	var req string
	err := s.db.QueryRowContext(ctx,
		`SELECT id,session_id,request,status,decided_by,decided_at,created_at FROM approvals WHERE id=?`, id).
		Scan(&a.ID, &a.SessionID, &req, &a.Status, &a.DecidedBy, &a.DecidedAt, &a.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return a, ErrNotFound
	}
	a.Request = json.RawMessage(req)
	return a, err
}

/** ErrAlreadyDecided：审批已有结果 */
var ErrAlreadyDecided = errors.New("审批已处理")

/** DecideApproval：仅在待审批状态下写入结果，保证只生效一次 */
func (s *Store) DecideApproval(ctx context.Context, id, status, by string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE approvals SET status=?, decided_by=?, decided_at=? WHERE id=? AND status=?`,
		status, by, s.nowMs(), id, ApprovalPending)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		if _, err := s.Approval(ctx, id); err != nil {
			return err
		}
		return ErrAlreadyDecided
	}
	return nil
}

/** PendingApprovals：某会话尚未处理的审批 */
func (s *Store) PendingApprovals(ctx context.Context, sessionID string) ([]Approval, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id,session_id,request,status,decided_by,decided_at,created_at FROM approvals WHERE session_id=? AND status=? ORDER BY created_at`,
		sessionID, ApprovalPending)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Approval{}
	for rows.Next() {
		var a Approval
		var req string
		if err := rows.Scan(&a.ID, &a.SessionID, &req, &a.Status, &a.DecidedBy, &a.DecidedAt, &a.CreatedAt); err != nil {
			return nil, err
		}
		a.Request = json.RawMessage(req)
		out = append(out, a)
	}
	return out, rows.Err()
}

/** AddRule：记录「本会话总是允许」规则 */
func (s *Store) AddRule(ctx context.Context, sessionID, pattern string) error {
	_, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO rules(session_id,pattern) VALUES(?,?)`, sessionID, pattern)
	return err
}

/** Rules：某会话的全部规则 */
func (s *Store) Rules(ctx context.Context, sessionID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT pattern FROM rules WHERE session_id=? ORDER BY pattern`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}
