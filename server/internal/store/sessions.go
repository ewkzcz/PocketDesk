/**
 * 会话表与事件表的读写，事件序号在事务内递增保证连续。
 */
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sync"
)

/** Session：一个聊天窗口或终端会话 */
type Session struct {
	ID             string `json:"id"`
	Kind           string `json:"kind"`
	Title          string `json:"title"`
	WorkspaceID    string `json:"workspaceId"`
	Cwd            string `json:"cwd"`
	Model          string `json:"model"`
	AgentSessionID string `json:"agentSessionId"`
	State          string `json:"state"`
	Pinned         bool   `json:"pinned"`
	LastSeq        int64  `json:"lastSeq"`
	Preview        string `json:"preview"`
	CreatedAt      int64  `json:"createdAt"`
	UpdatedAt      int64  `json:"updatedAt"`
	// AutoApprove：免审批会话（快捷启动 ccs、cx 等），所有操作自动放行
	AutoApprove bool `json:"autoApprove"`
}

/** Event：会话内按序号递增的事件 */
type Event struct {
	Session   string          `json:"session"`
	Seq       int64           `json:"seq"`
	Type      string          `json:"type"`
	Data      json.RawMessage `json:"data"`
	CreatedAt int64           `json:"createdAt"`
}

const sessionCols = `id,kind,title,workspace_id,cwd,model,agent_session_id,state,pinned,last_seq,preview,created_at,updated_at,auto_approve`

/** CreateSession：新建会话 */
func (s *Store) CreateSession(ctx context.Context, x Session) (Session, error) {
	now := s.nowMs()
	x.CreatedAt, x.UpdatedAt = now, now
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions(`+sessionCols+`) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		x.ID, x.Kind, x.Title, x.WorkspaceID, x.Cwd, x.Model, x.AgentSessionID, x.State,
		boolInt(x.Pinned), x.LastSeq, x.Preview, x.CreatedAt, x.UpdatedAt, boolInt(x.AutoApprove))
	return x, err
}

/** Session：按 ID 查询 */
func (s *Store) Session(ctx context.Context, id string) (Session, error) {
	return scanSession(s.db.QueryRowContext(ctx, `SELECT `+sessionCols+` FROM sessions WHERE id=?`, id))
}

