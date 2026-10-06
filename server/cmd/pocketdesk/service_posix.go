//go:build !windows && !darwin

package main

import "os/exec"

/** startService：以独立后台进程启动服务 */
func startService(exe string) error {
	c := exec.Command(exe, "serve")
	detach(c)
	if err := c.Start(); err != nil {
		return err
	}
	go c.Wait()
	return nil
}
