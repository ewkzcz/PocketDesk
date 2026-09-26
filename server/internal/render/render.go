/**
 * Markdown 转 PDF：检查缓存、合并并发请求、驱动本机 Chrome 或 Edge 无头打印，结果按原路径镜像缓存。
 */
package render

import (
	"compress/gzip"
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** CfgVersion：渲染样式版本，样式调整时递增使旧缓存失效 */
const CfgVersion = "1"

/** maxSource：可转换的 Markdown 最大字节数 */
const maxSource = 5 << 20

/** 渲染错误 */
var (
	ErrNotMarkdown = errors.New("只能转换 .md 文件")
	ErrTooLarge    = errors.New("文件过大，无法转换")
)

//go:embed assets
var assetFS embed.FS

/** Printer：把 HTML 文件打印为 PDF */
type Printer interface {
	Print(ctx context.Context, htmlPath string, page Page) ([]byte, error)
}

/** Renderer：转换服务 */
type Renderer struct {
	store    *store.Store
	printer  Printer
	pageSize func() string
	dataDir  string
	assets   string
	sf       singleflight.Group
	mu       sync.Mutex
}

/** Result：转换结果 */
type Result struct {
	PDFPath string `json:"-"`
	ETag    string `json:"etag"`
	Cached  bool   `json:"cached"`
	Size    int64  `json:"size"`
}

/** meta：缓存旁的 .meta 文件内容 */
type meta struct {
	SrcHash  string `json:"srcHash"`
	DepsHash string `json:"depsHash"`
	CfgVer   string `json:"cfgVer"`
}

/**
 * New：创建转换服务，并把内嵌的公式与图表脚本解压到数据目录
 */
func New(s *store.Store, p Printer, dataDir string, pageSize func() string) (*Renderer, error) {
	assets := filepath.Join(dataDir, "render-assets", CfgVersion)
	if err := extractAssets(assets); err != nil {
		return nil, err
	}
	return &Renderer{store: s, printer: p, pageSize: pageSize, dataDir: dataDir, assets: assets}, nil
}

/**
 * extractAssets：解压内嵌资源（.gz 解压后去掉后缀），已存在则跳过
 */
func extractAssets(dst string) error {
	return fs.WalkDir(assetFS, "assets", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel := strings.TrimPrefix(p, "assets")
		target := filepath.Join(dst, filepath.FromSlash(strings.TrimSuffix(rel, ".gz")))
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if _, err := os.Stat(target); err == nil {
			return nil
		}
		f, err := assetFS.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		var r io.Reader = f
		if strings.HasSuffix(p, ".gz") {
			zr, err := gzip.NewReader(f)
			if err != nil {
				return err
			}
			defer zr.Close()
			r = zr
		}
		tmp := target + ".tmp"
		out, err := os.Create(tmp)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, r); err != nil {
			out.Close()
			return err
		}
		if err := out.Close(); err != nil {
			return err
		}
		return os.Rename(tmp, target)
	})
}

/**
 * cachePaths：PDF 缓存位置
 *
 * 处理流程：
 * 1、优先放在工作区 .pocketdesk/cache/pdf/ 下按原路径镜像
 * 2、工作区不可写时退回数据目录
 */
func (r *Renderer) cachePaths(ws store.Workspace, rel string) (string, string) {
	stem := strings.TrimSuffix(rel, path.Ext(rel))
	// 1、工作区内
	dir := filepath.Join(ws.RootPath, ".pocketdesk", "cache", "pdf")
	if err := os.MkdirAll(filepath.Join(dir, filepath.FromSlash(path.Dir(stem))), 0o755); err == nil {
		p := filepath.Join(dir, filepath.FromSlash(stem))
		return p + ".pdf", p + ".meta"
	}
	// 2、数据目录
	dir = filepath.Join(r.dataDir, "render-cache", ws.ID)
	os.MkdirAll(filepath.Join(dir, filepath.FromSlash(path.Dir(stem))), 0o755)
	p := filepath.Join(dir, filepath.FromSlash(stem))
	return p + ".pdf", p + ".meta"
}

/**
 * Render：转换 Markdown，命中缓存直接返回
 *
 * 处理流程：
 * 1、校验扩展名、大小与路径
 * 2、计算源文件哈希、引用图片摘要、配置版本
 * 3、未强制刷新且 .meta 一致时返回缓存
 * 4、同一文件的并发请求合并为一次转换
 */
