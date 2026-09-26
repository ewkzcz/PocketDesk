//go:build !darwin && !windows

/**
 * 其他系统：不做防休眠处理。
 */
package power

/** nopHolder：空实现 */
type nopHolder struct{}

/** newHolder：创建空实现 */
func newHolder() holder { return nopHolder{} }

/** Hold：无操作 */
func (nopHolder) Hold() error { return nil }

/** Release：无操作 */
func (nopHolder) Release() {}
