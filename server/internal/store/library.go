/**
 * 资料库：收藏、剪切板、提示词三类条目的读写，手机与电脑共用同一份。
 */
package store

import (
	"context"
	"database/sql"
	"errors"
)

/** LibraryItem：一条资料，文字放 Body，图片与文件内容放二进制 */
type LibraryItem struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Mime      string `json:"mime"`
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	Meta      string `json:"meta"`
	Pinned    bool   `json:"pinned"`
	CreatedAt int64  `json:"createdAt"`
	UpdatedAt int64  `json:"updatedAt"`
}

/** LibraryPatch：可单独更新的字段，nil 表示不改 */
type LibraryPatch struct {
	Title  *string
	Body   *string
	Meta   *string
	Pinned *bool
}

const libraryCols = `id,kind,title,body,mime,name,size,meta,pinned,created_at,updated_at`

/** scanLibrary：读取一行资料 */
func scanLibrary(r scanner) (LibraryItem, error) {
	var x LibraryItem
	var pinned int
	err := r.Scan(&x.ID, &x.Kind, &x.Title, &x.Body, &x.Mime, &x.Name, &x.Size, &x.Meta, &pinned, &x.CreatedAt, &x.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return x, ErrNotFound
	}
	x.Pinned = pinned == 1
	return x, err
}

/** AddLibrary：新增一条资料，blob 为空表示纯文字 */
func (s *Store) AddLibrary(ctx context.Context, x LibraryItem, blob []byte) (LibraryItem, error) {
	now := s.nowMs()
	x.CreatedAt, x.UpdatedAt = now, now
	if blob != nil {
		x.Size = int64(len(blob))
	}
	var data any
	if blob != nil {
		data = blob
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO library(`+libraryCols+`,blob) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`,
		x.ID, x.Kind, x.Title, x.Body, x.Mime, x.Name, x.Size, x.Meta, boolInt(x.Pinned), x.CreatedAt, x.UpdatedAt, data)
	return x, err
}

/** Library：某一类资料，置顶优先，再按更新时间倒序 */
func (s *Store) Library(ctx context.Context, kind string, limit int) ([]LibraryItem, error) {
	if limit <= 0 || limit > 1000 {
		limit = 500
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+libraryCols+` FROM library WHERE kind=? ORDER BY pinned DESC, updated_at DESC LIMIT ?`, kind, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []LibraryItem{}
	for rows.Next() {
		x, err := scanLibrary(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, x)
	}
	return out, rows.Err()
}

/** LibraryItem：按 ID 查询 */
func (s *Store) LibraryItem(ctx context.Context, id string) (LibraryItem, error) {
	return scanLibrary(s.db.QueryRowContext(ctx, `SELECT `+libraryCols+` FROM library WHERE id=?`, id))
}

/** LibraryBlob：读取二进制内容 */
func (s *Store) LibraryBlob(ctx context.Context, id string) ([]byte, error) {
	var b []byte
	err := s.db.QueryRowContext(ctx, `SELECT blob FROM library WHERE id=?`, id).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return b, err
}

/** UpdateLibrary：按补丁更新资料 */
func (s *Store) UpdateLibrary(ctx context.Context, id string, p LibraryPatch) (LibraryItem, error) {
	var out LibraryItem
	err := s.tx(ctx, func(t *sql.Tx) error {
		cur, err := scanLibrary(t.QueryRowContext(ctx, `SELECT `+libraryCols+` FROM library WHERE id=?`, id))
		if err != nil {
			return err
		}
		if p.Title != nil {
			cur.Title = *p.Title
		}
		if p.Body != nil {
			cur.Body = *p.Body
		}
		if p.Meta != nil {
			cur.Meta = *p.Meta
		}
		if p.Pinned != nil {
			cur.Pinned = *p.Pinned
		}
		cur.UpdatedAt = s.nowMs()
		_, err = t.ExecContext(ctx, `UPDATE library SET title=?,body=?,meta=?,pinned=?,updated_at=? WHERE id=?`,
			cur.Title, cur.Body, cur.Meta, boolInt(cur.Pinned), cur.UpdatedAt, id)
		out = cur
		return err
	})
	return out, err
}

/** DeleteLibrary：删除一条资料 */
func (s *Store) DeleteLibrary(ctx context.Context, id string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM library WHERE id=?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

/** ClearLibrary：清空某一类里未置顶的资料，返回删除条数 */
func (s *Store) ClearLibrary(ctx context.Context, kind string) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM library WHERE kind=? AND pinned=0`, kind)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

/** TrimLibrary：某一类只保留最近的 keep 条（置顶的不删），用于剪切板自动清理 */
func (s *Store) TrimLibrary(ctx context.Context, kind string, keep int) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM library WHERE kind=? AND pinned=0 AND id NOT IN (SELECT id FROM library WHERE kind=? AND pinned=0 ORDER BY updated_at DESC LIMIT ?)`, kind, kind, keep)
	return err
}