/** Sessions：全部会话，置顶优先，再按更新时间倒序 */
func (s *Store) Sessions(ctx context.Context) ([]Session, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+sessionCols+` FROM sessions ORDER BY pinned DESC, updated_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Session{}
	for rows.Next() {
		x, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

/** SessionPatch：可单独更新的字段，nil 表示不改 */
type SessionPatch struct {
	Title          *string
	Cwd            *string
	Model          *string
	AgentSessionID *string
	State          *string
	Pinned         *bool
	Preview        *string
}

/**
 * UpdateSession：按补丁更新会话
 *
 * 处理流程：
 * 1、读出当前值
 * 2、合并补丁字段
 * 3、整行写回并刷新更新时间
 */
func (s *Store) UpdateSession(ctx context.Context, id string, p SessionPatch) (Session, error) {
	var out Session
	err := s.tx(ctx, func(t *sql.Tx) error {
		// 1、当前值
		cur, err := scanSession(t.QueryRowContext(ctx, `SELECT `+sessionCols+` FROM sessions WHERE id=?`, id))
		if err != nil {
			return err
		}
		// 2、合并
		if p.Title != nil {
			cur.Title = *p.Title
		}
		if p.Cwd != nil {
			cur.Cwd = *p.Cwd
		}
		if p.Model != nil {
			cur.Model = *p.Model
		}
		if p.AgentSessionID != nil {
			cur.AgentSessionID = *p.AgentSessionID
		}
		if p.State != nil {
			cur.State = *p.State
		}
		if p.Pinned != nil {
			cur.Pinned = *p.Pinned
		}
		if p.Preview != nil {
			cur.Preview = *p.Preview
		}
		cur.UpdatedAt = s.nowMs()
		// 3、写回
		_, err = t.ExecContext(ctx,
			`UPDATE sessions SET title=?,cwd=?,model=?,agent_session_id=?,state=?,pinned=?,preview=?,updated_at=? WHERE id=?`,
			cur.Title, cur.Cwd, cur.Model, cur.AgentSessionID, cur.State, boolInt(cur.Pinned), cur.Preview, cur.UpdatedAt, id)
		out = cur
		return err
	})
	return out, err
}

/** DeleteSession：删除会话及其事件、审批、规则 */
func (s *Store) DeleteSession(ctx context.Context, id string) error {
	return s.tx(ctx, func(t *sql.Tx) error {
		res, err := t.ExecContext(ctx, `DELETE FROM sessions WHERE id=?`, id)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 0 {
			return ErrNotFound
		}
		for _, q := range []string{`DELETE FROM events WHERE session_id=?`, `DELETE FROM approvals WHERE session_id=?`, `DELETE FROM rules WHERE session_id=?`} {
			if _, err := t.ExecContext(ctx, q, id); err != nil {
				return err
			}
		}
		return nil
	})
}

/**
 * AppendEvent：追加事件并分配下一个序号
 *
 * 处理流程：
 * 1、在事务内把会话的 last_seq 加一
 * 2、用新序号写入事件
 * 3、返回带序号的事件
 */
func (s *Store) AppendEvent(ctx context.Context, sessionID, typ string, data any) (Event, error) {
	raw, err := json.Marshal(data)
	if err != nil {
		return Event{}, err
	}
	ev := Event{Session: sessionID, Type: typ, Data: raw, CreatedAt: s.nowMs()}
	err = s.tx(ctx, func(t *sql.Tx) error {
		// 1、递增序号
		if err := t.QueryRowContext(ctx,
			`UPDATE sessions SET last_seq=last_seq+1, updated_at=? WHERE id=? RETURNING last_seq`, ev.CreatedAt, sessionID).
			Scan(&ev.Seq); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return ErrNotFound
			}
			return err
		}
		// 2、写入事件
		_, err := t.ExecContext(ctx, `INSERT INTO events(session_id,seq,type,data,created_at) VALUES(?,?,?,?,?)`,
			sessionID, ev.Seq, typ, string(raw), ev.CreatedAt)
		return err
	})
	return ev, err
}

/**
 * AppendEventThen：写入事件后在同一把会话锁内执行 then（用于推送）
 * 同一会话的并发写入会按序号依次推送，手机不会先收到大序号而把小序号当成重复丢弃
 */
func (s *Store) AppendEventThen(ctx context.Context, sessionID, typ string, data any, then func(Event)) (Event, error) {
	v, _ := s.emitLocks.LoadOrStore(sessionID, &sync.Mutex{})
	mu := v.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()
	e, err := s.AppendEvent(ctx, sessionID, typ, data)
	if err == nil && then != nil {
		then(e)
	}
	return e, err
}

/** EventsAfter：取某序号之后的事件，最多 limit 条 */
func (s *Store) EventsAfter(ctx context.Context, sessionID string, after int64, limit int) ([]Event, error) {
	if limit <= 0 || limit > 5000 {
		limit = 5000
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT session_id,seq,type,data,created_at FROM events WHERE session_id=? AND seq>? ORDER BY seq LIMIT ?`,
		sessionID, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		var e Event
		var data string
		if err := rows.Scan(&e.Session, &e.Seq, &e.Type, &data, &e.CreatedAt); err != nil {
			return nil, err
		}
		e.Data = json.RawMessage(data)
		out = append(out, e)
	}
	return out, rows.Err()
}

/** EventsBefore：取某序号之前最近的 limit 条事件（升序返回），用于上滑加载 */
func (s *Store) EventsBefore(ctx context.Context, sessionID string, before int64, limit int) ([]Event, error) {
	if limit <= 0 || limit > 2000 {
		limit = 2000
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT session_id,seq,type,data,created_at FROM events WHERE session_id=? AND seq<? ORDER BY seq DESC LIMIT ?`,
		sessionID, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		var e Event
		var data string
		if err := rows.Scan(&e.Session, &e.Seq, &e.Type, &data, &e.CreatedAt); err != nil {
			return nil, err
		}
		e.Data = json.RawMessage(data)
		out = append(out, e)
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, rows.Err()
}

/** scanSession：读取一行会话记录 */
func scanSession(r scanner) (Session, error) {
	var x Session
	var pinned, auto int
	err := r.Scan(&x.ID, &x.Kind, &x.Title, &x.WorkspaceID, &x.Cwd, &x.Model, &x.AgentSessionID,
		&x.State, &pinned, &x.LastSeq, &x.Preview, &x.CreatedAt, &x.UpdatedAt, &auto)
	if errors.Is(err, sql.ErrNoRows) {
		return x, ErrNotFound
	}
	x.Pinned = pinned == 1
	x.AutoApprove = auto == 1
	return x, err
}
