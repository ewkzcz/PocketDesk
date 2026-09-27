// PocketDesk 审批扩展：Pi 执行命令、写入工作区外文件前，经 RPC 向手机请求确认；拒绝或超时则拦下这次调用。
import * as fs from "node:fs";
import * as path from "node:path";

/** realish：存在的部分解析符号链接，不存在的尾部原样拼回 */
function realish(p: string): string {
	let head = p;
	const tail: string[] = [];
	while (!fs.existsSync(head)) {
		const parent = path.dirname(head);
		if (parent === head) return p;
		tail.unshift(path.basename(head));
		head = parent;
	}
	return path.join(fs.realpathSync(head), ...tail);
}

export default function (pi: any) {
	pi.on("tool_call", async (event: any, ctx: any) => {
		const input = event.input ?? {};
		let kind = "";
		let summary = "";
		if (event.toolName === "bash") {
			kind = "command";
			summary = String(input.command ?? "");
		} else if (event.toolName === "write" || event.toolName === "edit") {
			const cwd = realish(ctx.cwd);
			const target = realish(path.resolve(ctx.cwd, String(input.path ?? "")));
			const rel = path.relative(cwd, target);
			if (rel !== ".." && !rel.startsWith(".." + path.sep) && !path.isAbsolute(rel)) return undefined;
			kind = "edit";
			summary = target;
		} else {
			return undefined;
		}
		const req = JSON.stringify({ tool: event.toolName, kind, summary, input });
		const choice = await ctx.ui.select("pocketdesk:approval " + req, ["allow", "deny"]);
		if (choice !== "allow") return { block: true, reason: "用户在手机上拒绝了这次操作" };
		return undefined;
	});
}
