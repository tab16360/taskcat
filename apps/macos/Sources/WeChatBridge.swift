import Foundation
import AppKit
import CoreImage
import Darwin

/// Built-in WeChat connection: QR login, then answer stored messages and long-poll for new ones.
/// Replaces the earlier Python worker; no Python or third-party SDK is needed.
final class WeChatBridge:@unchecked Sendable {
    typealias Handler = @MainActor (_ text:String,_ source:String,_ requestID:String) async -> ServiceResult
    typealias StateSink = @MainActor (_ state:String,_ qrLink:String?) -> Void

    struct Options {
        var root:URL
        var lockFile:URL
        var loginBase:URL=ILinkProtocol.loginBaseURL
        var appVersion:String
        var trustedHost:(URL)->Bool = ILinkProtocol.trustedHost
        var pollTimeout:TimeInterval=ILinkProtocol.longPollSeconds
        var retryDelay:UInt64=5_000_000_000
        var session:URLSession = .shared
    }

    private let options:Options
    private let handler:Handler
    private let sink:StateSink
    private var task:Task<Void,Never>?
    private var lockFD:Int32 = -1
    private let verifyLock=NSLock()
    private var verifyContinuation:CheckedContinuation<String,Never>?
    private var running=false
    private var earlyVerifyCode:String?
    private(set) var processed=0

    init(options:Options,handler:@escaping Handler,sink:@escaping StateSink) {
        self.options=options;self.handler=handler;self.sink=sink
    }
    var isRunning:Bool {verifyLock.withLock{running}}
    private var accountFile:URL {options.root.appendingPathComponent("native-account.json")}

    func start(forceLogin:Bool=false) {
        let claimed=verifyLock.withLock{()->Bool in if running {return false};running=true;return true}
        guard claimed else{return}
        task=Task.detached(priority:.utility){[weak self] in
            await self?.run(forceLogin:forceLogin)
            self?.verifyLock.withLock{self?.running=false}
        }
    }
    /// Cancels the loop; the lock is released when the loop exits.
    func stop() {task?.cancel();submitVerifyCode("")}
    func wait() async {await task?.value}
    /// The number WeChat shows on the phone when it asks for confirmation.
    func submitVerifyCode(_ code:String) {
        let code=code.trimmingCharacters(in:.whitespacesAndNewlines)
        // Kept if it arrives before the login loop starts waiting, so a quick answer is not lost.
        let c=verifyLock.withLock{()->CheckedContinuation<String,Never>? in
            let waiting=verifyContinuation;verifyContinuation=nil
            if waiting == nil {earlyVerifyCode=code}
            return waiting
        }
        c?.resume(returning:code)
    }

    private func publish(_ state:String,_ qr:String?=nil) async {await sink(state,qr)}

    private func run(forceLogin:Bool) async {
        // A just-stopped bridge may still be unwinding; give it a moment before calling it a conflict.
        var locked=acquireLock()
        for _ in 0..<15 where !locked && !Task.isCancelled {try? await Task.sleep(nanoseconds:200_000_000);locked=acquireLock()}
        guard locked else {await publish("worker_conflict");return}
        defer {releaseLock()}
        do {
            await publish("starting")
            if forceLogin {try? FileManager.default.removeItem(at:accountFile)}
            var account:ILinkAccount
            if let saved=try loadAccount() {account=saved}
            else {account=try await login();try saveAccount(account)}
            guard let base=URL(string:account.baseURL),options.trustedHost(base) else{throw ILinkError("微信返回了不受信任的服务地址")}
            let inbox=try WeChatInbox(path:options.root.appendingPathComponent("inbox.sqlite"))
            try await serve(account:account,base:base,inbox:inbox)
        } catch is CancellationError {
            await publish("stopped")
        } catch let error as BridgeStop {
            await publish(error.state)
        } catch {
            if Task.isCancelled {await publish("stopped")} else {await publish("blocked")}
        }
    }

    private struct BridgeStop:Error {let state:String}

    // MARK: Serving