func (r *Renderer) Render(ctx context.Context, ws store.Workspace, rel string, force bool) (Result, error) {
	// 1、校验
	clean, err := workspace.CleanRel(rel)
	if err != nil {
		return Result{}, err
	}
	ext := strings.ToLower(path.Ext(clean))
	if ext != ".md" && ext != ".markdown" {
		return Result{}, ErrNotMarkdown
	}
	abs, err := workspace.Resolve(ws.RootPath, clean)
	if err != nil {
		return Result{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return Result{}, err
	}
	if info.Size() > maxSource {
		return Result{}, ErrTooLarge
	}
	// 2、摘要
	src, err := os.ReadFile(abs)
	if err != nil {
		return Result{}, err
	}
	sum := sha256.Sum256(src)
	realRoot, err := filepath.EvalSymlinks(ws.RootPath)
	if err != nil {
		return Result{}, err
	}
	doc, err := Convert(src, realRoot, abs)
	if err != nil {
		return Result{}, err
	}
	want := meta{SrcHash: hex.EncodeToString(sum[:]), DepsHash: depsHash(doc.Images), CfgVer: CfgVersion + ":" + r.pageSize()}
	pdfPath, metaPath := r.cachePaths(ws, clean)
	// 3、缓存
	if !force {
		if res, ok := r.cached(pdfPath, metaPath, want); ok {
			return res, nil
		}
	}
	// 4、合并并发
	v, err, _ := r.sf.Do(ws.ID+"\x00"+clean, func() (any, error) {
		if !force {
			if res, ok := r.cached(pdfPath, metaPath, want); ok {
				return res, nil
			}
		}
		return r.convert(context.WithoutCancel(ctx), ws, clean, doc, want, pdfPath, metaPath)
	})
	if err != nil {
		return Result{}, err
	}
	return v.(Result), nil
}

/** cached：缓存文件存在且 .meta 与期望一致 */
func (r *Renderer) cached(pdfPath, metaPath string, want meta) (Result, bool) {
	raw, err := os.ReadFile(metaPath)
	if err != nil {
		return Result{}, false
	}
	var got meta
	if json.Unmarshal(raw, &got) != nil || got != want {
		return Result{}, false
	}
	info, err := os.Stat(pdfPath)
	if err != nil {
		return Result{}, false
	}
	return Result{PDFPath: pdfPath, ETag: workspace.ETag(info), Cached: true, Size: info.Size()}, true
}

/**
 * convert：生成 HTML 并打印为 PDF
 *
 * 处理流程：
 * 1、HTML 写入缓存目录旁的临时文件
 * 2、交给打印器生成 PDF，30 秒超时
 * 3、先写 PDF 再写 .meta，最后登记缓存表
 */
func (r *Renderer) convert(ctx context.Context, ws store.Workspace, rel string, doc Doc, want meta, pdfPath, metaPath string) (Result, error) {
	// 1、HTML
	page := pageFor(r.pageSize())
	htmlPath := pdfPath + ".html"
	if err := os.WriteFile(htmlPath, []byte(HTML(doc, page, r.assets)), 0o600); err != nil {
		return Result{}, err
	}
	defer os.Remove(htmlPath)
	// 2、打印
	pctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	pdf, err := r.printer.Print(pctx, htmlPath, page)
	if err != nil {
		return Result{}, fmt.Errorf("生成 PDF 失败: %w", err)
	}
	// 3、落盘
	tmp := pdfPath + ".tmp"
	if err := os.WriteFile(tmp, pdf, 0o644); err != nil {
		return Result{}, err
	}
	if err := os.Rename(tmp, pdfPath); err != nil {
		return Result{}, err
	}
	mraw, _ := json.Marshal(want)
	if err := os.WriteFile(metaPath, mraw, 0o644); err != nil {
		return Result{}, err
	}
	info, err := os.Stat(pdfPath)
	if err != nil {
		return Result{}, err
	}
	r.store.SaveRenderEntry(ctx, store.RenderEntry{WsID: ws.ID, RelPath: rel, SrcHash: want.SrcHash, DepsHash: want.DepsHash, CfgVer: want.CfgVer, PdfPath: pdfPath})
	return Result{PDFPath: pdfPath, ETag: workspace.ETag(info), Size: info.Size()}, nil
}

/** CachedPDF：取已缓存的 PDF 路径（供下载接口使用） */
func (r *Renderer) CachedPDF(ctx context.Context, ws store.Workspace, rel string) (string, error) {
	clean, err := workspace.CleanRel(rel)
	if err != nil {
		return "", err
	}
	pdfPath, _ := r.cachePaths(ws, clean)
	if _, err := os.Stat(pdfPath); err != nil {
		return "", err
	}
	return pdfPath, nil
}
