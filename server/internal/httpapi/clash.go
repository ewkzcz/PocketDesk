/**
 * Clash 分流脚本：电脑开着 Clash 的 TUN 模式时，提供一份放进 Clash Verge「全局扩展脚本」的模板。
 * 用户只填写住宅代理；AI 编程工具与谷歌走住宅出口，其他流量走基础节点，Tailscale 组网内部不进代理。
 * 模板与订阅解耦：换订阅、换节点不用改；不修改用户已有的订阅与扩展脚本。
 */
package httpapi

import (
	_ "embed"
	"net/http"
)

/** clashScript：分流脚本模板，内容见 clash_script.js */
//
//go:embed clash_script.js
var clashScript string

/** adminClashScript：返回分流脚本模板，桌面端复制后粘贴到 Clash */
func (s *Server) adminClashScript(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]string{"script": clashScript})
}
