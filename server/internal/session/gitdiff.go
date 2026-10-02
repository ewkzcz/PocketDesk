/**
 * 改动清单：工作目录是 git 仓库时对比本轮前后的 numstat 与未跟踪文件，得到本轮改动；并提供单文件差异。
 */
package session

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

/** FileChange：改动清单中的一个文件 */
type FileChange struct {
	Path    string `json:"path"`
	Abs     string `json:"abs,omitempty"`
	Added   int    `json:"added"`
	Removed int    `json:"removed"`
	Status  string `json:"status"`
	Binary  bool   `json:"binary,omitempty"`
	// Ref：本轮保存的差异编号，查看差异时带上
	Ref string `json:"ref,omitempty"`
}

/** gitSnap：某一时刻的工作区状态 */
type gitSnap struct {
	repo    bool
	root    string
	tracked map[string]string
	untrack map[string]string
}

/** ErrNoDiff：没有可展示的差异 */
var ErrNoDiff = errors.New("没有可展示的差异")

/** git：执行 git 命令，5 秒超时 */
func git(ctx context.Context, dir string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir, "-c", "core.quotepath=off"}, args...)...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("%v: %s", err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

/**
 * snapshot：记录当前改动状态
 *
 * 处理流程：
 * 1、确认是 git 仓库并取仓库根目录
 * 2、读取已跟踪文件相对 HEAD 的 numstat，附带修改时间
 * 3、读取未跟踪文件，记录大小与修改时间
 */
func snapshot(ctx context.Context, cwd string) gitSnap {
	// 1、仓库
	out, err := git(ctx, cwd, "rev-parse", "--show-toplevel")
	if err != nil {
		return gitSnap{}
	}
	s := gitSnap{repo: true, root: strings.TrimSpace(string(out)), tracked: map[string]string{}, untrack: map[string]string{}}
	// 2、已跟踪
	for path, v := range numstat(ctx, s.root) {
		s.tracked[path] = v + "\t" + mtime(filepath.Join(s.root, path))
	}
	// 3、未跟踪
	if out, err := git(ctx, s.root, "ls-files", "--others", "--exclude-standard", "-z"); err == nil {
		for _, p := range strings.Split(string(out), "\x00") {
			if p != "" {
				s.untrack[p] = mtime(filepath.Join(s.root, p))
			}
		}
	}
	return s
}

/** numstat：已跟踪文件的增删行数，没有 HEAD 时对比暂存区 */
func numstat(ctx context.Context, root string) map[string]string {
	out, err := git(ctx, root, "diff", "--numstat", "HEAD")
	if err != nil {
		out, _ = git(ctx, root, "diff", "--numstat")
		cached, _ := git(ctx, root, "diff", "--numstat", "--cached")
		out = append(out, cached...)
	}
	res := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.SplitN(line, "\t", 3)
		if len(f) == 3 {
			res[f[2]] = f[0] + "\t" + f[1]
		}
	}
	return res
}

/** mtime：文件修改时间与大小，不存在时返回 gone */
func mtime(p string) string {
	info, err := os.Stat(p)
	if err != nil {
		return "gone"
	}
	return strconv.FormatInt(info.ModTime().UnixNano(), 36) + ":" + strconv.FormatInt(info.Size(), 36)
}

/**
 * changedSince：对比前后两次快照，得到本轮改动
 *
 * 处理流程：
 * 1、已跟踪文件：条目新增或变化即计入，行数取当前 numstat
 * 2、未跟踪文件：新出现或变化即计入新建，行数按文件行数估算
 * 3、按路径排序
 */
