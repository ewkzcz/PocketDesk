# PocketDesk

在手机上像发微信一样，指挥电脑里的 Claude Code、Codex、Pi 和 DSH 干活；顺手浏览电脑上的文件、看文档、互传文件。

电脑上跑一个常驻服务，手机装一个 App，扫码配对后就能用。数据只在你自己的手机、电脑和网络之间走，不经过第三方服务器。

<img src="assets/phone-sessions.webp" width="240" alt="会话列表"> <img src="assets/phone-chat.webp" width="240" alt="聊天、改动与审批"> <img src="assets/phone-preset.webp" width="240" alt="预设助手">



## 一、工作原理

### 1、整体流程

AI 编程工具一直在电脑上运行，读写的也是电脑上的文件；手机只负责发消息、看结果、点审批。

- **电脑端服务**：常驻在电脑上，按手机的请求启动 Claude Code、Codex、Pi、DSH，把它们的回复、工具调用和改动实时转给手机；也负责文件浏览和收发。
- **手机 App**：通过加密连接和电脑端服务通信。第一次扫码配对时记下电脑的证书指纹，之后每次连接都核对，对不上就拒绝。

一轮对话的过程：

### 2、远程连接

手机和电脑在同一个 Wi-Fi 下时直接走局域网。不在一个网络时（比如你在外面用流量，电脑在家），靠 [Tailscale](https://tailscale.com/) 连回电脑。

**原理**：Tailscale 把登录同一个账号的设备组成一个私有的虚拟局域网，每台设备分到一个固定的 `100.x.x.x` 地址。设备之间的数据用 WireGuard 加密，能直连就直连；直连不通时经 Tailscale 的中继服务器转发，中继只转发加密后的数据，看不到内容。PocketDesk 不需要公网 IP、不需要开路由器端口，也不需要自己的服务器。

**需要安装**：

| 设备 | 下载 |
| --- | --- |
| 安卓手机 | [tailscale-android](https://github.com/tailscale/tailscale-android)（也可以在谷歌应用商店搜 Tailscale） |
| Mac 电脑 | [Tailscale for Mac](https://tailscale.com/download/mac) |

两边装好后登录同一个账号，保持开启即可。App 的「我 → 异地连接」里能看到两边的状态，没装时也能从这里跳到下载页。



## 二、功能说明

### 1、一个 App 管多个 AI 编程工具

| 工具 | 能做什么 |
| --- | --- |
| Claude Code | 对话、逐条审批、切换模型和供应商、选用 skill、接着电脑上的会话聊 |
| Codex | 同上 |
| Pi | 对话、执行命令前在手机上审批、切换模型 |
| DSH（DeepSeek Harness） | 对话、切换模型 |

还能新建「免审批」会话：Claude Code 跳过全部确认，Codex 不审批也不进沙箱，适合放手让它跑。

### 2、手机查阅 AI 执行过程和结果

- **审批卡片**：AI 要改文件或执行命令时，手机上弹卡片，可以允许、拒绝或「本会话总是允许」。
- **本轮改动**：每轮结束列出改了哪些文件、各加减几行，点开看逐行差异。用命令或脚本生成的文件、工作区外的文件、Word / PPT / Excel 里的文字变化也算在内。
- **提醒**：需要审批和任务完成时弹通知，点通知直接进到那个会话并弹出审批。手机不在线时可以经 ntfy 或 Bark 推送，通知里不带代码和提示词。

### 3、模型和供应商随会话切换

- 每个会话可以单独换模型，列表里没有的也能手动填写。
- 电脑上用 [CC Switch](https://github.com/farion1231/cc-switch) 管理供应商时，Claude Code 和 Codex 会话可以单独换供应商（比如换成 DeepSeek 或中转站）。只读取 CC Switch 保存的配置，对这一个会话生效，不改电脑上的全局设置。
- 可以查看、启用、停用 Claude Code 和 Codex 已装的 skill，勾选后随下一条消息使用。
- 电脑上没聊完的 Claude Code、Codex 会话，在手机上选一个就能接着聊；电脑那边又聊了几句，手机打开时会自动补上。

### 4、能直接访问电脑的文件系统

- **工作区**：把电脑上的文件夹封装为工作区，手机上浏览、搜索、上传、新建、编辑。
- **此电脑**：在电脑整个磁盘里找文件
- **手机**：把手机上的文件夹封装为工作区，电脑端也能管理它。

### 5、文档在手机上直接看

| 格式 | 怎么看 |
| --- | --- |
| Markdown | 手机上排版阅读，支持 Mermaid 图表、宽表格左右滑、公式 |
| PPT | 按原稿版式、字体和配色显示 |
| Word / Excel | App 内查看，保留标题、表格、图片和工作表 |
| PDF、图片 | App 内查看 |
| txt | 小说阅读器：分章分页、衬线排版、三种底色 |

聊天里的代码块和 Mermaid 图表也能画出来，可以全屏缩放、保存成图片。

### 6、连接方式

- **局域网**：手机和电脑在同一个 Wi-Fi 下，扫码配对后直接连。
- **Tailscale**：不在一个网络时，两边都装上 Tailscale 并登录同一个账号，手机先试局域网，连不上自动改走 Tailscale。
- **手动地址**：也可以手动填写电脑的连接地址。

配对时核对电脑证书的指纹，之后每次连接都校验，防止被冒充。App 可以开启指纹或面容解锁。

### 7、传输文件

手机和电脑之间互传文本、图片和任意文件。大文件分段并行传，断网后接着传，App 重启后自动恢复未完成的任务。收到的文件按日期放进文件夹。

### 8、核心页面说明

| 标签 | 功能预览 |
| --- | --- |
| 消息 | 会话列表，右上角加号新建会话 |
| 通讯录 | AI 好友（Claude Code、Codex、Pi、DSH）和预设助手 |
| 发现 | 文件、传输、剪切板、收藏夹、提示词、截取电脑屏幕并发送给手机 |
| 我 | 电脑与连接、工作空间、安全、外观、日志 |

### 9、通讯录和预设助手

预设助手带着写好的系统提示词，可以交给任意一个 Agent 处理。

内置翻译、OCR 识别、润色改写、总结提炼、代码审查、提示词优化六个，也可以自己新建。

- **选 Agent**：开始对话前选交给谁处理，只列电脑上已安装的。
- **参数**：参数会填进提示词里，每一轮对话电脑端都把这段提示词放在你的输入前面一起交给 Agent。
- **OCR 用法**：在对话里发图片或扫描件，Agent 会读取文件并只输出识别结果。

### 10、收藏夹、剪切板、提示词

三样东西存在电脑上，手机和电脑端看到的是同一份，一端改了另一端马上同步。

- **收藏夹**：聊天里长按一条消息选「收藏」，也可以手动写一条；支持搜索、置顶、重命名。
- **剪切板**：手机和电脑之间中转文字、图片和文件（单个不超过 25 MB），保留最近 200 条，置顶的不清理。电脑端可以直接粘贴图片或拖入文件。
- **提示词**：存常用提示词并分类；聊天时在「+」面板里点「提示词」就能放进输入框。

### 11、界面风格、头像

- **主题风格**：微信、Codex、QQ、Claude、冰川玻璃、极光、新粗野、纸刊，各有浅色和深色；
- **头像**：我自己和每个 AI 都能单独设置头像。



## 三、效果展示

截图用的是演示数据，供应商名称、IP 地址和电脑名已脱敏或替换。所有截图使用 Claude 风格的深色主题。

### 1、消息与会话

右上角加号和微信一样弹出菜单：新建各工具的会话、免审批会话、终端，接着电脑上的会话、截取电脑屏幕，或扫码配对。

<img src="assets/phone-sessions.webp" width="240" alt="会话列表"> <img src="assets/phone-new-menu.webp" width="240" alt="右上角加号菜单"> <img src="assets/phone-chat.webp" width="240" alt="聊天、本轮改动与审批">

聊天输入栏的「+」面板放着相册、拍照、文件、提示词、模型与供应商、Skills 等入口；输入斜杠就列出可用的指令。

<img src="assets/phone-chat-panel.webp" width="240" alt="聊天输入面板"> <img src="assets/phone-chat-slash.webp" width="240" alt="斜杠指令"> <img src="assets/phone-diff.webp" width="240" alt="逐行差异">

每个会话可以单独设置名称、提醒、模型、供应商、Skills 和工作目录。

<img src="assets/phone-settings.webp" width="240" alt="会话设置"> <img src="assets/phone-provider.webp" width="240" alt="按会话切换供应商"> <img src="assets/phone-skills.webp" width="240" alt="Skills">

### 2、通讯录与预设助手

通讯录里是电脑上已安装的 AI 好友和内置的预设助手。选好交给哪个 Agent、填好参数就能开始对话，提示词也可以修改和恢复默认。

<img src="assets/phone-contacts.webp" width="240" alt="通讯录"> <img src="assets/phone-preset.webp" width="240" alt="翻译助手的参数与系统提示词"> <img src="assets/phone-preset-chat.webp" width="240" alt="预设助手对话">

### 3、发现

文件、传输、剪切板、收藏夹、提示词和截取电脑屏幕都收在「发现」里。

<img src="assets/phone-discover.webp" width="240" alt="发现"> <img src="assets/phone-files.webp" width="240" alt="工作区文件"> <img src="assets/phone-file-menu.webp" width="240" alt="文件长按菜单">

<img src="assets/phone-transfer.webp" width="240" alt="传输任务"> <img src="assets/phone-clip.webp" width="240" alt="剪切板"> <img src="assets/phone-fav.webp" width="240" alt="收藏夹">

<img src="assets/phone-prompt.webp" width="240" alt="提示词"> 

### 4、文档

 <img src="assets/phone-docx.webp" width="240" alt="Word 预览"> <img src="assets/phone-xlsx.webp" width="240" alt="Excel 预览">

<img src="assets/phone-md.webp" width="240" alt="Markdown 阅读"> <img src="assets/phone-md-outline.webp" width="240" alt="Markdown 大纲">

### 5、连接与设置

<img src="assets/phone-me.webp" width="240" alt="我"> <img src="assets/phone-computers.webp" width="240" alt="已配对的电脑"> <img src="assets/phone-remote.webp" width="240" alt="异地连接">

<img src="assets/phone-security.webp" width="240" alt="安全设置"> <img src="assets/phone-transfer-settings.webp" width="240" alt="传输设置"> <img src="assets/phone-terminal.webp" width="240" alt="终端">

<img src="assets/phone-mermaid.webp" width="240" alt="聊天里的 Mermaid 图表">

### 6、外观与主题

八套风格在「我 → 外观」里切换，下面是风格选择页。

<img src="assets/phone-appearance.webp" width="240" alt="外观：界面风格">

### 7、电脑端

电脑端的聊天、Mermaid 图表和「+」新建菜单（预设助手收在二级菜单里）：

<img src="assets/desktop-chat.webp" width="800" alt="电脑端聊天">

<img src="assets/desktop-mermaid.webp" width="800" alt="电脑端 Mermaid 图表">

<img src="assets/desktop-new-menu.webp" width="800" alt="电脑端新建菜单">

通讯录、预设助手和工具箱（剪切板、收藏夹、提示词、工作区）：

<img src="assets/desktop-preset.webp" width="800" alt="电脑端预设助手">

<img src="assets/desktop-clip.webp" width="800" alt="电脑端剪切板">

<img src="assets/desktop-fav.webp" width="800" alt="电脑端收藏夹">

<img src="assets/desktop-prompt.webp" width="800" alt="电脑端提示词">

<img src="assets/desktop-workspace.webp" width="800" alt="电脑端工作区文件">

工作区里的文件和文件夹用右键菜单操作，终端在电脑上直接用：

<img src="assets/desktop-file-menu.webp" width="800" alt="电脑端文件右键菜单">

<img src="assets/desktop-terminal.webp" width="800" alt="电脑端终端">

### 8、电脑端设置

<img src="assets/desktop-settings-overview.webp" width="800" alt="设置：概览">

<img src="assets/desktop-settings-permissions.webp" width="800" alt="设置：权限">

<img src="assets/desktop-settings-pair.webp" width="800" alt="设置：配对">

<img src="assets/desktop-settings-transfer.webp" width="800" alt="设置：传输">

<img src="assets/desktop-settings-security.webp" width="800" alt="设置：安全">

<img src="assets/desktop-settings-appearance.webp" width="800" alt="设置：外观与主题">



## 四、安装和使用

### 1、支持的平台

| 端 | 平台 |
| --- | --- |
| 手机 | Android 8.0 及以上 |
| 电脑 | macOS（Intel 和 Apple 芯片）；Windows 未进行适配 |

电脑上要先装好想用的 AI 编程工具（Claude Code、Codex、Pi、DSH 任选），PocketDesk 会自动找到它们。

### 2、从源码打包

需要 Go 和 Flutter。

```bash
# macOS 桌面应用，产物在 server/dist/，加 --install 直接装进「应用程序」
scripts/package-mac.sh

# 安卓安装包，按 CPU 架构拆分，产物在 app/build/app/outputs/flutter-apk/
scripts/build-apk.sh
```

### 3、配对和使用

1. 电脑上打开 PocketDesk，点「配对新手机」，屏幕上出现二维码。
2. 手机打开 App，扫码，回到电脑上点「允许」。

想在外面用，就在电脑上装 [Tailscale for Mac](https://tailscale.com/download/mac)、手机上装 [tailscale-android](https://github.com/tailscale/tailscale-android)，登录同一个账号即可。



## 五、注意点

如果电脑上用 Clash Verge 的 TUN 模式，让 AI 编程工具经住宅代理出去，**注意关掉电脑上 Tailscale 的「Use Tailscale DNS settings」**。不关的话，DNS 查询和一部分流量会绕开 Clash，跑出住宅代理的范围，暴露你真实的网络位置。

**怎么关**：

| 位置     | 操作                                                         |
| -------- | ------------------------------------------------------------ |
| Mac 电脑 | 点菜单栏的 Tailscale 图标，在菜单里取消勾选「Use Tailscale DNS settings」；装了命令行工具的也可以执行 `tailscale set --accept-dns=false` |
| 安卓手机 | 手机上一般不同时跑 Clash，可以不改；如果手机也要经代理出去，在 Tailscale 设置里同样关掉「Use Tailscale DNS」 |



## 六、社区友链

[LINUX DO](https://linux.do/)：一个关注开发者、开源项目与 AI 工具交流的社区。感谢社区佬友对开源工具和 Agent 工作流的讨论与反馈。



## 七、许可

MIT 协议，见 [LICENSE](LICENSE)。
