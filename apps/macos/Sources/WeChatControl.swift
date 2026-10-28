import Foundation
import AppKit

extension TaskService {
    /// Built-in connection: scan once in settings; later launches reconnect with the saved session.
    func startWeChat(forceLogin:Bool=false) {
        guard oldOwnerStopped else { errorMessage="请先确认其他设备上的微信连接已停止。";return }
        guard wechatBridge?.isRunning != true else{return}
        UserDefaults.standard.set(true,forKey:"TaskSecretary.wechatAutoConnect")
        UserDefaults.standard.set(true,forKey:"TaskSecretary.confirmedSingleOwner")
        let relogin=forceLogin || ["session_expired","login_expired","already_bound"].contains(wechatState)
        wechatState="starting";wechatQRCode=nil
        let bridge=makeWeChatBridge();wechatBridge=bridge
        bridge.start(forceLogin:relogin)
    }
    func stopWeChat(preserveAutoConnect:Bool=false) {
        if !preserveAutoConnect {UserDefaults.standard.set(false,forKey:"TaskSecretary.wechatAutoConnect")}
        wechatBridge?.stop();wechatBridge=nil
        wechatState="stopped";wechatQRCode=nil;wechatVerifyCode=""
    }
    func submitWeChatVerifyCode() {
        let code=wechatVerifyCode.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !code.isEmpty else{return}
        wechatBridge?.submitVerifyCode(code);wechatVerifyCode=""
    }
    private func makeWeChatBridge()->WeChatBridge {
        let home=FileManager.default.homeDirectoryForCurrentUser
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0.0"
        let options=WeChatBridge.Options(root:home.appendingPathComponent(".tasksecretary/wechat"),
                                         lockFile:AppPaths.runtime.appendingPathComponent("wechat-worker.lock"),appVersion:version)
        // Only the current bridge may change the visible state; a stopped one's last words are ignored.
        weak var current:WeChatBridge?
        let bridge=WeChatBridge(options:options,
            handler:{[weak self] text,source,id in
                guard let self else{return ServiceResult(ok:false,status:"busy",message:"记事喵正在退出",requestId:id)}
                return await self.submit(text,source:source,id:id)
            },
            sink:{[weak self] state,link in
                guard let self,let current,self.wechatBridge === current else{return}
                self.wechatState=state
                let showQR=["waiting_for_scan","scanned","need_verifycode"].contains(state)
                self.wechatQRCode=showQR ? link.flatMap(WeChatBridge.qrImage) : nil
            })
        current=bridge
        return bridge
    }
    var wechatLabel:String {
        ["stopped":"未连接","starting":"正在连接…","waiting_for_scan":"请用微信扫码","scanned":"已扫码，请在手机上确认",
         "need_verifycode":"请输入手机微信上显示的数字","connected":"已连接","waiting_for_app":"正在等待任务服务",
         "session_expired":"登录已失效，请重新扫码","login_expired":"二维码已失效，请重新连接","already_bound":"这个微信已连接过其他设备，请先在微信中解除",
         "network_error":"网络异常，正在重试","reply_uncertain":"有一条回复未确认送达，已暂停，请重新连接",
         "worker_conflict":"本机已有另一个微信连接在运行","blocked":"连接中断，请重新连接"][wechatState] ?? wechatState
    }
}
