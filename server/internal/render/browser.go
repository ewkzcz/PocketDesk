/**
 * 无头浏览器打印：查找本机 Chrome 或 Edge，常驻一个实例，空闲 5 分钟后关闭。
 */
package render

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"
)

/** ErrNoBrowser：本机没有可用的浏览器 */
var ErrNoBrowser = errors.New("未找到 Chrome 或 Edge，无法生成 PDF")

/** FindBrowser：按系统查找 Chrome、Edge 或 Chromium */
func FindBrowser(configured string) string {
	if configured != "" {
		if _, err := os.Stat(configured); err == nil {
			return configured
		}
	}
	if v := os.Getenv("POCKETDESK_BROWSER"); v != "" {
		return v
	}
	var cands []string
	switch runtime.GOOS {
	case "darwin":
		home, _ := os.UserHomeDir()
		for _, base := range []string{"/Applications", filepath.Join(home, "Applications")} {
			cands = append(cands,
				filepath.Join(base, "Google Chrome.app/Contents/MacOS/Google Chrome"),
				filepath.Join(base, "Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
				filepath.Join(base, "Chromium.app/Contents/MacOS/Chromium"))
		}
	case "windows":
		for _, env := range []string{"ProgramFiles(x86)", "ProgramFiles", "LocalAppData"} {
			base := os.Getenv(env)
			if base == "" {
				continue
			}
			cands = append(cands,
				filepath.Join(base, `Microsoft\Edge\Application\msedge.exe`),
				filepath.Join(base, `Google\Chrome\Application\chrome.exe`))
		}
	default:
		for _, n := range []string{"google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge"} {
			if p, err := exec.LookPath(n); err == nil {
				cands = append(cands, p)
			}
		}
	}
	for _, c := range cands {
		if info, err := os.Stat(c); err == nil && !info.IsDir() {
			return c
		}
	}
	return ""
}

/** ChromePrinter：常驻浏览器实例 */
type ChromePrinter struct {
	find    func() string
	idle    time.Duration
	mu      sync.Mutex
	alloc   context.CancelFunc
	browser context.Context
	cancel  context.CancelFunc
	timer   *time.Timer
	active  int
}

/** NewChromePrinter：find 返回浏览器路径，空闲超过 idle 自动关闭 */
func NewChromePrinter(find func() string, idle time.Duration) *ChromePrinter {
	return &ChromePrinter{find: find, idle: idle}
}

/**
 * ensure：确保浏览器已启动，返回浏览器上下文
 *
 * 处理流程：
 * 1、已在运行直接复用
 * 2、查找浏览器，以无头方式启动（root 身份时关闭沙箱）
 */
func (c *ChromePrinter) ensure() (context.Context, error) {
	// 1、复用；上次的实例已崩溃时先清理
	if c.browser != nil {
		if c.browser.Err() == nil {
			return c.browser, nil
		}
		c.shutdownLocked()
	}
	// 2、启动
	exe := c.find()
	if exe == "" {
		return nil, ErrNoBrowser
	}
	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.ExecPath(exe),
		chromedp.Flag("headless", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("allow-file-access-from-files", true),
		chromedp.Flag("disable-extensions", true),
	)
	if runtime.GOOS == "linux" && os.Geteuid() == 0 {
		opts = append(opts, chromedp.NoSandbox)
	}
	actx, acancel := chromedp.NewExecAllocator(context.Background(), opts...)
	bctx, bcancel := chromedp.NewContext(actx)
	if err := chromedp.Run(bctx); err != nil {
		bcancel()
		acancel()
		return nil, err
	}
	c.alloc, c.browser, c.cancel = acancel, bctx, bcancel
	return bctx, nil
}

/** release：一次打印结束，没有进行中的任务时开始空闲计时 */
func (c *ChromePrinter) release() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.active--
	if c.active > 0 {
		return
	}
	if c.timer != nil {
		c.timer.Stop()
	}
	c.timer = time.AfterFunc(c.idle, func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		if c.active == 0 {
			c.shutdownLocked()
		}
	})
}

/** Close：立即关闭浏览器 */
func (c *ChromePrinter) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.shutdownLocked()
}

/** shutdownLocked：关闭浏览器进程（调用方持锁） */
func (c *ChromePrinter) shutdownLocked() {
	if c.cancel != nil {
		c.cancel()
		c.alloc()
		c.cancel, c.alloc, c.browser = nil, nil, nil
	}
}

/**
 * Print：在新标签页打开 HTML，等待就绪后打印
 *
 * 处理流程：
 * 1、取得浏览器并登记进行中的任务
 * 2、新标签页打开本地 HTML，等待脚本标记就绪
 * 3、按页面尺寸打印，背景色一并输出
 */
func (c *ChromePrinter) Print(ctx context.Context, htmlPath string, pg Page) ([]byte, error) {
	// 1、浏览器
	c.mu.Lock()
	bctx, err := c.ensure()
	if err != nil {
		c.mu.Unlock()
		return nil, err
	}
	c.active++
	if c.timer != nil {
		c.timer.Stop()
	}
	c.mu.Unlock()
	defer c.release()
	tctx, tcancel := chromedp.NewContext(bctx)
	defer tcancel()
	stop := context.AfterFunc(ctx, tcancel)
	defer stop()
	// 2、打开并等待
	w, h := mm(pg.Width), mm(pg.Height)
	var pdf []byte
	err = chromedp.Run(tctx,
		chromedp.Navigate(fileURL(htmlPath)),
		chromedp.Poll(`window.__pdReady === true`, nil, chromedp.WithPollingTimeout(15*time.Second)),
		// 3、打印
		chromedp.ActionFunc(func(ctx context.Context) error {
			var err error
			pdf, _, err = page.PrintToPDF().
				WithPrintBackground(true).
				WithPreferCSSPageSize(true).
				WithPaperWidth(w / 25.4).
				WithPaperHeight(h / 25.4).
				Do(ctx)
			return err
		}),
	)
	if err != nil {
		return nil, err
	}
	return pdf, nil
}

/** mm：把 "110mm" 解析为毫米数 */
func mm(s string) float64 {
	v, _ := strconv.ParseFloat(strings.TrimSuffix(s, "mm"), 64)
	return v
}
