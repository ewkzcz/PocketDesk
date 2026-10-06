//go:build darwin

/**
 * macOS 截屏：由电脑端程序自己调用系统截屏接口，权限直接算在 PocketDesk 头上。
 */
package httpapi

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa -framework CoreGraphics -framework ScreenCaptureKit
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// pdNoDock：声明这个进程是后台程序，不在 Dock 里显示图标（后台服务调用截屏接口后会被系统当成普通应用）
static void pdNoDock(void) {
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}

// pdScreenAllowed：当前进程是否已有屏幕录制权限
static int pdScreenAllowed(void) { return CGPreflightScreenCaptureAccess() ? 1 : 0; }

// pdInBundle：当前是否以 PocketDesk 应用的身份在运行（直接编译出来的调试版本不是）
static int pdInBundle(void) { return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.pocketdesk.desktop"] ? 1 : 0; }

// pdScreenRequest：向系统登记并申请屏幕录制权限（没有权限时系统会弹出授权窗口）
static void pdScreenRequest(void) { CGRequestScreenCaptureAccess(); }

// pdSave：把截到的图存成 PNG，成功返回 0
static int pdSave(CGImageRef img, const char *path) {
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
	NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
	if (!png) return 2;
	return [png writeToFile:[NSString stringWithUTF8String:path] atomically:YES] ? 0 : 3;
}

// pdCapture：用系统的屏幕捕获框架截取主显示器并存成 PNG，成功返回 0；系统版本太低返回 -1
static int pdCapture(const char *path) {
	if (@available(macOS 14.0, *)) {
		__block int result = 4;
		dispatch_semaphore_t done = dispatch_semaphore_create(0);
		[SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *err) {
			SCDisplay *main = nil;
			for (SCDisplay *d in content.displays) if (d.displayID == CGMainDisplayID()) main = d;
			if (!main) main = content.displays.firstObject;
			if (!main) { dispatch_semaphore_signal(done); return; }
			SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:main excludingWindows:@[]];
			SCStreamConfiguration *cfg = [SCStreamConfiguration new];
			CGDisplayModeRef mode = CGDisplayCopyDisplayMode(main.displayID);
			cfg.width = mode ? CGDisplayModeGetPixelWidth(mode) : main.width * 2;
			cfg.height = mode ? CGDisplayModeGetPixelHeight(mode) : main.height * 2;
			if (mode) CGDisplayModeRelease(mode);
			cfg.showsCursor = NO;
			[SCScreenshotManager captureImageWithFilter:filter configuration:cfg completionHandler:^(CGImageRef img, NSError *e) {
				if (img) result = pdSave(img, path);
				dispatch_semaphore_signal(done);
			}];
		}];
		if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) != 0) return 5;
		return result;
	}
	return -1;
}
*/
import "C"

import (
	"errors"
	"os/exec"
	"sync"
	"time"
	"unsafe"
)

/** noDock：只在第一次截屏前声明一次不要 Dock 图标 */
var noDock sync.Once

/** screenReset：上一次清理旧授权记录的时间，避免短时间内反复清理、反复弹窗 */
var (
	screenResetMu sync.Mutex
	screenResetAt time.Time
)

/**
 * requestScreenAccess：重新申请屏幕录制权限
 *
 * 系统里记着的授权对不上当前这份应用（重新安装后常见，设置里开关显示已开但实际无效）时，
 * 先清掉 PocketDesk 自己的那一条旧记录，再向系统申请，系统会重新弹出授权窗口并登记当前这份应用。
 */
func requestScreenAccess() {
	screenResetMu.Lock()
	defer screenResetMu.Unlock()
	if C.pdInBundle() == 1 && time.Since(screenResetAt) > 2*time.Minute {
		screenResetAt = time.Now()
		exec.Command("tccutil", "reset", "ScreenCapture", "com.pocketdesk.desktop").Run()
	}
	C.pdScreenRequest()
}

/** errScreenDenied：没有屏幕录制权限 */
var errScreenDenied = errors.New("没有屏幕录制权限")

/**
 * captureScreen：截取电脑屏幕存成 PNG 文件
 *
 * 处理流程：
 * 1、先问系统是否已授权；未授权就重新申请（系统会重新登记 PocketDesk 并弹窗），本次返回未授权
 * 2、已授权则直接截取主显示器
 * 3、直接截取失败时退回系统自带的截屏命令
 */
func captureScreen(file string) error {
	// 1、权限
	noDock.Do(func() { C.pdNoDock() })
	if C.pdScreenAllowed() == 0 {
		requestScreenAccess()
		return errScreenDenied
	}
	// 2、直接截取
	p := C.CString(file)
	defer C.free(unsafe.Pointer(p))
	if C.pdCapture(p) == 0 {
		return nil
	}
	// 3、系统命令兜底
	return exec.Command("screencapture", "-x", "-t", "png", file).Run()
}
