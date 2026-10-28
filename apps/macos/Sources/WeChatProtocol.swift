import Foundation
import CryptoKit

// WeChat iLink bot protocol, implemented from Tencent's MIT-licensed openclaw-weixin plugin
// (@tencent-weixin/openclaw-weixin). Pure functions only: no network, files or timers here.

struct ILinkAccount:Codable,Equatable {
    var accountID:String
    var botID:String
    var baseURL:String
    var botToken:String
    var routeTag:String?
    var userID:String
}

struct ILinkInbound:Equatable {
    let userID:String
    let text:String
    let contextToken:String
}

enum ILinkProtocol {
    static let loginBaseURL=URL(string:"https://ilinkai.weixin.qq.com")!
    static let appID="bot"
    static let botType="3"
    static let staleSession = -14
    static let longPollSeconds:TimeInterval=35

    /// Only Tencent's own hosts may receive the bot token.
    static func trustedHost(_ url:URL)->Bool {
        guard url.scheme == "https",let host=url.host?.lowercased() else{return false}
        return host == "weixin.qq.com" || host.hasSuffix(".weixin.qq.com")
    }

    /// iLink-App-ClientVersion: 0x00MMNNPP.
    static func clientVersion(_ version:String)->Int {
        let parts=version.split(separator:".").map{Int($0) ?? 0}
        func part(_ i:Int)->Int {i<parts.count ? parts[i] & 0xff : 0}
        return part(0)<<16 | part(1)<<8 | part(2)
    }

    static func headers(token:String?,routeTag:String?,appVersion:String,uin:UInt32=UInt32.random(in:0...UInt32.max))->[String:String] {
        var h=["Content-Type":"application/json","AuthorizationType":"ilink_bot_token",
               "X-WECHAT-UIN":Data(String(uin).utf8).base64EncodedString(),
               "iLink-App-Id":appID,"iLink-App-ClientVersion":String(clientVersion(appVersion))]
        if let routeTag,!routeTag.isEmpty {h["SKRouteTag"]=routeTag}
        if let token=token?.trimmingCharacters(in:.whitespaces),!token.isEmpty {h["Authorization"]="Bearer "+token}
        return h
    }

    static func baseInfo(appVersion:String)->[String:Any] {["channel_version":appVersion,"bot_agent":"TaskCat/"+appVersion]}

    /// Message IDs are uint64; quote them before JSONSerialization can round them through Double.
    static func losslessJSON(_ data:Data)throws->Any {
        guard let text=String(data:data,encoding:.utf8) else{throw ILinkError("响应不是有效文本")}
        let pattern=#"("(?:message_id|msg_id|svr_id)"\s*:\s*)(-?\d+)"#
        let quoted=text.replacingOccurrences(of:pattern,with:"$1\"$2\"",options:.regularExpression)
        return try JSONSerialization.jsonObject(with:Data(quoted.utf8))
    }

    static func string(_ value:Any?)->String? {
        switch value {
        case let s as String:return s
        case let n as NSNumber:return n.stringValue
        default:return nil
        }
    }

    /// Text typed by the user, or the transcript of a voice message. Bot echoes are ignored.
    static func inbound(_ message:[String:Any])->ILinkInbound? {
        if let type=message["message_type"] as? Int,type != 1 {return nil}
        guard let user=string(message["from_user_id"]),!user.isEmpty,
              let context=string(message["context_token"]),!context.isEmpty,
              let items=message["item_list"] as? [[String:Any]] else{return nil}
        for item in items {
            let type=item["type"] as? Int ?? 0
            if type == 1,let text=(item["text_item"] as? [String:Any]).flatMap({string($0["text"])}),!text.isEmpty {return ILinkInbound(userID:user,text:text,contextToken:context)}
            if type == 3,let text=(item["voice_item"] as? [String:Any]).flatMap({string($0["text"])}),!text.isEmpty {return ILinkInbound(userID:user,text:text,contextToken:context)}
        }
        return nil
    }

