import Foundation
import AppKit

extension TaskService {
    func startWeChat() {
        guard oldOwnerStopped else { errorMessage="请先确认其他设备上的微信执行器已停止。";return }
        guard wechatProcess?.isRunning != true else { return }
        do {
            let runtime=AppPaths.root.appendingPathComponent("bridge-runtime")
            let executable=runtime.appendingPathComponent("venv/bin/python")
            let worker=runtime.appendingPathComponent("code/run_worker.py")
            guard FileManager.default.isExecutableFile(atPath:executable.path),FileManager.default.fileExists(atPath:worker.path) else {
                throw AppFailure.message("微信运行环境尚未安装，请运行工程的本机安装脚本。")
            }
            let process=Process();process.executableURL=executable
            process.arguments=[worker.path,"--old-owner-stopped","--parent-pid",String(ProcessInfo.processInfo.processIdentifier)]
            process.environment=WeChatEnvironment.worker(ProcessInfo.processInfo.environment)
            if wechatState=="session_expired" {process.arguments!.append("--login-again")}
            process.standardOutput=FileHandle.nullDevice
            let errors=AppPaths.runtime.appendingPathComponent("wechat-worker-errors.log")
            if !FileManager.default.fileExists(atPath:errors.path) {FileManager.default.createFile(atPath:errors.path,contents:nil,attributes:[.posixPermissions:0o600])}
            let errorFile=try FileHandle(forWritingTo:errors);try errorFile.seekToEnd();process.standardError=errorFile
            try process.run();wechatProcess=process;wechatState="starting"
            UserDefaults.standard.set(true,forKey:"TaskSecretary.wechatAutoConnect")
            UserDefaults.standard.set(true,forKey:"TaskSecretary.confirmedSingleOwner")
            wechatTimer?.invalidate()
            wechatTimer=Timer.scheduledTimer(withTimeInterval:1.5,repeats:true){[weak self] _ in
                Task { @MainActor in self?.updateWeChatStatus() }
            }
        } catch {errorMessage="微信连接启动失败："+error.localizedDescription}
    }
    func stopWeChat(preserveAutoConnect:Bool=false) {
        if !preserveAutoConnect {UserDefaults.standard.set(false,forKey:"TaskSecretary.wechatAutoConnect")}
        wechatProcess?.terminate();wechatProcess=nil;wechatTimer?.invalidate();wechatTimer=nil
        wechatState="stopped";wechatQRCode=nil
    }
    func updateWeChatStatus() {
        let root=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tasksecretary/wechat")
        if let data=try? Data(contentsOf:root.appendingPathComponent("status.json")),
           let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let state=json["state"] as? String {
            if let pid=(json["worker_pid"] as? NSNumber)?.int32Value,pid==wechatProcess?.processIdentifier {
                wechatState=state
                if state=="waiting_for_scan" {wechatQRCode=NSImage(contentsOf:root.appendingPathComponent("login.png"))}
                else {wechatQRCode=nil}
            }
        }
        if wechatProcess?.isRunning != true {
            if wechatProcess?.terminationStatus==3 {wechatState="worker_conflict"}
            else if ["starting","connected","network_error","waiting_for_app"].contains(wechatState) {wechatState="blocked"}
            wechatTimer?.invalidate();wechatTimer=nil
        }
    }
    var wechatLabel:String {
        ["stopped":"未连接","starting":"正在连接…","waiting_for_scan":"请使用微信扫码并确认",
         "connected":"已连接 · 共用任务服务","waiting_for_app":"正在等待任务服务","session_expired":"会话已失效，请重新扫码",
         "network_error":"网络异常，正在重试","reply_uncertain":"回复结果不明，已暂停","blocked":"执行器已退出，请重试（保留现有会话）",
         "worker_conflict":"本机已有微信执行器占用连接，请先停止旧进程","protocol_error":"微信接口返回异常，连接已暂停","owner_exited":"主应用已退出，连接已停止"] [wechatState] ?? wechatState
    }
}
