/**
 * 电脑端入口：serve 常驻服务，open 打开设置窗口，pair 在终端显示配对二维码，send 把文件发给手机，
 * install / uninstall 管理开机自启，mcp-approve 为 Claude Code 提供审批工具。
 */
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/app"
	"github.com/ewkzcz/pocketdesk/server/internal/autostart"
	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/httpapi"
)

/** version：发布时通过 -ldflags 注入 */
var version = "1.0.0"

/** usage：命令说明 */
const usage = `用法: pocketdesk <命令> [参数]

命令:
  serve                 启动电脑端服务（默认）
  open [tray|pair]      打开设置窗口、菜单面板或配对窗口
  pair                  在终端显示配对二维码
  send <文件...> [--to 设备名]   把文件发给手机
  install               开机自动启动
  uninstall             取消开机自动启动
  version               显示版本
`

/**
 * main：按子命令分发
 */
func main() {
	cmd := "serve"
	args := os.Args[1:]
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	dataDir, err := config.DefaultDataDir()
	if err != nil {
		fail(err)
	}
	switch cmd {
	case "serve":
		err = serve(dataDir, args)
	case "open":
		err = openAdmin(dataDir, args)
	case "pair":
		err = pairCLI(dataDir)
	case "send":
		err = sendCLI(dataDir, args)
	case "install":
		exe, _ := os.Executable()
		var where string
		where, err = autostart.Install(exe, dataDir)
		if err == nil {
			fmt.Println("已设置开机自动启动：" + where)
		}
	case "uninstall":
		err = autostart.Uninstall()
		if err == nil {
			fmt.Println("已取消开机自动启动")
		}
	case "mcp-approve":
		err = mcpApprove(args)
	case "version", "--version", "-v":
		fmt.Println("PocketDesk " + version)
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fail(err)
	}
}

/** fail：输出错误并退出 */
func fail(err error) {
	fmt.Fprintln(os.Stderr, "错误：", err)
	os.Exit(1)
}

/**
 * serve：启动服务，收到退出信号或退出请求后清理
 */
func serve(dataDir string, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	debug := fs.Bool("debug", false, "记录信息级别日志")
	fs.Parse(args)
	a, err := app.New(app.Options{DataDir: dataDir, Version: version, Debug: *debug})
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := a.Start(ctx); err != nil {
		a.Close()
		return err
	}
	cfg := a.Cfg.Get()
	fmt.Printf("PocketDesk %s 已启动，端口 %d。设置窗口：pocketdesk open\n", version, cfg.Port)
	select {
	case <-ctx.Done():
	case <-a.Done():
	}
	return a.Close()
}

/** adminBase：本机管理地址与密钥 */
func adminBase(dataDir string) (string, string, error) {
	cfg, err := config.Open(filepath.Join(dataDir, "config.json"))
	if err != nil {
		return "", "", err
	}
	key, err := app.LoadAdminKey(dataDir)
	if err != nil {
		return "", "", err
	}
	return fmt.Sprintf("http://127.0.0.1:%d", cfg.Get().AdminPort), key, nil
}

/** openAdmin：用默认浏览器打开管理页面 */
func openAdmin(dataDir string, args []string) error {
	base, key, err := adminBase(dataDir)
	if err != nil {
		return err
	}
	page := "settings/overview"
	if len(args) > 0 {
		page = args[0]
	}
	u := base + "/?k=" + key + "#" + page
	var c *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		c = exec.Command("open", u)
	case "windows":
		c = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	default:
		c = exec.Command("xdg-open", u)
	}
	return c.Start()
}

/** adminCall：调用本机管理接口 */
func adminCall(dataDir, method, path string, body any, out any) error {
	base, key, err := adminBase(dataDir)
	if err != nil {
		return err
	}
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, base+path, r)
	req.Header.Set("X-PD-Key", key)
	req.Header.Set("Content-Type", "application/json")
	res, err := (&http.Client{Timeout: 5 * time.Minute}).Do(req)
	if err != nil {
		return errors.New("电脑端服务未运行，请先执行 pocketdesk serve")
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	if res.StatusCode >= 300 {
		var e struct {
			Message string `json:"message"`
		}
		json.Unmarshal(b, &e)
		return errors.New(e.Message)
	}
	if out != nil {
		return json.Unmarshal(b, out)
	}
	return nil
}

/** pairCLI：在终端显示配对二维码与配对码，是否允许在设置窗口中确认 */
func pairCLI(dataDir string) error {
	var p struct {
		Code   string `json:"code"`
		QRText string `json:"qrText"`
	}
	if err := adminCall(dataDir, "POST", "/admin/api/pair/start", nil, &p); err != nil {
		return err
	}
	q, err := qrcode.New(p.QRText, qrcode.Low)
	if err != nil {
		return err
	}
	fmt.Println(q.ToSmallString(false))
	fmt.Printf("配对码：%s（5 分钟内有效）\n手机扫码后，请在设置窗口中点「允许」。\n", p.Code)
	return nil
}

/** sendCLI：pocketdesk send a.pdf b.png --to 我的手机 */
func sendCLI(dataDir string, args []string) error {
	var paths []string
	to := ""
	for i := 0; i < len(args); i++ {
		if args[i] == "--to" && i+1 < len(args) {
			to = args[i+1]
			i++
			continue
		}
		abs, err := filepath.Abs(args[i])
		if err != nil {
			return err
		}
		paths = append(paths, abs)
	}
	if len(paths) == 0 {
		return errors.New("请指定要发送的文件")
	}
	var sent []struct {
		Name string `json:"name"`
	}
	if err := adminCall(dataDir, "POST", "/admin/api/send", map[string]any{"paths": paths, "to": to}, &sent); err != nil {
		return err
	}
	for _, s := range sent {
		fmt.Println("已加入发送队列：" + s.Name)
	}
	return nil
}

/**
 * mcpApprove：Claude Code 的审批工具，读取本机密钥后把请求转给电脑端服务
 */
func mcpApprove(args []string) error {
	fs := flag.NewFlagSet("mcp-approve", flag.ExitOnError)
	data := fs.String("data", "", "数据目录")
	sid := fs.String("session", "", "会话 ID")
	fs.Parse(args)
	dataDir := *data
	if dataDir == "" {
		dataDir, _ = config.DefaultDataDir()
	}
	base, key, err := adminBase(dataDir)
	if err != nil {
		return err
	}
	return agent.ServeApprovalMCP(context.Background(), os.Stdin, os.Stdout, func(ctx context.Context, tool string, input map[string]any) (map[string]any, error) {
		return httpapi.ApproveViaAdmin(ctx, base, key, *sid, tool, input)
	})
}
