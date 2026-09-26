/**
 * 工作区路径安全与文件操作单元测试。
 */
package workspace

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

/** mkTree：按路径与内容建立测试目录树 */
func mkTree(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for p, c := range files {
		full := filepath.Join(root, filepath.FromSlash(p))
		os.MkdirAll(filepath.Dir(full), 0o755)
		if strings.HasSuffix(p, "/") {
			os.MkdirAll(full, 0o755)
			continue
		}
		if err := os.WriteFile(full, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestCleanRel(t *testing.T) {
	ok := map[string]string{"": ".", ".": ".", "a/b": "a/b", "/a//b/": "a/b", `a\b`: "a/b", "a/./b": "a/b"}
	for in, want := range ok {
		got, err := CleanRel(in)
		if err != nil || got != want {
			t.Errorf("CleanRel(%q)=%q,%v", in, got, err)
		}
	}
	for _, bad := range []string{"../x", "a/../../x", "..", `..\x`, "C:/x", "a\x00b"} {
		if _, err := CleanRel(bad); err == nil {
			t.Errorf("CleanRel(%q) 应拒绝", bad)
		}
	}
}

func TestResolveBlocksSymlinkEscape(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("符号链接需要额外权限")
	}
	root := t.TempDir()
	outside := t.TempDir()
	mkTree(t, outside, map[string]string{"secret.txt": "s"})
	mkTree(t, root, map[string]string{"in.txt": "i", "sub/": ""})
	os.Symlink(outside, filepath.Join(root, "link"))
	os.Symlink(filepath.Join(root, "sub"), filepath.Join(root, "inner"))
	if _, err := Resolve(root, "link/secret.txt"); !errors.Is(err, ErrOutside) {
		t.Fatalf("符号链接越界应拒绝: %v", err)
	}
	if _, err := Resolve(root, "link/new.txt"); !errors.Is(err, ErrOutside) {
		t.Fatalf("经符号链接新建文件也应拒绝: %v", err)
	}
	if _, err := Resolve(root, "../"+filepath.Base(outside)+"/secret.txt"); !errors.Is(err, ErrOutside) {
		t.Fatalf("../ 越界应拒绝: %v", err)
	}
	p, err := Resolve(root, "inner/x.txt")
	if err != nil || !strings.HasSuffix(p, filepath.Join("sub", "x.txt")) {
		t.Fatalf("工作区内的符号链接应允许: %s %v", p, err)
	}
	if p, err := Resolve(root, "in.txt"); err != nil || filepath.Base(p) != "in.txt" {
		t.Fatal(err)
	}
}

func TestListSortsDateFoldersAndHidesDotfiles(t *testing.T) {
	root := t.TempDir()
	mkTree(t, root, map[string]string{
		"20261002/a.md": "x", "20261001/b.md": "y", "zeta/": "", "Alpha/": "",
		"b.txt": "bb", "A.txt": "a", ".hidden": "h",
	})
	list, err := List(root, "", ListOptions{})
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range list {
		names = append(names, e.Name)
	}
	want := "20261001,20261002,Alpha,zeta,A.txt,b.txt"
	if strings.Join(names, ",") != want {
		t.Fatalf("排序 %v", names)
	}
	if list[0].ChildCount != 1 || !list[0].DateFolder || list[0].Path != "20261001" {
		t.Fatalf("文件夹信息 %+v", list[0])
	}
	list, _ = List(root, "", ListOptions{Sort: "size", Desc: true, ShowHidden: true})
	if list[len(list)-1].Name != ".hidden" && list[len(list)-1].Name != "A.txt" {
		t.Fatalf("按大小倒序异常: %+v", list)
	}
	sub, _ := List(root, "20261001", ListOptions{})
	if len(sub) != 1 || sub[0].Path != "20261001/b.md" {
		t.Fatalf("子目录路径 %+v", sub)
	}
	if _, err := List(root, "b.txt", ListOptions{}); !errors.Is(err, ErrNotDir) {
		t.Fatal("对文件列目录应报错")
	}
}

func TestSaveWithIfMatch(t *testing.T) {
	root := t.TempDir()
	mkTree(t, root, map[string]string{"a.txt": "one"})
	abs := filepath.Join(root, "a.txt")
	info, _ := os.Stat(abs)
	tag := ETag(info)
	if _, err := Save(abs, strings.NewReader("x"), "", false); !errors.Is(err, ErrNeedIfMatch) {
		t.Fatal("缺少 If-Match 应拒绝")
	}
	newTag, err := Save(abs, strings.NewReader("two"), tag, false)
	if err != nil || newTag == tag {
		t.Fatalf("保存失败: %v", err)
	}
	if _, err := Save(abs, strings.NewReader("three"), tag, false); !errors.Is(err, ErrConflict) {
		t.Fatal("旧 ETag 应冲突")
	}
	b, _ := os.ReadFile(abs)
	if string(b) != "two" {
		t.Fatal("冲突时不应写入")
	}
	if _, err := Save(filepath.Join(root, "new.txt"), strings.NewReader("n"), "", false); err == nil {
		t.Fatal("不允许创建时应报错")
	}
	if _, err := Save(filepath.Join(root, "d", "new.txt"), strings.NewReader("n"), "", true); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(root)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".pd-save") {
			t.Fatal("残留临时文件")
		}
	}
}

