//go:build !darwin

package httpapi

import "errors"

/** errScreenDenied：没有屏幕录制权限（仅 macOS 会出现） */
var errScreenDenied = errors.New("没有屏幕录制权限")

/** captureScreen：其他系统暂不支持截屏 */
func captureScreen(string) error { return errors.New("这台电脑暂不支持截屏") }
