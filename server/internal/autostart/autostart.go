/**
 * 开机自启与右键发送：macOS 用户级 LaunchAgent；Windows 登录时启动的计划任务与「发送到」菜单。
 */
package autostart

/** Label：自启任务名 */
const Label = "com.pocketdesk.server"

/** Install：注册开机自启（exe 为当前可执行文件路径） */
func Install(exe, dataDir string) (string, error) { return install(exe, dataDir) }

/** Uninstall：取消开机自启 */
func Uninstall() error { return uninstall() }
