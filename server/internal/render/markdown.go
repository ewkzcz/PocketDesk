/**
 * Markdown 转 HTML：支持 GFM 表格、任务列表、脚注、代码高亮、数学公式与 mermaid；本地图片限制在工作区内。
 */
package render

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"html"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/gohugoio/hugo-goldmark-extensions/passthrough"
	"github.com/yuin/goldmark"
	highlighting "github.com/yuin/goldmark-highlighting/v2"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
	"github.com/yuin/goldmark/text"
	"go.abhg.dev/goldmark/mermaid"

	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** Doc：转换结果 */
type Doc struct {
	Body       string
	Title      string
	HasMath    bool
	HasMermaid bool
	Images     []string
	BaseDir    string
}

/** newMarkdown：构造带全部扩展的 goldmark 实例 */
func newMarkdown() goldmark.Markdown {
	return goldmark.New(
		goldmark.WithExtensions(
			extension.GFM,
			extension.Footnote,
			highlighting.NewHighlighting(highlighting.WithStyle("github")),
			&mermaid.Extender{RenderMode: mermaid.RenderModeClient, NoScript: true},
			passthrough.New(passthrough.Config{
				InlineDelimiters: []passthrough.Delimiters{{Open: "$", Close: "$"}, {Open: `\(`, Close: `\)`}},
				BlockDelimiters:  []passthrough.Delimiters{{Open: "$$", Close: "$$"}, {Open: `\[`, Close: `\]`}},
			}),
		),
		goldmark.WithParserOptions(parser.WithAutoHeadingID()),
	)
}

/**
 * Convert：把 Markdown 源文转成 HTML 片段
 *
 * 处理流程：
 * 1、解析 AST
 * 2、遍历节点：记录标题、公式、mermaid；本地图片校验必须在工作区内，越界图片清空
 * 3、渲染为 HTML
 */
func Convert(src []byte, root, mdAbs string) (Doc, error) {
	md := newMarkdown()
	// 1、解析
	reader := text.NewReader(src)
	doc := md.Parser().Parse(reader)
	dir := filepath.Dir(mdAbs)
	out := Doc{BaseDir: dir}
	// 2、遍历
	err := ast.Walk(doc, func(n ast.Node, entering bool) (ast.WalkStatus, error) {
		if !entering {
			return ast.WalkContinue, nil
		}
		switch v := n.(type) {
		case *ast.Heading:
			if out.Title == "" && v.Level == 1 {
				out.Title = string(v.Lines().Value(src))
			}
		case *passthrough.PassthroughInline, *passthrough.PassthroughBlock:
			out.HasMath = true
		case *mermaid.Block:
			out.HasMermaid = true
		case *ast.Image:
			dest := string(v.Destination)
			if isRemote(dest) {
				return ast.WalkContinue, nil
			}
			abs, ok := localImage(root, dir, dest)
			if !ok {
				v.Destination = nil
				return ast.WalkContinue, nil
			}
			// 保留相对路径，由页面的 base 指向 md 所在目录解析
			out.Images = append(out.Images, abs)
		}
		return ast.WalkContinue, nil
	})
	if err != nil {
		return out, err
	}
	// 3、渲染
	var buf bytes.Buffer
	if err := md.Renderer().Render(&buf, src, doc); err != nil {
		return out, err
	}
	out.Body = buf.String()
	return out, nil
}

/** isRemote：远程或内联图片 */
func isRemote(dest string) bool {
	l := strings.ToLower(dest)
	return strings.HasPrefix(l, "http://") || strings.HasPrefix(l, "https://") || strings.HasPrefix(l, "data:")
}

/** localImage：把相对图片路径解析为工作区内的绝对路径，越界返回 false */
func localImage(root, dir, dest string) (string, bool) {
	if u, err := url.PathUnescape(dest); err == nil {
		dest = u
	}
	if i := strings.IndexAny(dest, "?#"); i >= 0 {
		dest = dest[:i]
	}
	if dest == "" || filepath.IsAbs(dest) || strings.HasPrefix(dest, "file:") {
		return "", false
	}
	// dir 已是解析过符号链接的真实路径，先求相对根目录的路径，再交给工作区校验（含 .. 与符号链接越界）
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", false
	}
	rel, err := filepath.Rel(realRoot, filepath.Join(dir, filepath.FromSlash(dest)))
	if err != nil {
		return "", false
	}
	abs, err := workspace.Resolve(realRoot, filepath.ToSlash(rel))
	if err != nil {
		return "", false
	}
	return abs, true
}

/** fileURL：本地绝对路径转 file:// 地址 */
func fileURL(abs string) string {
	p := filepath.ToSlash(abs)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return (&url.URL{Scheme: "file", Path: p}).String()
}

/** depsHash：引用图片的路径与修改时间摘要 */
func depsHash(images []string) string {
	sorted := append([]string(nil), images...)
	sort.Strings(sorted)
	h := sha256.New()
	for _, p := range sorted {
		mt := "missing"
		if info, err := os.Stat(p); err == nil {
			mt = fmt.Sprintf("%d:%d", info.ModTime().UnixNano(), info.Size())
		}
		fmt.Fprintf(h, "%s|%s\n", p, mt)
	}
	return hex.EncodeToString(h.Sum(nil))
}

