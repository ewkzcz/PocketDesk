// PocketDesk 发到手机扩展：注册 send_to_phone 工具，用户要求时把电脑上的文件经文件传输发到手机。
import * as path from "node:path";

export default function (pi: any) {
	const cmd: string[] = JSON.parse(process.env.POCKETDESK_SEND_CMD ?? "[]");
	if (cmd.length === 0) return;
	pi.registerTool({
		name: "send_to_phone",
		label: "Send to phone",
		description: process.env.POCKETDESK_SEND_DESC ?? "",
		promptSnippet: "Send files from this computer to the user's phone",
		promptGuidelines: ["Use send_to_phone when the user asks to send, share or transfer a file to their phone."],
		parameters: {
			type: "object",
			properties: {
				paths: { type: "array", items: { type: "string" }, description: process.env.POCKETDESK_SEND_PATHS_DESC ?? "" },
			},
			required: ["paths"],
		},
		async execute(_id: string, params: any, signal: any, _onUpdate: any, ctx: any) {
			// 1、路径按会话工作目录转为绝对路径，去掉模型可能带上的 @ 前缀
			const paths = (params.paths ?? []).map((p: string) => path.resolve(ctx.cwd, String(p).replace(/^@/, "")));
			if (paths.length === 0) throw new Error("请指定要发送的文件");
			// 2、交给 PocketDesk 加入发送队列
			const r = await pi.exec(cmd[0], [...cmd.slice(1), ...paths], { signal, timeout: 5 * 60 * 1000 });
			if (r.code !== 0) throw new Error("发送失败：" + (r.stderr || r.stdout).trim());
			return { content: [{ type: "text", text: r.stdout.trim() + "\n手机连上后自动接收" }], details: {} };
		},
	});
}
