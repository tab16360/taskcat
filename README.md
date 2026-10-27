<p align="center">
  <img src="docs/assets/taskcat.png" width="96" height="96" alt="记事喵图标">
</p>

<h1 align="center">记事喵 · TaskCat</h1>

<p align="center"><strong>一句话，安排好每件事。</strong><br>住在 Mac 菜单栏的 AI 待办管家，微信里也能交代。</p>

<p align="center">
  <a href="https://github.com/tab16360/taskcat/releases/latest"><img alt="下载" src="https://img.shields.io/github/v/release/tab16360/taskcat?label=%E4%B8%8B%E8%BD%BD&color=315ed8"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple">
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-315ed8"></a>
  <a href="https://x.com/ai_funs"><img alt="X" src="https://img.shields.io/badge/X-@ai__funs-111?logo=x"></a>
</p>

<p align="center">
  <a href="https://tab16360.github.io/taskcat/">官网</a> ·
  <a href="https://github.com/tab16360/taskcat/releases/latest">下载</a> ·
  <a href="GUIDE.md">使用指南</a> ·
  <a href="SECURITY.md">隐私与安全</a> ·
  <a href="https://x.com/ai_funs">X</a>
</p>

<p align="center">
  <img src="docs/assets/screens/panel-light.png" width="420" alt="记事喵菜单栏面板：今日提醒、按逾期/明天/7天内分段的待办">
  <img src="docs/assets/screens/panel-dark.png" width="420" alt="记事喵深色主题">
</p>

## 为什么做它

待办工具不缺，缺的是**记下来的那一秒**。

- 脑子里冒出一件事，要打开 App、找列表、选日期、填分组，念头早就没了。
- 待办越积越多，打开列表只看到一堵墙，分不清哪件今天必须做。
- 人在外面、手边只有微信，想改个时间还得等回到电脑前。

记事喵把这三步都缩成一句话：**说出来，它来整理；打开时，它先告诉你今天该先做什么。**

## 它能做什么

### 想到就记，不离开当前窗口

在任何 App 里按 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>T</kbd>，输入框直接弹出。写一句“周五下午三点前交 Q4 方案，进度先记 40%”，回车交给 AI 理解成标题、截止时间、进度和分组；<kbd>⇧</kbd><kbd>↩</kbd> 则不经 AI，原样存为一条待办。

### 每天第一次打开，先看到一段“今日提醒”

AI 会读一遍逾期、今天到期和进行中的事，用两三句话告诉你先做哪件、为什么。没配模型或模型不在线时，改由本机整理同样的摘要，提醒不会缺席。

### 列表按“什么时候要做”排好

已逾期、今天、明天、7 天内、以后，各成一段；逾期标红，进行中显示进度环。每行的“…”菜单里可以一键推迟到明天或下周一（保留原来的时刻）、切换状态、移到分组；点完成后几秒内可以撤销。菜单栏图标旁的数字，就是今天逾期加到期的件数。

<p align="center">
  <img src="docs/assets/screens/conversation.png" width="420" alt="对话记录：今日提醒和微信查询结果">
  <img src="docs/assets/screens/settings.png" width="420" alt="分栏设置：外观、每日提醒、全局快捷键">
</p>

### 微信里也能交代

“这周还有什么要做的？”“任务3改到下周一。”“确认1。”记事喵通过可选的微信桥接收发消息，和菜单栏共用同一份任务、同一套编号。修改类操作会先发确认，回复短编号才执行。

### 模型你自己选

支持任何 OpenAI 兼容接口（自备 Key），也可以接本地 Ollama，完全不出本机。多套配置随时切换，设置里能一键测试连接。不配置模型也能手动管理全部任务。

### 任务跟着设备走

基础任务存进系统“提醒事项”的专用列表：选 iCloud 账户后，iPhone 上能看到、能改，到期由系统通知，Mac 关机也照样提醒。两台 Mac 之间的状态、进度、编号和回收站，可以经你自己的 iCloud Drive 同步。

