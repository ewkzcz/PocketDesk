/**
 * Markdown 转 PDF 单元测试：转换规则、缓存判定、并发合并；本机有浏览器时再做一次真实打印。
 */
package render

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

func TestConvertFeaturesAndImages(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	os.MkdirAll(filepath.Join(root, "notes", "img"), 0o755)
	os.WriteFile(filepath.Join(root, "notes", "img", "a.png"), []byte("png"), 0o644)
	os.WriteFile(filepath.Join(outside, "secret.png"), []byte("s"), 0o644)
	os.Symlink(outside, filepath.Join(root, "notes", "link"))
	md := "# 会议纪要\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] 完成\n\n行内公式 $a_1+b_2$\n\n$$\nE=mc^2\n$$\n\n```mermaid\ngraph TD; A-->B\n```\n\n```go\nfunc main() {}\n```\n\n脚注[^1]\n\n[^1]: 说明\n\n![](img/a.png) ![](../../" + filepath.Base(outside) + "/secret.png) ![](link/secret.png) ![](https://x.test/r.png)\n"
	doc, err := Convert([]byte(md), root, filepath.Join(root, "notes", "a.md"))
	if err != nil {
		t.Fatal(err)
	}
	if doc.Title != "会议纪要" || !doc.HasMath || !doc.HasMermaid {
		t.Fatalf("识别结果 %+v", doc)
	}
	for _, want := range []string{"<table>", `type="checkbox"`, `class="mermaid"`, "$a_1+b_2$", "footnote", `src="img/a.png"`, "https://x.test/r.png"} {
		if !strings.Contains(doc.Body, want) {
			t.Errorf("HTML 缺少 %q", want)
		}
	}
	if strings.Contains(doc.Body, "secret") || len(doc.Images) != 1 {
		t.Fatalf("工作区外图片应被清空: %v", doc.Images)
	}
	page := HTML(doc, pageFor("mobile"), "/assets")
	if !doc.HasCode || !strings.Contains(page, "highlight.min.js") {
		t.Fatal("有代码块时应加载高亮脚本")
	}
	if !strings.Contains(page, `<base href="file://`+filepath.ToSlash(filepath.Join(root, "notes"))+`/">`) || !strings.Contains(page, "size:110mm 190mm") || !strings.Contains(page, "katex.min.js") || !strings.Contains(page, "mermaid.min.js") {
		t.Fatal("页面组装缺少尺寸或脚本")
	}
	plain, _ := Convert([]byte("hello <script>alert(1)</script>"), root, filepath.Join(root, "a.md"))
	if strings.Contains(plain.Body, "<script>") || plain.HasMath || plain.HasMermaid {
		t.Fatal("原始 HTML 应被过滤")
	}
	if strings.Contains(HTML(plain, pageFor("a4"), "/a"), "mermaid.min.js") {
		t.Fatal("没有图表时不应加载 mermaid")
	}
}

/** fakePrinter：记录调用次数并返回固定内容 */
type fakePrinter struct {
	calls atomic.Int32
	delay time.Duration
}

func (f *fakePrinter) Print(ctx context.Context, htmlPath string, pg Page) ([]byte, error) {
	f.calls.Add(1)
	time.Sleep(f.delay)
	b, err := os.ReadFile(htmlPath)
	if err != nil {
		return nil, err
	}
	return append([]byte("%PDF-fake\n"), b[:20]...), nil
}

func newRenderer(t *testing.T, p Printer) (*Renderer, store.Workspace) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	r, err := New(st, p, t.TempDir(), func() string { return "mobile" })
	if err != nil {
		t.Fatal(err)
	}
	return r, store.Workspace{ID: "w", RootPath: t.TempDir()}
}

func TestAssetsExtracted(t *testing.T) {
	r, _ := newRenderer(t, &fakePrinter{})
	for _, f := range []string{"mermaid.min.js", "katex.min.js", "katex.min.css", "fonts/KaTeX_Main-Regular.woff2"} {
		info, err := os.Stat(filepath.Join(r.assets, f))
		if err != nil || info.Size() == 0 {
			t.Fatalf("资源 %s 未解压", f)
		}
	}
	b, _ := os.ReadFile(filepath.Join(r.assets, "mermaid.min.js"))
	if bytes.HasPrefix(b, []byte{0x1f, 0x8b}) {
		t.Fatal("资源仍是压缩格式")
	}
}

