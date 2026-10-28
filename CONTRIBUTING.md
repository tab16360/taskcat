# 贡献指南

欢迎可复现的问题、文档修正与小范围PR。先描述触发条件、预期和实际行为；真实任务或凭据不属于复现材料。

核心为 Swift / SwiftUI / EventKit，元数据日志实现位于 `poc/metadata-journal/OperationJournal.swift`（保留历史路径）。菜单栏与微信两个入口共用 `TaskService`，不要在微信连接里另写一套任务存储。

改动任务执行逻辑时，保留：稳定业务ID、操作幂等、危险动作确认、快照先持久化再删除、原生回读后确认成功、缺前序/冲突时暂停写入。不要以模型输出作为可直接执行的权限。

运行 `python3 -m pytest tests -q`（在已安装pytest的测试环境中）和 `bash scripts/build-app.sh`。测试只使用合成数据；不得默认读取个人提醒事项、请求Keychain、扫码或发送微信。若需要真机验收，区分自动化、代码检查与人工结果。

页面位于 `docs/`，为无构建步骤的静态HTML/CSS/JS。交互示例只在浏览器本地运行，不能伪装成真实模型请求。可用 `python3 -m http.server 8767 --directory docs` 预览。