func TestRenameMoveMkdir(t *testing.T) {
	root := t.TempDir()
	mkTree(t, root, map[string]string{"a.txt": "a", "B.txt": "b", "dir/": ""})
	if _, err := Rename(filepath.Join(root, "a.txt"), "b.txt"); !errors.Is(err, ErrExists) {
		t.Fatal("改成已有名字应拒绝")
	}
	if n, err := Rename(filepath.Join(root, "a.txt"), "A.TXT"); err != nil || n != "A.TXT" {
		t.Fatalf("仅改大小写应允许: %v", err)
	}
	if err := Move(filepath.Join(root, "A.TXT"), filepath.Join(root, "dir")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "dir", "A.TXT")); err != nil {
		t.Fatal("移动失败")
	}
	if err := Move(filepath.Join(root, "dir"), filepath.Join(root, "dir")); err == nil {
		t.Fatal("移动到自身应拒绝")
	}
	if _, err := Mkdir(root, "dir"); !errors.Is(err, ErrExists) {
		t.Fatal("同名文件夹应拒绝")
	}
	if n, err := Mkdir(root, "new:dir"); err != nil || n != "new_dir" {
		t.Fatalf("新建文件夹: %s %v", n, err)
	}
}

func TestSearch(t *testing.T) {
	root := t.TempDir()
	mkTree(t, root, map[string]string{"a/Report.md": "", "b/report-2.pdf": "", ".git/report": "", "c.txt": ""})
	res, err := Search(context.Background(), root, "REPORT", 10)
	if err != nil || len(res) != 2 {
		t.Fatalf("搜索结果 %+v %v", res, err)
	}
	res, _ = Search(context.Background(), root, "report", 1)
	if len(res) != 1 {
		t.Fatal("上限未生效")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Search(ctx, root, "r", 10); err == nil {
		t.Fatal("取消后应返回错误")
	}
	if res, _ := Search(context.Background(), root, "  ", 10); len(res) != 0 {
		t.Fatal("空关键词应无结果")
	}
}

func TestTrashMovesFile(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("只在 Linux 上验证")
	}
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	root := t.TempDir()
	mkTree(t, root, map[string]string{"x.txt": "x"})
	if err := Trash(filepath.Join(root, "x.txt")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "x.txt")); !os.IsNotExist(err) {
		t.Fatal("文件仍在原处")
	}
	mkTree(t, root, map[string]string{"x.txt": "x2"})
	if err := Trash(filepath.Join(root, "x.txt")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(os.Getenv("XDG_DATA_HOME"), "Trash", "files", "x-1.txt")); err != nil {
		t.Fatal("重名应加序号")
	}
}

func TestProtectedAndHidden(t *testing.T) {
	if !IsProtected(".pocketdesk/cache/pdf/a.pdf") || IsProtected(".pocketdesk/inbox/a") {
		t.Fatal("缓存目录判断错误")
	}
	if !IsHidden("a/.b/c") || IsHidden("a/b") {
		t.Fatal("隐藏判断错误")
	}
	_ = time.Now
}
