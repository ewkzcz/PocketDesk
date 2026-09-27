/**
 * 内置网页：桌面端管理页面（面板、配对、设置）与手机浏览器应急网页，以及日志导出接口。
 */
package httpapi

import (
	"bytes"
	"embed"
	"io/fs"
	"net/http"
	"strings"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/logx"
)

//go:embed web
var webFS embed.FS

/** subFS：取内嵌目录 */
func subFS(dir string) http.FileSystem {
	f, err := fs.Sub(webFS, "web/"+dir)
	if err != nil {
		panic(err)
	}
	return http.FS(f)
}

/** staticHandler：根路径返回 index.html，icons.js 与头像取公共目录，其余按文件名返回 */
func staticHandler(dir, prefix string) http.Handler {
	files := http.StripPrefix(prefix, http.FileServer(subFS(dir)))
	common := http.StripPrefix(prefix, http.FileServer(subFS("common")))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:")
		if r.URL.Path == "/" {
			r.URL.Path = prefix
		}
		if r.URL.Path == prefix+"icons.js" || strings.HasPrefix(r.URL.Path, prefix+"avatars/") {
			common.ServeHTTP(w, r)
			return
		}
		files.ServeHTTP(w, r)
	})
}

/** adminPage：桌面端管理页面 */
func (s *Server) adminPage() http.Handler { return staticHandler("admin", "/admin/") }

/** pwa：手机浏览器应急网页 */
func (s *Server) pwa() http.Handler { return staticHandler("pwa", "/pwa/") }

/** exportLogs：打包电脑端日志（已去除令牌等敏感内容） */
func (s *Server) exportLogs(w http.ResponseWriter, r *http.Request) {
	var buf bytes.Buffer
	if err := logx.Export(s.LogDir, &buf); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "logs.export", nil)
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="pocketdesk-host-`+time.Now().Format("20060102-150405")+`.zip"`)
	w.Write(buf.Bytes())
}
