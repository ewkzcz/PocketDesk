/**
 * 工作区表的读写；另有内置的「此电脑」，从根目录起可访问电脑上的任意文件夹。
 */
package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

/** ComputerID：内置「此电脑」工作区的 ID */
const ComputerID = "computer"

/** ComputerRoot：「此电脑」的根目录，Windows 为用户文件夹所在的盘 */
func ComputerRoot() string {
	if runtime.GOOS == "windows" {
		home, _ := os.UserHomeDir()
		return filepath.VolumeName(home) + `\`
	}
	return "/"
}

/** Computer：内置的「此电脑」工作区 */
func Computer() Workspace {
	return Workspace{ID: ComputerID, Name: "此电脑", RootPath: ComputerRoot()}
}

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
	if id == ComputerID {
		return Computer(), nil
	}
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

/** DefaultWorkspaceName：默认工作目录在列表中的名称 */
const DefaultWorkspaceName = "默认"

/** legacyDefaultName：旧版默认工作目录的名称，启动时改为新名称 */
const legacyDefaultName = "默认工作区"

/**
 * EnsureDefault：把默认工作目录登记为工作区
 *
 * 处理流程：
 * 1、已有同一目录的工作区时直接返回，旧版名称改为新名称
 * 2、已有默认工作目录时改为新目录，否则新建
 */
func (s *Store) EnsureDefault(ctx context.Context, root, newID string) (Workspace, error) {
	list, err := s.Workspaces(ctx)
	if err != nil {
		return Workspace{}, err
	}
	// 1、同一目录
	for _, w := range list {
		if filepath.Clean(w.RootPath) == filepath.Clean(root) {
			if w.Name != legacyDefaultName {
				return w, nil
			}
			w.Name = DefaultWorkspaceName
			return w, s.SaveWorkspace(ctx, w)
		}
	}
	// 2、改目录或新建
	w := Workspace{ID: newID, Name: DefaultWorkspaceName, RootPath: root}
	for _, x := range list {
		if x.Name == DefaultWorkspaceName || x.Name == legacyDefaultName {
			w.ID, w.ReadOnly = x.ID, x.ReadOnly
		}
	}
	return w, s.SaveWorkspace(ctx, w)
}
