/**
 * 工作区表的读写。
 */
package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
)

/** Workspace：被授权访问的根目录 */
type Workspace struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	RootPath string `json:"rootPath"`
	ReadOnly bool   `json:"readOnly"`
}

/** ErrDuplicate：名称重复 */
var ErrDuplicate = errors.New("名称已存在")

/** SaveWorkspace：新增或更新工作区 */
func (s *Store) SaveWorkspace(ctx context.Context, w Workspace) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO workspaces(id,name,root_path,read_only) VALUES(?,?,?,?)
		 ON CONFLICT(id) DO UPDATE SET name=excluded.name, root_path=excluded.root_path, read_only=excluded.read_only`,
		w.ID, w.Name, w.RootPath, boolInt(w.ReadOnly))
	if err != nil && strings.Contains(err.Error(), "UNIQUE") {
		return ErrDuplicate
	}
	return err
}

/** Workspaces：全部工作区，按名称排序 */
func (s *Store) Workspaces(ctx context.Context) ([]Workspace, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,name,root_path,read_only FROM workspaces ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Workspace{}
	for rows.Next() {
		var w Workspace
		var ro int
		if err := rows.Scan(&w.ID, &w.Name, &w.RootPath, &ro); err != nil {
			return nil, err
		}
		w.ReadOnly = ro == 1
		out = append(out, w)
	}
	return out, rows.Err()
}

/** Workspace：按 ID 查询 */
func (s *Store) Workspace(ctx context.Context, id string) (Workspace, error) {
	var w Workspace
	var ro int
	err := s.db.QueryRowContext(ctx, `SELECT id,name,root_path,read_only FROM workspaces WHERE id=?`, id).
		Scan(&w.ID, &w.Name, &w.RootPath, &ro)
	if errors.Is(err, sql.ErrNoRows) {
		return w, ErrNotFound
	}
	w.ReadOnly = ro == 1
	return w, err
}

/** DeleteWorkspace：删除工作区配置，不动磁盘文件 */
func (s *Store) DeleteWorkspace(ctx context.Context, id string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM workspaces WHERE id=?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}