## 下载安装

1. 从 [Releases](https://github.com/tab16360/taskcat/releases/latest) 下载 `TaskCat-arm64.zip`，解压后把“记事喵.app”拖进“应用程序”。
2. 首次打开若被拦截：在“系统设置 → 隐私与安全性”底部点“仍要打开”。应用使用固定的自签名证书，没有经过 Apple 公证；不需要关闭任何系统安全功能。
3. 点“授权并连接”，允许访问提醒事项，选择账户。
4. 在设置的“AI 模型”里填服务地址、模型 ID 和 Key，点“测试连接”；也可以先手动添加任务。

之后有新版本会弹窗提醒，点“安装并重启”即可：下载后先校验 SHA-256、代码签名与应用标识，替换失败自动还原。macOS 14 以上；Apple Silicon 已实测，Intel 尚未验收。

## 隐私

- **Key**：只保存在本机应用配置目录（仅当前用户可读写），不进入备份，不跨机同步。
- **发给模型的内容**：你的输入、近期操作，以及最多 100 项相关任务的标题、状态、分组；每日提醒最多 12 项任务的标题、时间、状态。**不发送任务备注**。选本地模型时，一切留在本机。
- **更新检查**：只访问本仓库的 GitHub Releases，不发送任务数据，可在设置中关闭。

详见 [SECURITY.md](SECURITY.md)。

## 从源码构建

需要 Apple Silicon Mac、Xcode 或 Command Line Tools（含 macOS 26 SDK）。核心应用不依赖 Python、Node 或第三方包。

```bash
git clone https://github.com/tab16360/taskcat.git
cd taskcat
bash scripts/build-app.sh      # 生成 dist/TaskCat.app
bash scripts/install-app.sh    # 安装到“应用程序”并打开
```

构建脚本会优先使用本机专用钥匙串 `~/Library/Keychains/taskcat-signing.keychain-db` 里的自签名证书；没有时回退为临时签名（每次更新后 macOS 会重新询问提醒事项权限）。设置 `TASKCAT_SIGNING_IDENTITY` 可改用 Developer ID。

```text
apps/macos/Sources/     SwiftUI 界面、任务服务、更新、同步
apps/macos/Resources/   Info.plist、模型指令与命令 Schema、更新脚本
poc/metadata-journal/   不可变操作日志与冲突检测
services/wechat-bridge/ 可选的微信桥接（不含第三方 SDK）
scripts/                构建、打包、安装、界面预览
tests/                  pytest 驱动的真实 Swift 行为测试
docs/                   官网（GitHub Pages）
```

## 测试

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -m pytest tests -q
```

测试会编译真实的 Swift 代码并用合成数据运行，不访问你的提醒事项、钥匙串或微信。未安装可选微信 SDK 时，相关的 3 项自动跳过。

## 微信桥接说明

桥接代码在 [`services/wechat-bridge/`](services/wechat-bridge/README.md)，适配第三方 SDK `minibear2021/wechat_clawbot_sdk`（固定提交 `0d1c8b4e`）。本仓库与安装包**不包含该 SDK**，其许可需自行确认。同一个微信绑定请只在一台 Mac 上运行。

## 已知边界

- 没有独立的 iOS App；手机端通过系统提醒事项查看和接收通知。
- AI 理解可能出错：修改类操作默认先确认，请核对后再执行。
- 含重复规则或位置提醒的复杂任务，暂不支持完整的快照删除与恢复。
- 两台 Mac 的扩展同步遇到真实并发冲突时会暂停修改，等待核对。

## 参与

欢迎通过 [Issues](https://github.com/tab16360/taskcat/issues) 报告可复现的问题，提交前请读 [贡献指南](CONTRIBUTING.md)，不要附上个人任务、Key、二维码或微信会话。

关注作者：[@ai_funs](https://x.com/ai_funs)

## 许可证

[Apache License 2.0](LICENSE)。第三方微信 SDK 不在此许可范围内。