    private func serve(account:ILinkAccount,base:URL,inbox:WeChatInbox) async throws {
        var failures=0
        while !Task.isCancelled {
            if try await drain(account:account,base:base,inbox:inbox) == false {
                try await Task.sleep(nanoseconds:2_000_000_000);continue
            }
            let cursor=try inbox.cursor(account.accountID)
            let payload:[String:Any]
            do {
                payload=try await post(base,"ilink/bot/getupdates",["get_updates_buf":cursor,"base_info":ILinkProtocol.baseInfo(appVersion:options.appVersion)],
                                       account:account,timeout:options.pollTimeout+5)
            } catch let error as URLError where error.code == .timedOut {
                continue // a quiet long poll
            } catch is CancellationError {throw CancellationError()
            } catch {
                if Task.isCancelled {throw CancellationError()}
                failures+=1;await publish("network_error")
                try await Task.sleep(nanoseconds:failures>=3 ? options.retryDelay*6 : options.retryDelay);continue
            }
            let (result,messages)=try ILinkProtocol.interpretPoll(payload,previousCursor:cursor)
            switch result {
            case .sessionExpired:
                try? FileManager.default.removeItem(at:accountFile)
                throw BridgeStop(state:"session_expired")
            case .rejected:
                failures+=1;await publish("network_error")
                try await Task.sleep(nanoseconds:failures>=3 ? options.retryDelay*6 : options.retryDelay)
            case .batch(_,let next):
                failures=0
                try inbox.commitBatch(account.accountID,messages:messages,cursor:next)
                await publish("connected")
            }
        }
        throw CancellationError()
    }

    /// Handles every stored message in order. Returns false when the task service is busy.
    private func drain(account:ILinkAccount,base:URL,inbox:WeChatInbox) async throws->Bool {
        for (op,raw) in try inbox.pending(account.accountID) {
            try Task.checkCancellation()
            guard let message=ILinkProtocol.inbound(raw) else {try inbox.acknowledge(op);continue}
            let conversation=ILinkHash.sha256(account.accountID+"|"+message.userID)
            let result=await handler(message.text,"wechat:"+conversation,op)
            if result.status == "busy" || result.status == "uncertain" {await publish("waiting_for_app");return false}
            // Pre-claim before sending: after a crash an uncertain reply is not sent twice.
            if try inbox.claimReply(op) {
                let body=ILinkProtocol.textReply(to:message.userID,text:result.message,contextToken:message.contextToken,
                                                 clientID:"taskcat:\(op)",appVersion:options.appVersion)
                do {
                    let response=try await post(base,"ilink/bot/sendmessage",body,account:account,timeout:15)
                    if let ret=response["ret"] as? Int,ret != 0 {throw ILinkError("回复被拒绝 \(ret)")}
                    try inbox.markReplied(op)
                } catch {
                    if Task.isCancelled {throw CancellationError()}
                    throw BridgeStop(state:"reply_uncertain")
                }
            }
            try inbox.acknowledge(op);processed+=1
            await publish("connected")
        }
        return true
    }

    // MARK: Login