    /// Same stable ID as the earlier Python bridge: UUIDv5(URL, "tasksecretary:wechat:" + JSON([account, sender, message ID])).
    static func operationID(account:String,sender:String,messageID:String)->String {
        let identity=(try? JSONSerialization.data(withJSONObject:[account,sender,messageID],options:[.withoutEscapingSlashes])).flatMap{String(data:$0,encoding:.utf8)} ?? ""
        return uuid5(namespace:"6ba7b811-9dad-11d1-80b4-00c04fd430c8",name:"tasksecretary:wechat:"+identity)
    }

    static func uuid5(namespace:String,name:String)->String {
        let hex=namespace.replacingOccurrences(of:"-",with:"")
        var bytes=stride(from:0,to:hex.count,by:2).map{i->UInt8 in
            let start=hex.index(hex.startIndex,offsetBy:i);return UInt8(hex[start..<hex.index(start,offsetBy:2)],radix:16)!
        }
        bytes.append(contentsOf:Array(name.utf8))
        var digest=Array(Insecure.SHA1.hash(data:bytes).prefix(16))
        digest[6]=(digest[6] & 0x0f) | 0x50
        digest[8]=(digest[8] & 0x3f) | 0x80
        let s=digest.map{String(format:"%02x",$0)}.joined()
        return [s.prefix(8),s.dropFirst(8).prefix(4),s.dropFirst(12).prefix(4),s.dropFirst(16).prefix(4),s.dropFirst(20)].map(String.init).joined(separator:"-")
    }

    enum PollResult:Equatable {
        case batch(messages:Int,cursor:String)
        case sessionExpired
        case rejected(code:Int)
    }
    /// A batch is accepted only with a cursor string; `ret`/`errcode` non-zero means the server refused.
    static func interpretPoll(_ payload:[String:Any],previousCursor:String)throws->(PollResult,[[String:Any]]) {
        let errcode=payload["errcode"] as? Int ?? 0,ret=payload["ret"] as? Int ?? 0
        let code=errcode != 0 ? errcode : ret
        if code == staleSession {return (.sessionExpired,[])}
        if code != 0 {return (.rejected(code:code),[])}
        guard let cursor=payload["get_updates_buf"] as? String else{throw ILinkError("轮询结果缺少游标")}
        let messages=payload["msgs"] as? [[String:Any]] ?? []
        if payload["msgs"] != nil && !(payload["msgs"] is [[String:Any]]) {throw ILinkError("轮询结果格式无效")}
        return (.batch(messages:messages.count,cursor:cursor.isEmpty ? previousCursor : cursor),messages)
    }

    static func textReply(to user:String,text:String,contextToken:String,clientID:String,appVersion:String)->[String:Any] {
        ["msg":["from_user_id":"","to_user_id":user,"client_id":clientID,"message_type":2,"message_state":2,
                "item_list":[["type":1,"text_item":["text":text]]],"context_token":contextToken],
         "base_info":baseInfo(appVersion:appVersion)]
    }

    enum LoginStatus:Equatable {
        case waiting,scanned,expired,needVerifyCode,verifyBlocked,alreadyBound
        case redirect(host:String)
        case confirmed(ILinkAccount)
        case failed(String)
    }
    static func loginStatus(_ payload:[String:Any],currentBase:URL)->LoginStatus {
        switch payload["status"] as? String {
        case "scaned":return .scanned
        case "expired":return .expired
        case "need_verifycode":return .needVerifyCode
        case "verify_code_blocked":return .verifyBlocked
        case "binded_redirect":return .alreadyBound
        case "scaned_but_redirect":
            if let host=payload["redirect_host"] as? String,!host.isEmpty {return .redirect(host:host)}
            return .scanned
        case "confirmed":
            guard let bot=string(payload["ilink_bot_id"]),!bot.isEmpty,let token=payload["bot_token"] as? String,!token.isEmpty else{return .failed("登录失败：微信没有返回机器人身份。")}
            let base=(payload["baseurl"] as? String).flatMap{$0.isEmpty ? nil : $0} ?? currentBase.absoluteString
            return .confirmed(ILinkAccount(accountID:bot,botID:bot,baseURL:base,botToken:token,routeTag:nil,userID:string(payload["ilink_user_id"]) ?? ""))
        default:return .waiting
        }
    }
}

struct ILinkError:LocalizedError {
    let message:String
    init(_ message:String){self.message=message}
    var errorDescription:String? {message}
}
