//go:build windows

/**
 * Windows 删除：通过系统组件移到回收站。
 */
package workspace

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

/**
 * Trash：调用 VisualBasic 文件系统组件发送到回收站
 *
 * 处理流程：
 * 1、根据是否为目录选择 DeleteDirectory 或 DeleteFile
 * 2、以隐藏窗口方式执行 PowerShell
 */
func Trash(abs string) error {
	// 1、选择方法
	info, err := os.Stat(abs)
	if err != nil {
		return err
	}
	method := "DeleteFile"
	if info.IsDir() {
		method = "DeleteDirectory"
	}
	quoted := "'" + strings.ReplaceAll(abs, "'", "''") + "'"
	script := fmt.Sprintf("Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::%s(%s,'OnlyErrorDialogs','SendToRecycleBin')", method, quoted)
	// 2、执行
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("移到回收站失败: %v %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