    private func login() async throws->ILinkAccount {
        var base=options.loginBase,refreshes=1,verifyCode:String?
        var (qrcode,link)=try await fetchQRCode()
        await publish("waiting_for_scan",link)
        let deadline=Date().addingTimeInterval(480)
        while Date()<deadline {
            try Task.checkCancellation()
            let status=await pollLogin(base:base,qrcode:qrcode,verifyCode:verifyCode)
            switch status {
            case .waiting:break
            case .scanned:verifyCode=nil;await publish("scanned",link)
            case .needVerifyCode:
                await publish("need_verifycode",link)
                let code=await withCheckedContinuation{(c:CheckedContinuation<String,Never>) in
                    let early=verifyLock.withLock{()->String? in
                        if let early=earlyVerifyCode {earlyVerifyCode=nil;return early}
                        verifyContinuation=c;return nil
                    }
                    if let early {c.resume(returning:early)}
                }
                try Task.checkCancellation()
                verifyCode=code.isEmpty ? nil : code
                continue
            case .expired,.verifyBlocked:
                refreshes+=1
                guard refreshes<=3 else{throw BridgeStop(state:"login_expired")}
                (qrcode,link)=try await fetchQRCode();verifyCode=nil
                await publish("waiting_for_scan",link)
            case .alreadyBound:throw BridgeStop(state:"already_bound")
            case .redirect(let host):
                if let url=URL(string:"https://"+host),options.trustedHost(url) {base=url}
            case .confirmed(let account):return account
            case .failed:throw BridgeStop(state:"blocked")
            }
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        throw BridgeStop(state:"login_expired")
    }
    private func fetchQRCode() async throws->(String,String) {
        let tokens=(try? loadAccount()).flatMap{$0}.map{[$0.botToken]} ?? []
        let response=try await post(options.loginBase,"ilink/bot/get_bot_qrcode?bot_type="+ILinkProtocol.botType,["local_token_list":tokens],account:nil,timeout:15)
        guard let code=response["qrcode"] as? String,let link=response["qrcode_img_content"] as? String,!code.isEmpty,!link.isEmpty else {throw ILinkError("没有拿到登录二维码")}
        return (code,link)
    }
    private func pollLogin(base:URL,qrcode:String,verifyCode:String?) async->ILinkProtocol.LoginStatus {
        var endpoint="ilink/bot/get_qrcode_status?qrcode="+(qrcode.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? "")
        if let verifyCode {endpoint+="&verify_code="+(verifyCode.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? "")}
        guard let url=URL(string:endpoint,relativeTo:base.appendingPathComponent("/")) else{return .waiting}
        var request=URLRequest(url:url,timeoutInterval:ILinkProtocol.longPollSeconds)
        for (k,v) in ILinkProtocol.headers(token:nil,routeTag:nil,appVersion:options.appVersion) where k.hasPrefix("iLink") {request.setValue(v,forHTTPHeaderField:k)}
        guard let (data,response)=try? await options.session.data(for:request),(response as? HTTPURLResponse)?.statusCode == 200,
              let payload=(try? ILinkProtocol.losslessJSON(data)) as? [String:Any] else{return .waiting}
        return ILinkProtocol.loginStatus(payload,currentBase:base)
    }

    // MARK: HTTP

    private func post(_ base:URL,_ endpoint:String,_ body:[String:Any],account:ILinkAccount?,timeout:TimeInterval) async throws->[String:Any] {
        guard let url=URL(string:endpoint,relativeTo:base.appendingPathComponent("/")),options.trustedHost(url.absoluteURL) else{throw ILinkError("微信服务地址无效")}
        var request=URLRequest(url:url.absoluteURL,timeoutInterval:timeout)
        request.httpMethod="POST"
        for (k,v) in ILinkProtocol.headers(token:account?.botToken,routeTag:account?.routeTag,appVersion:options.appVersion) {request.setValue(v,forHTTPHeaderField:k)}
        request.httpBody=try JSONSerialization.data(withJSONObject:body)
        let (data,response)=try await options.session.data(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode == 200 else{throw ILinkError("微信服务返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)")}
        guard let object=try ILinkProtocol.losslessJSON(data) as? [String:Any] else{throw ILinkError("微信服务响应格式无效")}
        return object
    }

    // MARK: Account and lock

    func loadAccount()throws->ILinkAccount? {
        if let data=try? Data(contentsOf:accountFile) {return try JSONDecoder().decode(ILinkAccount.self,from:data)}
        // One-time import of the session saved by the earlier Python bridge, so no rescan is needed.
        guard let marker=try? JSONSerialization.jsonObject(with:Data(contentsOf:options.root.appendingPathComponent("active-sdk.json"))) as? [String:Any],
              let dir=marker["directory"] as? String,dir.hasPrefix("sdk-"),!dir.contains("/") else{return nil}
        let accounts=options.root.appendingPathComponent(dir).appendingPathComponent("accounts")
        let files=((try? FileManager.default.contentsOfDirectory(at:accounts,includingPropertiesForKeys:nil)) ?? [])
            .filter{$0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".sync.json") && !$0.lastPathComponent.hasSuffix(".context-tokens.json")}
        guard files.count == 1,let legacy=try? JSONSerialization.jsonObject(with:Data(contentsOf:files[0])) as? [String:Any],
              let id=legacy["account_id"] as? String,let token=legacy["bot_token"] as? String,let base=legacy["base_url"] as? String else{return nil}
        let account=ILinkAccount(accountID:id,botID:legacy["bot_id"] as? String ?? id,baseURL:base,botToken:token,routeTag:legacy["route_tag"] as? String,userID:legacy["user_id"] as? String ?? "")
        try saveAccount(account)
        return account
    }
    private func saveAccount(_ account:ILinkAccount)throws {
        try FileManager.default.createDirectory(at:options.root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(account).write(to:accountFile,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:accountFile.path)
    }
    /// Same lock file as the old worker: two bridges can never poll one WeChat binding.
    private func acquireLock()->Bool {
        try? FileManager.default.createDirectory(at:options.lockFile.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=open(options.lockFile.path,O_CREAT|O_RDWR,0o600)
        guard fd>=0 else{return false}
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else{close(fd);return false}
        lockFD=fd;return true
    }
    private func releaseLock() {if lockFD>=0 {flock(lockFD,LOCK_UN);close(lockFD);lockFD = -1}}

    static func qrImage(_ link:String)->NSImage? {
        guard let filter=CIFilter(name:"CIQRCodeGenerator") else{return nil}
        filter.setValue(Data(link.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel")
        guard let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:10,y:10)) else{return nil}
        let rep=NSCIImageRep(ciImage:output);let image=NSImage(size:rep.size);image.addRepresentation(rep)
        return image
    }
}
