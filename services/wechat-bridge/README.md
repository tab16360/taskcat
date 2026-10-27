# 可选微信桥接

记事喵核心应用不依赖Python。这里包含本项目自己的桥接和持久入站实现，不包含第三方微信SDK、用户绑定或会话。

当前适配 `minibear2021/wechat_clawbot_sdk` 固定提交 `0d1c8b4e68a22f35dd38a4c2db3ec01d39234cde`。该固定版本的许可证信息尚未明确。本仓库不重新分发其源码或已安装依赖，也不把本项目协议扩展到它；请先自行确认授权与使用条件。

开发者如已有适当授权及可用的SDK环境，可在本机应用数据目录准备：

```text
~/Library/Application Support/TaskSecretary/bridge-runtime/
  venv/bin/python             # Python 3.11+，可导入授权的SDK、httpx和qrcode
  code/run_worker.py          # 本目录的run_worker.py
  code/src/tasksecretary_bridge/
    __init__.py
    inbox.py
```

仅复制本项目桥接代码，不复制会话或其他人的虚拟环境。运行目录应仅本机用户可访问。安装后在控制中心确认旧执行器停止，再连接微信并扫码。不要在另一台Mac同时运行同一绑定。

执行器经父进程PID监督，状态带owner/worker PID；主应用退出时停止。原始消息批次与游标先提交本机SQLite入站，再逐条请求本机鉴权Unix socket；未完成回复保持不确定状态，不盲目重发。

会话在本机 `~/.tasksecretary/wechat` 中保存，属于敏感信息，不能分享。手机扫码与真实收发属于单独的真机验收，单元测试不冒充这些结果。