func changedSince(ctx context.Context, before gitSnap) []FileChange {
	if !before.repo {
		return nil
	}
	after := snapshot(ctx, before.root)
	var out []FileChange
	// 1、已跟踪
	cur := numstat(ctx, before.root)
	for p, v := range after.tracked {
		if before.tracked[p] == v {
			continue
		}
		fc := FileChange{Path: p, Abs: filepath.Join(before.root, p), Status: "modified"}
		counts := strings.SplitN(cur[p], "\t", 2)
		if len(counts) == 2 {
			if counts[0] == "-" {
				fc.Binary = true
			}
			fc.Added, _ = strconv.Atoi(counts[0])
			fc.Removed, _ = strconv.Atoi(counts[1])
		}
		if strings.HasPrefix(mtime(filepath.Join(before.root, p)), "gone") {
			fc.Status = "deleted"
		}
		out = append(out, fc)
	}
	// 2、未跟踪
	for p, v := range after.untrack {
		if before.untrack[p] == v {
			continue
		}
		out = append(out, FileChange{Path: p, Abs: filepath.Join(before.root, p), Added: countLines(filepath.Join(before.root, p)), Status: "added"})
	}
	// 3、排序
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

/** cumulative：当前全部未提交改动（/diff 指令） */
func cumulative(ctx context.Context, cwd string) ([]FileChange, bool) {
	s := snapshot(ctx, cwd)
	if !s.repo {
		return nil, false
	}
	empty := gitSnap{repo: true, root: s.root, tracked: map[string]string{}, untrack: map[string]string{}}
	return changedSince(ctx, empty), true
}

/** countLines：文本文件行数，大于 2MB 不统计 */
func countLines(p string) int {
	info, err := os.Stat(p)
	if err != nil || info.Size() > 2<<20 {
		return 0
	}
	b, err := os.ReadFile(p)
	if err != nil || len(b) == 0 {
		return 0
	}
	n := bytes.Count(b, []byte("\n"))
	if b[len(b)-1] != '\n' {
		n++
	}
	return n
}

/**
 * fileDiff：单个文件的差异文本
 *
 * 处理流程：
 * 1、非 git 仓库返回无差异
 * 2、未跟踪文件把全文按新增行展示
 * 3、已跟踪文件对比 HEAD，没有 HEAD 时对比暂存区
 */
func fileDiff(ctx context.Context, cwd, path string) (string, error) {
	// 1、仓库
	out, err := git(ctx, cwd, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", ErrNoDiff
	}
	root := strings.TrimSpace(string(out))
	clean := filepath.ToSlash(filepath.Clean(path))
	if strings.HasPrefix(clean, "../") || filepath.IsAbs(path) {
		return "", ErrNoDiff
	}
	// 2、未跟踪
	if out, _ := git(ctx, root, "ls-files", "--others", "--exclude-standard", "--", clean); strings.TrimSpace(string(out)) != "" {
		b, err := os.ReadFile(filepath.Join(root, clean))
		if err != nil {
			return "", err
		}
		if len(b) > 256<<10 {
			b = b[:256<<10]
		}
		var sb strings.Builder
		fmt.Fprintf(&sb, "--- /dev/null\n+++ b/%s\n", clean)
		for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
			sb.WriteString("+" + l + "\n")
		}
		return sb.String(), nil
	}
	// 3、已跟踪
	d, err := git(ctx, root, "diff", "HEAD", "--", clean)
	if err != nil {
		d, err = git(ctx, root, "diff", "--", clean)
	}
	if err != nil {
		return "", err
	}
	if len(d) == 0 {
		return "", ErrNoDiff
	}
	return string(d), nil
}

/** absWrite：写文件记录还原为绝对路径，相对路径按工作目录解析 */
func absWrite(cwd, p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Join(cwd, p)
}

/** outsideWrites：写文件记录里落在仓库之外的文件，仓库快照看不到它们 */
func outsideWrites(root string, writes map[string]bool, cwd string) []FileChange {
	var out []FileChange
	for p := range writes {
		abs := absWrite(cwd, p)
		if r, err := filepath.Rel(root, abs); err == nil && r != ".." && !strings.HasPrefix(r, ".."+string(filepath.Separator)) {
			continue
		}
		status := "modified"
		if _, err := os.Stat(abs); err != nil {
			status = "deleted"
		}
		out = append(out, FileChange{Path: abs, Abs: abs, Status: status})
	}
	return out
}
