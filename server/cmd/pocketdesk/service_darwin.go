//go:build darwin

package main

/*
#include <stdlib.h>
#include <spawn.h>
#include <fcntl.h>
#include <sys/types.h>

extern char **environ;
int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attr, int disclaim);

// pdSpawn：以独立会话启动后台服务，并声明权限归它自己（不归启动它的窗口程序）
static int pdSpawn(const char *exe, pid_t *pid) {
	posix_spawnattr_t attr;
	posix_spawn_file_actions_t fa;
	posix_spawnattr_init(&attr);
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
	responsibility_spawnattrs_setdisclaim(&attr, 1);
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
	posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
	char *argv[] = {(char *)exe, "serve", NULL};
	int r = posix_spawn(pid, exe, &fa, &attr, argv, environ);
	posix_spawn_file_actions_destroy(&fa);
	posix_spawnattr_destroy(&attr);
	return r;
}
*/
import "C"

import (
	"fmt"
	"os"
	"unsafe"
)

/**
 * startService：启动后台服务
 *
 * 声明「权限归它自己」：系统把它当作 PocketDesk 本身，已开的屏幕录制等权限才算在它头上；
 * 同时它不会像「以应用方式打开」那样在 Dock 里出现一个一直跳动的图标。
 */
func startService(exe string) error {
	cexe := C.CString(exe)
	defer C.free(unsafe.Pointer(cexe))
	var pid C.pid_t
	if r := C.pdSpawn(cexe, &pid); r != 0 {
		return fmt.Errorf("错误码 %d", int(r))
	}
	if p, err := os.FindProcess(int(pid)); err == nil {
		go p.Wait()
	}
	return nil
}