func TestRenderCacheInvalidation(t *testing.T) {
	fp := &fakePrinter{}
	r, ws := newRenderer(t, fp)
	ctx := context.Background()
	os.MkdirAll(filepath.Join(ws.RootPath, "20261001"), 0o755)
	mdPath := filepath.Join(ws.RootPath, "20261001", "会议纪要.md")
	os.WriteFile(mdPath, []byte("# A\n\n![](p.png)"), 0o644)
	os.WriteFile(filepath.Join(ws.RootPath, "20261001", "p.png"), []byte("1"), 0o644)
	res, err := r.Render(ctx, ws, "20261001/会议纪要.md", false)
	if err != nil || res.Cached {
		t.Fatalf("首次应转换 %+v %v", res, err)
	}
	if res.PDFPath != filepath.Join(ws.RootPath, ".pocketdesk", "cache", "pdf", "20261001", "会议纪要.pdf") {
		t.Fatalf("缓存位置 %s", res.PDFPath)
	}
	if _, err := os.Stat(strings.TrimSuffix(res.PDFPath, ".pdf") + ".meta"); err != nil {
		t.Fatal("缺少 .meta")
	}
	res, _ = r.Render(ctx, ws, "20261001/会议纪要.md", false)
	if !res.Cached || fp.calls.Load() != 1 {
		t.Fatal("第二次应命中缓存")
	}
	later := time.Now().Add(time.Minute)
	os.Chtimes(filepath.Join(ws.RootPath, "20261001", "p.png"), later, later)
	if res, _ = r.Render(ctx, ws, "20261001/会议纪要.md", false); res.Cached {
		t.Fatal("图片修改后应重新转换")
	}
	os.WriteFile(mdPath, []byte("# B"), 0o644)
	if res, _ = r.Render(ctx, ws, "20261001/会议纪要.md", false); res.Cached {
		t.Fatal("源文件修改后应重新转换")
	}
	if res, _ = r.Render(ctx, ws, "20261001/会议纪要.md", true); res.Cached || fp.calls.Load() != 4 {
		t.Fatal("强制刷新应重新转换")
	}
	if p, err := r.CachedPDF(ctx, ws, "20261001/会议纪要.md"); err != nil || p != res.PDFPath {
		t.Fatal("查询缓存失败")
	}
	if _, err := r.Render(ctx, ws, "a.txt", false); err != ErrNotMarkdown {
		t.Fatal("非 md 应拒绝")
	}
	if _, err := r.Render(ctx, ws, "../x.md", false); err == nil {
		t.Fatal("越界应拒绝")
	}
}

func TestRenderSingleflight(t *testing.T) {
	fp := &fakePrinter{delay: 100 * time.Millisecond}
	r, ws := newRenderer(t, fp)
	os.WriteFile(filepath.Join(ws.RootPath, "a.md"), []byte("# x"), 0o644)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := r.Render(context.Background(), ws, "a.md", false); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if fp.calls.Load() != 1 {
		t.Fatalf("并发请求应合并为一次，实际 %d 次", fp.calls.Load())
	}
}

func TestRealChromePrint(t *testing.T) {
	exe := FindBrowser(os.Getenv("PD_TEST_BROWSER"))
	if exe == "" {
		t.Skip("本机没有浏览器")
	}
	cp := NewChromePrinter(func() string { return exe }, time.Minute)
	defer cp.Close()
	r, ws := newRenderer(t, cp)
	md := "# 标题\n\n中文段落。\n\n$$\\int_0^1 x^2 dx$$\n\n```mermaid\ngraph LR; A-->B\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![](pic.png)\n"
	os.WriteFile(filepath.Join(ws.RootPath, "doc.md"), []byte(md), 0o644)
	img := image.NewRGBA(image.Rect(0, 0, 40, 30))
	for i := range img.Pix {
		img.Pix[i] = 200
	}
	var pngBuf bytes.Buffer
	png.Encode(&pngBuf, img)
	os.WriteFile(filepath.Join(ws.RootPath, "pic.png"), pngBuf.Bytes(), 0o644)
	start := time.Now()
	res, err := r.Render(context.Background(), ws, "doc.md", false)
	if err != nil {
		t.Fatal(err)
	}
	cold := time.Since(start)
	b, _ := os.ReadFile(res.PDFPath)
	if !bytes.HasPrefix(b, []byte("%PDF")) || len(b) < 1000 {
		t.Fatalf("PDF 内容异常 %d 字节", len(b))
	}
	if !bytes.Contains(b, []byte("/Subtype /Image")) {
		t.Fatal("本地图片没有进入 PDF")
	}
	start = time.Now()
	res, _ = r.Render(context.Background(), ws, "doc.md", false)
	if !res.Cached || time.Since(start) > 200*time.Millisecond {
		t.Fatalf("命中缓存耗时 %v", time.Since(start))
	}
	os.WriteFile(filepath.Join(ws.RootPath, "doc.md"), []byte(md+"\n更多内容"), 0o644)
	start = time.Now()
	if _, err := r.Render(context.Background(), ws, "doc.md", false); err != nil {
		t.Fatal(err)
	}
	t.Logf("冷启动 %v，浏览器常驻后未命中 %v", cold, time.Since(start))
	if time.Since(start) > 2*time.Second {
		t.Fatalf("常驻浏览器下未命中缓存超过 2 秒: %v", time.Since(start))
	}
}

func TestRealChromePrintLateReady(t *testing.T) {
	exe := FindBrowser(os.Getenv("PD_TEST_BROWSER"))
	if exe == "" {
		t.Skip("本机没有浏览器")
	}
	cp := NewChromePrinter(func() string { return exe }, time.Minute)
	defer cp.Close()
	r, ws := newRenderer(t, cp)
	// 只有公式时页面要等字体加载完才就绪，晚于开始轮询；按帧轮询在后台标签页里永远等不到
	os.WriteFile(filepath.Join(ws.RootPath, "m.md"), []byte("# 公式\n\n$$E=mc^2$$\n"), 0o644)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	res, err := r.Render(ctx, ws, "m.md", false)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(res.PDFPath); !bytes.Contains(b, []byte("KaTeX")) {
		t.Fatal("PDF 中没有公式字体")
	}
}