/** Page：阅读页尺寸配置 */
type Page struct {
	Width    string
	Height   string
	Margin   string
	FontSize string
}

/** pageFor：手机阅读尺寸（宽 110mm）或 A4 */
func pageFor(size string) Page {
	if size == "a4" {
		return Page{Width: "210mm", Height: "297mm", Margin: "15mm", FontSize: "11pt"}
	}
	return Page{Width: "110mm", Height: "190mm", Margin: "6mm", FontSize: "11pt"}
}

/** HTML：组装完整的打印页 */
func HTML(d Doc, page Page, assets string) string {
	var b strings.Builder
	b.WriteString("<!doctype html><html lang=\"zh\"><head><meta charset=\"utf-8\">")
	if d.BaseDir != "" {
		b.WriteString(`<base href="` + html.EscapeString(fileURL(d.BaseDir)+"/") + `">`)
	}
	b.WriteString("<title>" + html.EscapeString(d.Title) + "</title>")
	fmt.Fprintf(&b, "<style>@page{size:%s %s;margin:%s}", page.Width, page.Height, page.Margin)
	fmt.Fprintf(&b, ":root{--pd-text:#1a1a1a;--pd-muted:#5c5c5c;--pd-line:#e5e5e5;--pd-code:#f6f8fa;--pd-accent:#07c160}body{font-size:%s}", page.FontSize)
	b.WriteString(readerCSS)
	b.WriteString("</style>")
	if d.HasMath {
		fmt.Fprintf(&b, `<link rel="stylesheet" href="%s"><script src="%s"></script><script src="%s"></script>`,
			fileURL(filepath.Join(assets, "katex.min.css")), fileURL(filepath.Join(assets, "katex.min.js")), fileURL(filepath.Join(assets, "auto-render.min.js")))
	}
	if d.HasMermaid {
		fmt.Fprintf(&b, `<script src="%s"></script>`, fileURL(filepath.Join(assets, "mermaid.min.js")))
	}
	b.WriteString("</head><body><article>")
	b.WriteString(d.Body)
	b.WriteString("</article><script>")
	b.WriteString(readyJS)
	b.WriteString("</script></body></html>")
	return b.String()
}

/** readerCSS：中文排版友好的阅读样式，代码块自动换行 */
const readerCSS = `
*{box-sizing:border-box}
html{-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{margin:0;color:var(--pd-text);line-height:1.7;font-family:-apple-system,"PingFang SC","Hiragino Sans GB","Microsoft YaHei","Noto Sans CJK SC","Source Han Sans SC",sans-serif;word-wrap:break-word;overflow-wrap:anywhere}
h1,h2,h3,h4,h5,h6{line-height:1.35;margin:1.2em 0 .5em;font-weight:600;break-after:avoid}
h1{font-size:1.6em;letter-spacing:-.01em;border-bottom:1px solid var(--pd-line);padding-bottom:.3em}
h2{font-size:1.35em;border-bottom:1px solid var(--pd-line);padding-bottom:.25em}
h3{font-size:1.15em}h4,h5,h6{font-size:1em}
p,ul,ol,blockquote,table,pre{margin:.6em 0}
ul,ol{padding-left:1.4em}
li{margin:.2em 0}
li input[type=checkbox]{margin:0 .4em 0 -1.2em;vertical-align:middle}
a{color:#1f6feb;text-decoration:none}
blockquote{margin-left:0;padding:.2em .9em;color:var(--pd-muted);border-left:3px solid var(--pd-line)}
code{font-family:"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;font-size:.88em;background:var(--pd-code);padding:.1em .35em;border-radius:4px}
pre{background:var(--pd-code)!important;padding:.7em .8em;border-radius:6px;white-space:pre-wrap!important;word-break:break-all;overflow:visible}
pre code{background:none;padding:0;font-size:.82em}
table{border-collapse:collapse;width:100%;font-size:.9em;break-inside:auto}
th,td{border:1px solid var(--pd-line);padding:.35em .5em;text-align:left;vertical-align:top}
th{background:var(--pd-code);font-weight:600}
tr{break-inside:avoid}
img{max-width:100%;height:auto}
hr{border:0;border-top:1px solid var(--pd-line);margin:1.2em 0}
pre.mermaid{background:none!important;text-align:center;white-space:pre!important}
.katex-display{overflow:hidden}
.footnotes{font-size:.88em;color:var(--pd-muted)}
`

/** readyJS：公式、图表与图片全部就绪后置 __pdReady */
const readyJS = `window.__pdReady=false;
(async function(){
try{if(window.renderMathInElement){renderMathInElement(document.body,{delimiters:[{left:"$$",right:"$$",display:true},{left:"\\[",right:"\\]",display:true},{left:"$",right:"$",display:false},{left:"\\(",right:"\\)",display:false}],throwOnError:false})}}catch(e){}
try{if(window.mermaid){mermaid.initialize({startOnLoad:false,theme:"neutral",securityLevel:"strict"});await mermaid.run({querySelector:"pre.mermaid"})}}catch(e){}
try{if(document.fonts&&document.fonts.ready){await document.fonts.ready}}catch(e){}
await Promise.all(Array.from(document.images).map(function(i){return i.complete?1:new Promise(function(r){i.onload=i.onerror=r})}));
window.__pdReady=true;
})();`
