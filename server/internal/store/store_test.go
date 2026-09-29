/**
 * 存储层单元测试。
 */
package store

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

/** openTest：在临时目录打开数据库 */
func openTest(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "pd.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestDevices(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	if _, err := s.CreateDevice(ctx, Device{ID: "d1", Name: "iPhone", Platform: "ios", TokenHash: "h1"}); err != nil {
		t.Fatal(err)
	}
	d, err := s.DeviceByTokenHash(ctx, "h1")
	if err != nil || d.ID != "d1" {
		t.Fatalf("按令牌查询失败: %v %+v", err, d)
	}
	if err := s.RevokeDevice(ctx, "d1"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeviceByTokenHash(ctx, "h1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("吊销后仍可查到: %v", err)
	}
	if err := s.RevokeDevice(ctx, "none"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("吊销不存在设备应报不存在: %v", err)
	}
	list, _ := s.Devices(ctx)
	if len(list) != 1 || !list[0].Revoked {
		t.Fatalf("设备列表异常: %+v", list)
	}
}

func TestReplaceInstall(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	mk := func(id, name string) {
		if _, err := s.CreateDevice(ctx, Device{ID: id, Name: name, Platform: "android", TokenHash: "h-" + id}); err != nil {
			t.Fatal(err)
		}
	}
	mk("old-tagged", "Android 手机")
	mk("legacy", "Android 手机")
	mk("other", "iPhone")
	if _, err := s.ReplaceInstall(ctx, "old-tagged", "inst-1", "Android 手机", "android"); err != nil {
		t.Fatal(err)
	}
	// 旧版没有编号的同名记录被归并，其他手机不受影响
	mk("new", "Android 手机")
	gone, err := s.ReplaceInstall(ctx, "new", "inst-1", "Android 手机", "android")
	if err != nil {
		t.Fatal(err)
	}
	if len(gone) != 1 || gone[0] != "old-tagged" {
		t.Fatalf("同一安装编号的旧记录应被替换: %v", gone)
	}
	list, _ := s.Devices(ctx)
	if len(list) != 2 {
		t.Fatalf("应剩 2 台设备: %d", len(list))
	}
}

func TestAppendEventThenKeepsOrder(t *testing.T) {
	// 并发写入同一会话时，回调（推送）顺序必须与序号一致
	s, ctx := openTest(t), context.Background()
	if _, err := s.CreateSession(ctx, Session{ID: "s1", Kind: "claude", WorkspaceID: "w", Cwd: ".", State: "idle"}); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var got []int64
	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.AppendEventThen(ctx, "s1", "msg.delta", map[string]int{}, func(e Event) {
				mu.Lock()
				got = append(got, e.Seq)
				mu.Unlock()
			}); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if len(got) != 200 {
		t.Fatalf("推送数 %d", len(got))
	}
	for i, seq := range got {
		if seq != int64(i+1) {
			t.Fatalf("推送顺序与序号不一致：第 %d 次推送序号 %d", i, seq)
		}
	}
}

