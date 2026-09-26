//go:build darwin

/**
 * macOS 防休眠：通过系统自带的 caffeinate 创建电源断言，结束进程即解除。
 */
package power

import (
	"os"
	"os/exec"
	"strconv"
)

/** darwinHolder：caffeinate 子进程 */
type darwinHolder struct {
	cmd *exec.Cmd
}

/** newHolder：创建 macOS 实现 */
func newHolder() holder { return &darwinHolder{} }

/** Hold：阻止空闲休眠，服务进程退出时 caffeinate 自动结束 */
func (d *darwinHolder) Hold() error {
	cmd := exec.Command("/usr/bin/caffeinate", "-i", "-w", strconv.Itoa(os.Getpid()))
	if err := cmd.Start(); err != nil {
		return err
	}
	d.cmd = cmd
	go cmd.Wait()
	return nil
}

/** Release：结束 caffeinate */
func (d *darwinHolder) Release() {
	if d.cmd != nil && d.cmd.Process != nil {
		d.cmd.Process.Kill()
	}
	d.cmd = nil
}
