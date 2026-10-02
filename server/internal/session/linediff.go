/**
 * 行级差异：对比本轮改动前后的文件内容，统计增删行数并生成统一格式的差异文本（不依赖 git）。
 */
package session

import (
	"fmt"
	"strings"
)

/** diffOp：一行的对比结果 */
type diffOp struct {
	kind byte // ' ' 相同，'-' 删除，'+' 新增
	text string
}

/** splitLines：按换行拆分，末尾换行不产生空行 */
func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(strings.ReplaceAll(s, "\r\n", "\n"), "\n"), "\n")
}

/**
 * lineOps：Myers 算法求最短编辑序列
 *
 * 处理流程：
 * 1、去掉相同的首尾行，缩小比较范围
 * 2、逐步扩大编辑距离，记录每一步的最远位置
 * 3、从终点回溯得到逐行结果；差异过大时退化为整段删除加整段新增
 */
func lineOps(a, b []string) []diffOp {
	// 1、首尾相同
	pre := 0
	for pre < len(a) && pre < len(b) && a[pre] == b[pre] {
		pre++
	}
	suf := 0
	for suf < len(a)-pre && suf < len(b)-pre && a[len(a)-1-suf] == b[len(b)-1-suf] {
		suf++
	}
	var out []diffOp
	for _, l := range a[:pre] {
		out = append(out, diffOp{' ', l})
	}
	out = append(out, myers(a[pre:len(a)-suf], b[pre:len(b)-suf])...)
	for _, l := range a[len(a)-suf:] {
		out = append(out, diffOp{' ', l})
	}
	return out
}

/** maxEdit：编辑距离上限，超过后不再逐行对比 */
const maxEdit = 4000

/** myers：中间不同部分的逐行对比 */
func myers(a, b []string) []diffOp {
	n, m := len(a), len(b)
	whole := func() []diffOp {
		out := make([]diffOp, 0, n+m)
		for _, l := range a {
			out = append(out, diffOp{'-', l})
		}
		for _, l := range b {
			out = append(out, diffOp{'+', l})
		}
		return out
	}
	if n == 0 || m == 0 {
		return whole()
	}
	// 2、逐步扩大
	max := n + m
	if max > maxEdit {
		max = maxEdit
	}
	off := max + 1
	v := make([]int, 2*max+3)
	var trace [][]int
	found := false
	for d := 0; d <= max && !found; d++ {
		trace = append(trace, append([]int(nil), v...))
		for k := -d; k <= d; k += 2 {
			var x int
			if k == -d || (k != d && v[off+k-1] < v[off+k+1]) {
				x = v[off+k+1]
			} else {
				x = v[off+k-1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[off+k] = x
			if x >= n && y >= m {
				found = true
				break
			}
		}
	}
	if !found {
		return whole()
	}
	// 3、回溯
	var rev []diffOp
	x, y := n, m
	for d := len(trace) - 1; d >= 0; d-- {
		vv := trace[d]
		k := x - y
		var pk int
		if d == 0 {
			for x > 0 && y > 0 {
				rev = append(rev, diffOp{' ', a[x-1]})
				x--
				y--
			}
			break
		}
		if k == -d || (k != d && vv[off+k-1] < vv[off+k+1]) {
			pk = k + 1
		} else {
			pk = k - 1
		}
		px := vv[off+pk]
		py := px - pk
		for x > px && y > py {
			rev = append(rev, diffOp{' ', a[x-1]})
			x--
			y--
		}
		if x == px {
			rev = append(rev, diffOp{'+', b[y-1]})
			y--
		} else {
			rev = append(rev, diffOp{'-', a[x-1]})
			x--
		}
	}
	out := make([]diffOp, len(rev))
	for i := range rev {
		out[i] = rev[len(rev)-1-i]
	}
	return out
}

/**
 * unifiedDiff：生成统一格式差异，返回新增行数、删除行数与差异文本
 *
 * 处理流程：
 * 1、逐行对比
 * 2、改动行前后各保留 3 行上下文，合并相邻的块
 * 3、输出 @@ 块头与内容
 */
func unifiedDiff(name, before, after string, existed, exists bool) (added, removed int, text string) {
	// 1、对比
	ops := lineOps(splitLines(before), splitLines(after))
	for _, o := range ops {
		switch o.kind {
		case '+':
			added++
		case '-':
			removed++
		}
	}
	if added == 0 && removed == 0 {
		return 0, 0, ""
	}
	var sb strings.Builder
	from, to := "a/"+name, "b/"+name
	if !existed {
		from = "/dev/null"
	}
	if !exists {
		to = "/dev/null"
	}
	fmt.Fprintf(&sb, "--- %s\n+++ %s\n", from, to)
	// 2、分块
	const ctx = 3
	i := 0
	for i < len(ops) {
		if ops[i].kind == ' ' {
			i++
			continue
		}
		start := i - ctx
		if start < 0 {
			start = 0
		}
		end := i
		for end < len(ops) {
			if ops[end].kind != ' ' {
				end++
				continue
			}
			j := end
			for j < len(ops) && ops[j].kind == ' ' {
				j++
			}
			if j < len(ops) && j-end <= 2*ctx {
				end = j
				continue
			}
			end += ctx
			if end > len(ops) {
				end = len(ops)
			}
			break
		}
		// 3、块头
		aLine, bLine := 1, 1
		for _, o := range ops[:start] {
			if o.kind != '+' {
				aLine++
			}
			if o.kind != '-' {
				bLine++
			}
		}
		aCount, bCount := 0, 0
		for _, o := range ops[start:end] {
			if o.kind != '+' {
				aCount++
			}
			if o.kind != '-' {
				bCount++
			}
		}
		if aCount == 0 {
			aLine--
		}
		if bCount == 0 {
			bLine--
		}
		fmt.Fprintf(&sb, "@@ -%d,%d +%d,%d @@\n", aLine, aCount, bLine, bCount)
		for _, o := range ops[start:end] {
			sb.WriteByte(o.kind)
			sb.WriteString(o.text)
			sb.WriteByte('\n')
		}
		i = end
	}
	return added, removed, sb.String()
}