func TestWorkspaces(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	if err := s.SaveWorkspace(ctx, Workspace{ID: "w1", Name: "a", RootPath: "/a"}); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveWorkspace(ctx, Workspace{ID: "w2", Name: "a", RootPath: "/b"}); !errors.Is(err, ErrDuplicate) {
		t.Fatalf("重名应报错: %v", err)
	}
	if err := s.SaveWorkspace(ctx, Workspace{ID: "w1", Name: "a2", RootPath: "/a", ReadOnly: true}); err != nil {
		t.Fatal(err)
	}
	w, _ := s.Workspace(ctx, "w1")
	if w.Name != "a2" || !w.ReadOnly {
		t.Fatalf("更新未生效: %+v", w)
	}
	if err := s.DeleteWorkspace(ctx, "w1"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Workspace(ctx, "w1"); !errors.Is(err, ErrNotFound) {
		t.Fatal("删除后仍存在")
	}
}

func TestEnsureDefaultRenamesLegacy(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	if err := s.SaveWorkspace(ctx, Workspace{ID: "d1", Name: "默认工作区", RootPath: "/old"}); err != nil {
		t.Fatal(err)
	}
	// 同一目录：旧名称改为「默认」
	w, err := s.EnsureDefault(ctx, "/old", "x")
	if err != nil || w.ID != "d1" || w.Name != DefaultWorkspaceName {
		t.Fatalf("改名异常: %+v %v", w, err)
	}
	// 换目录：沿用同一条记录
	w, err = s.EnsureDefault(ctx, "/new", "x")
	if err != nil || w.ID != "d1" || w.RootPath != "/new" || w.Name != "默认" {
		t.Fatalf("换目录异常: %+v %v", w, err)
	}
	list, _ := s.Workspaces(ctx)
	if len(list) != 1 {
		t.Fatalf("不应新增记录: %+v", list)
	}
}

func TestEventSeqContinuousUnderConcurrency(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	if _, err := s.CreateSession(ctx, Session{ID: "s1", Kind: "claude", WorkspaceID: "w", Cwd: ".", State: "idle"}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if _, err := s.AppendEvent(ctx, "s1", "msg.delta", map[string]int{"i": i}); err != nil {
				t.Error(err)
			}
		}(i)
	}
	wg.Wait()
	evs, err := s.EventsAfter(ctx, "s1", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 50 {
		t.Fatalf("事件数 %d", len(evs))
	}
	for i, e := range evs {
		if e.Seq != int64(i+1) {
			t.Fatalf("序号不连续: 第 %d 条为 %d", i, e.Seq)
		}
	}
	after, _ := s.EventsAfter(ctx, "s1", 45, 0)
	if len(after) != 5 || after[0].Seq != 46 {
		t.Fatalf("补拉结果异常: %d", len(after))
	}
	before, _ := s.EventsBefore(ctx, "s1", 11, 5)
	if len(before) != 5 || before[0].Seq != 6 || before[4].Seq != 10 {
		t.Fatalf("向前加载异常: %+v", before)
	}
	sess, _ := s.Session(ctx, "s1")
	if sess.LastSeq != 50 {
		t.Fatalf("last_seq=%d", sess.LastSeq)
	}
	if _, err := s.AppendEvent(ctx, "missing", "x", nil); !errors.Is(err, ErrNotFound) {
		t.Fatalf("向不存在会话追加应失败: %v", err)
	}
}

func TestSessionPatchAndDelete(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	s.CreateSession(ctx, Session{ID: "s1", Kind: "codex", WorkspaceID: "w", Cwd: ".", State: "idle"})
	s.CreateSession(ctx, Session{ID: "s2", Kind: "pi", WorkspaceID: "w", Cwd: ".", State: "idle"})
	pin, state := true, "running"
	x, err := s.UpdateSession(ctx, "s2", SessionPatch{Pinned: &pin, State: &state})
	if err != nil || !x.Pinned || x.State != "running" {
		t.Fatalf("补丁失败: %v %+v", err, x)
	}
	list, _ := s.Sessions(ctx)
	if list[0].ID != "s2" {
		t.Fatal("置顶会话应排第一")
	}
	s.AppendEvent(ctx, "s1", "state", nil)
	if err := s.DeleteSession(ctx, "s1"); err != nil {
		t.Fatal(err)
	}
	evs, _ := s.EventsAfter(ctx, "s1", 0, 0)
	if len(evs) != 0 {
		t.Fatal("删除会话后事件应清空")
	}
	if err := s.DeleteSession(ctx, "s1"); !errors.Is(err, ErrNotFound) {
		t.Fatal("重复删除应报不存在")
	}
}

func TestApprovalDecideOnce(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	s.CreateApproval(ctx, Approval{ID: "a1", SessionID: "s1", Request: []byte(`{"cmd":"ls"}`)})
	if err := s.DecideApproval(ctx, "a1", ApprovalAllowed, "d1"); err != nil {
		t.Fatal(err)
	}
	if err := s.DecideApproval(ctx, "a1", ApprovalDenied, "d1"); !errors.Is(err, ErrAlreadyDecided) {
		t.Fatalf("重复审批应拒绝: %v", err)
	}
	if err := s.DecideApproval(ctx, "zz", ApprovalDenied, "d1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("不存在的审批: %v", err)
	}
	a, _ := s.Approval(ctx, "a1")
	if a.Status != ApprovalAllowed || a.DecidedBy != "d1" {
		t.Fatalf("结果未保存: %+v", a)
	}
	s.AddRule(ctx, "s1", "Bash")
	s.AddRule(ctx, "s1", "Bash")
	rules, _ := s.Rules(ctx, "s1")
	if len(rules) != 1 {
		t.Fatalf("规则去重失败: %v", rules)
	}
}

func TestOutbox(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	it, err := s.UpsertOutbox(ctx, OutboxItem{ID: "o1", Path: "/x/a.txt", Name: "a.txt", Size: 1, SHA256: "h"})
	if err != nil || it.Status != OutboxPending {
		t.Fatal(err, it)
	}
	s.UpsertOutbox(ctx, OutboxItem{ID: "o2", Path: "/x/b.txt", Name: "b.txt", TargetDevice: "d2"})
	list, _ := s.PendingOutbox(ctx, "d1")
	if len(list) != 1 || list[0].ID != "o1" {
		t.Fatalf("按设备过滤失败: %+v", list)
	}
	if err := s.MarkOutboxSent(ctx, "o1", "/x/.sent/a.txt"); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkOutboxSent(ctx, "o1", "/y"); !errors.Is(err, ErrNotFound) {
		t.Fatal("重复确认应失败")
	}
	list, _ = s.PendingOutbox(ctx, "d2")
	if len(list) != 1 || list[0].ID != "o2" {
		t.Fatalf("d2 列表异常: %+v", list)
	}
}

func TestAuditUploads(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	s.Audit(ctx, "d1", "file.read", map[string]string{"path": "a"})
	list, _ := s.AuditEntries(ctx, 10)
	if len(list) != 1 || list[0].Action != "file.read" {
		t.Fatalf("审计异常: %+v", list)
	}
	u, _ := s.CreateUpload(ctx, Upload{ID: "u1", Length: 10, Metadata: "{}", Target: "inbox", DateFolder: "20261001"})
	s.SetUploadOffset(ctx, u.ID, 5)
	got, _ := s.Upload(ctx, "u1")
	if got.Offset != 5 {
		t.Fatal("偏移未保存")
	}
	stale, _ := s.StaleUploads(ctx, time.Now().Add(time.Hour).UnixMilli())
	if len(stale) != 1 {
		t.Fatal("过期上传查询失败")
	}
	s.SetUploadResult(ctx, "u1", "a.txt")
	stale, _ = s.StaleUploads(ctx, time.Now().Add(time.Hour).UnixMilli())
	if len(stale) != 0 {
		t.Fatal("已完成的上传不应算过期")
	}
}

func TestMaintainArchivesOldEvents(t *testing.T) {
	s, ctx := openTest(t), context.Background()
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	s.SetClock(func() time.Time { return base })
	s.CreateSession(ctx, Session{ID: "s1", Kind: "claude", WorkspaceID: "w", Cwd: ".", State: "idle"})
	for i := 0; i < 3; i++ {
		s.AppendEvent(ctx, "s1", "msg.done", i)
	}
	s.Audit(ctx, "d", "x", nil)
	s.SetClock(func() time.Time { return base.Add(100 * 24 * time.Hour) })
	for i := 0; i < 4; i++ {
		s.AppendEvent(ctx, "s1", "msg.done", i)
	}
	dir := t.TempDir()
	n, err := s.Maintain(ctx, dir, RetentionPolicy{EventMaxAge: 90 * 24 * time.Hour, EventMaxPerSession: 2, AuditMaxAge: 90 * 24 * time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	if n != 5 {
		t.Fatalf("应归档 5 条，实际 %d", n)
	}
	left, _ := s.EventsAfter(ctx, "s1", 0, 0)
	if len(left) != 2 || left[0].Seq != 6 {
		t.Fatalf("剩余事件异常: %+v", left)
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 1 {
		t.Fatalf("归档文件数 %d", len(files))
	}
	audit, _ := s.AuditEntries(ctx, 10)
	if len(audit) != 0 {
		t.Fatal("过期审计未清理")
	}
}

func TestOpenAddsNewColumnsToOldDatabase(t *testing.T) {
	p := filepath.Join(t.TempDir(), "old.db")
	// 旧版本的会话表没有 auto_approve 列
	old, _ := sql.Open("sqlite", "file:"+p)
	old.Exec(`CREATE TABLE sessions (id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', workspace_id TEXT NOT NULL, cwd TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', agent_session_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, last_seq INTEGER NOT NULL DEFAULT 0, preview TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)`)
	old.Exec(`INSERT INTO sessions VALUES('s1','claude','t','w','.','','','idle',0,0,'',1,1)`)
	old.Close()
	for i := 0; i < 2; i++ {
		s, err := Open(p)
		if err != nil {
			t.Fatalf("第 %d 次打开：%v", i+1, err)
		}
		got, err := s.Session(context.Background(), "s1")
		if err != nil || got.AutoApprove {
			t.Fatalf("旧会话 %+v %v", got, err)
		}
		n, _ := s.CreateSession(context.Background(), Session{ID: "s2", Kind: "claude", WorkspaceID: "w", Cwd: ".", State: "idle", AutoApprove: true})
		if got, _ := s.Session(context.Background(), n.ID); !got.AutoApprove {
			t.Fatal("免审批标记没有保存")
		}
		s.db.Exec(`DELETE FROM sessions WHERE id='s2'`)
		s.Close()
	}
}
