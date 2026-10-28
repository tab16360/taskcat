import Foundation
import CryptoKit

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct TaskGroup:RawRepresentable,Hashable,Codable,Identifiable {
    let rawValue:String
    init?(rawValue:String) {
        let trimmed=rawValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let value=["收件箱":"inbox","工作":"work","个人":"personal"][trimmed] ?? trimmed
        guard !value.isEmpty,value.count<=40,value != "all",!value.contains(where:{$0.isNewline || $0 == "/" || $0 == "\\"}),value.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) else{return nil}
        self.rawValue=value
    }
    static let inbox=TaskGroup(rawValue:"inbox")!
    // Read old records without initializing these lists on new installations.
    static let work=TaskGroup(rawValue:"work")!
    static let personal=TaskGroup(rawValue:"personal")!
    static let allCases:[TaskGroup]=[.inbox]
    var id:String {rawValue}
    var title:String {["inbox":"收件箱","work":"工作","personal":"个人"][rawValue] ?? rawValue}
    var calendarTitle:String {"AI任务秘书-"+title}
    var uuid:String {
        if let legacy=["inbox":"b84e50c7-1fe8-4125-a677-f124168b3001","work":"b84e50c7-1fe8-4125-a677-f124168b3002","personal":"b84e50c7-1fe8-4125-a677-f124168b3003"][rawValue] {return legacy}
        let hex=SHA256.hash(data:Data(("tasksecretary.group:"+rawValue).utf8)).prefix(16).map{String(format:"%02x",$0)}.joined()
        let chars=Array(hex)
        return [String(chars[0..<8]),String(chars[8..<12]),String(chars[12..<16]),String(chars[16..<20]),String(chars[20..<32])].joined(separator:"-")
    }
    init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer();let raw=try c.decode(String.self)
        guard let group=TaskGroup(rawValue:raw) else {throw AppFailure.message("分组名称无效。")};self=group
    }
    func encode(to encoder:Encoder)throws {var c=encoder.singleValueContainer();try c.encode(rawValue)}
    static func named(_ title:String)->TaskGroup? {
        let name=title.trimmingCharacters(in:.whitespacesAndNewlines)
        return TaskGroup(rawValue:["收件箱":"inbox","工作":"work","个人":"personal"][name] ?? name)
    }
}

struct ManagedTask: Identifiable, Equatable, Codable {
    let id: String
    var title: String
    var notes: String
    var group: TaskGroup
    var status: String
    var progress: Int?
    var dueAt: Date?
    var completed: Bool
    var softDeleted: Bool
    var archived: Bool
    var conflicted: Bool
    var statusLabel: String {
        ["todo":"待办", "doing":"进行中", "waiting":"等待", "done":"已完成", "cancelled":"已取消"][status] ?? "待核对"
    }
    var nativeFingerprint: String {
        let value=[id,title,notes,group.rawValue,String(dueAt?.timeIntervalSince1970 ?? 0),String(completed)].joined(separator:"\u{0}")
        return SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    var fingerprint: String {
        let parts = [id,title,notes,group.rawValue,status,String(progress ?? -1),
                     String(dueAt?.timeIntervalSince1970 ?? 0),String(completed),String(softDeleted),String(archived)]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format:"%02x",$0) }.joined()
    }
}

struct TaskCommand: Codable, Equatable {
    let operationId: String
    let intent: String
    var taskId: String?
    var patch: [String: FieldValue]
    let dateText: String?
    var requiresConfirmation: Bool
    private enum CodingKeys:String,CodingKey {case operationId,intent,taskId,patch,dateText,requiresConfirmation}
    func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(operationId,forKey:.operationId);try c.encode(intent,forKey:.intent)
        if let id=taskId {try c.encode(id,forKey:.taskId)} else {try c.encodeNil(forKey:.taskId)}
        try c.encode(patch,forKey:.patch)
        if let date=dateText {try c.encode(date,forKey:.dateText)} else {try c.encodeNil(forKey:.dateText)}
        try c.encode(requiresConfirmation,forKey:.requiresConfirmation)
    }
    func text(_ field: String) -> String? { if case .text(let s) = patch[field] { return s }; return nil }
    var description: String {
        switch intent {
        case "create_task": return "新增「\(text("title") ?? "任务")」"
        case "complete_task": return "标记完成"
        case "reopen_task": return "重新打开任务"
        case "delete_task": return "移入回收站"
        case "move_task": return "移动任务分组"
        case "update_task": return "更新任务"
        case "create_group":return "创建分组「\(TaskGroup(rawValue:text("groupId") ?? "")?.title ?? "")」"
        case "rename_group":return "重命名分组为「\(text("newGroupId") ?? "")」"
        case "delete_group":return "删除分组，任务移至收件箱"
        case "query_groups":return "查看分组"
        default: return "查看任务"
        }
    }
    static let intents: Set<String> = ["create_task","update_task","complete_task","reopen_task","query_tasks","move_task","delete_task","clarify","create_group","query_groups","rename_group","delete_group"]
    static func decode(_ data: Data, expectedId: String, tasks: [ManagedTask]) throws -> TaskCommand {
        guard data.count < 32_768,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["operationId","intent","taskId","patch","dateText","requiresConfirmation"]) else {
            throw AppFailure.message("模型返回格式不正确，请重试或手动添加。")
        }
        // Some local models redundantly nest dateText in patch despite the schema.
        // Canonicalize only this known field; reject conflicting dates and keep all other validation.
        if var patch=object["patch"] as? [String:Any],let nested=patch["dateText"] {
            guard let text=nested as? String,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=240 else {
                throw AppFailure.message("模型返回的日期格式无效，未修改任务。")
            }
            if let top=object["dateText"] as? String,top != text {
                throw AppFailure.message("模型返回了两个不同的日期，请重新说明截止时间。")
            }
            guard object["dateText"] is NSNull || object["dateText"] is String else {
                throw AppFailure.message("模型返回的日期格式无效，未修改任务。")
            }
            patch.removeValue(forKey:"dateText");object["patch"]=patch;object["dateText"]=text
        }
        var c = try JSONDecoder().decode(TaskCommand.self,from:JSONSerialization.data(withJSONObject:object))
        if let date=c.dateText,date.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || date.count>240 {
            throw AppFailure.message("模型返回的日期格式无效，未修改任务。")
        }
        guard c.operationId == expectedId, intents.contains(c.intent), c.patch.count <= 6 else {
            throw AppFailure.message("模型命令校验未通过，未修改任务。")
        }
        for (key,value) in c.patch {
            switch (key,value) {
            case ("title",.text(let s)) where !s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && s.count <= 240: break
            case ("notes",.text(let s)) where s.count <= 4000: break
            case ("status",.text(let s)) where ["todo","doing","waiting","done","cancelled"].contains(s): break
            case ("progress",.number(let n)) where (0...100).contains(n): break
            case ("progress",.null): break
            case ("newGroupId",.text(let s)) where TaskGroup(rawValue:s) != nil: break
            case ("groupId",.text(let s)) where TaskGroup(rawValue:s) != nil: break
            default: throw AppFailure.message("模型返回了无效字段，未修改任务。")
            }
        }
        if c.patch["newGroupId"] != nil && c.intent != "rename_group" {throw AppFailure.message("新分组名只能用于重命名分组。")}
        if let raw=c.text("newGroupId"),let group=TaskGroup(rawValue:raw) {c.patch["newGroupId"] = .text(group.rawValue)}
        if let raw=c.text("groupId"),let group=TaskGroup(rawValue:raw) {c.patch["groupId"] = .text(group.rawValue)}
        if let id = c.taskId {
            guard let task = tasks.first(where:{$0.id == id}), !task.conflicted, !task.softDeleted else {
                throw AppFailure.message("目标任务不可用或存在冲突，请刷新后重试。")
            }
        }
        if !["create_task","query_tasks","clarify","create_group","query_groups","rename_group","delete_group"].contains(c.intent), c.taskId == nil {
            throw AppFailure.message("没有唯一匹配的任务，请补充具体名称。")
        }
        if c.intent == "create_task" {
            guard c.taskId == nil, c.text("title") != nil else { throw AppFailure.message("新增任务缺少标题。") }
            if tasks.contains(where: { !$0.softDeleted && $0.title.localizedCaseInsensitiveCompare(c.text("title")!) == .orderedSame }) {
                throw AppFailure.message("已有同名任务，请说明要修改原任务，还是另建一项。")
            }
        }
        if ["create_group","rename_group","delete_group"].contains(c.intent), c.text("groupId") == nil {throw AppFailure.message("请说明分组名称。") }
        if ["create_group","query_groups","rename_group","delete_group"].contains(c.intent),c.taskId != nil {throw AppFailure.message("分组命令不应指定任务。") }
        if ["rename_group","delete_group"].contains(c.intent) {
            guard c.text("groupId") != "inbox", c.dateText == nil else {throw AppFailure.message("收件箱是默认分组，不能重命名或删除。")}
            if c.intent == "rename_group" {guard let name=c.text("newGroupId"), name != c.text("groupId"), name != "inbox" else{throw AppFailure.message("请提供不同的有效新分组名。")}}
            c.requiresConfirmation=true
        }
        if case .number(let progress)=c.patch["progress"] {
            c.patch["progress"] = .number(max(10,min(100,Int((Double(progress)/10).rounded())*10)))
            if progress >= 95 {c.patch["status"] = .text("done")}
        }
        let restricted: [String: Set<String>] = ["rename_group":["groupId","newGroupId"],"delete_group":["groupId"],"create_group":["groupId"],"query_groups":[],"delete_task": [], "complete_task": ["status"], "reopen_task": ["status"], "move_task": ["groupId"], "query_tasks": ["groupId", "status"]]
        if let allowed=restricted[c.intent], !Set(c.patch.keys).isSubset(of:allowed) { throw AppFailure.message("模型命令包含与操作不符的修改，未执行。") }
        if c.intent=="complete_task", let status=c.text("status"),status != "done" { throw AppFailure.message("完成命令的状态不一致，未执行。") }
        if c.intent=="reopen_task", let status=c.text("status"),status != "todo" { throw AppFailure.message("重新打开命令的状态不一致，未执行。") }
        if c.intent == "move_task", c.text("groupId") == nil { throw AppFailure.message("请说明要移动到哪个分组。") }
        return c
    }
}

struct ModelPreferences: Codable, Equatable {
    var provider = "cloud"
    var cloudURL = "https://api.openai.com/v1"
    var cloudModel = ""
    var localURL = "http://127.0.0.1:11434/v1"
    var localModel = ""
    var sourceIdentifier: String? = nil
    var confirmAll = false
    var profiles:[ModelProfile]? = nil
    var selectedProfileID:String? = nil
    var credentialService:String? = nil
    var baseURL: String { provider == "cloud" ? cloudURL : localURL }
    var model: String { provider == "cloud" ? cloudModel : localModel }
    var origin: String {
        guard let c=URLComponents(string:baseURL),let scheme=c.scheme,let host=c.host else{return "invalid"}
        return scheme.lowercased()+"://"+host.lowercased()+":"+String(c.port ?? (scheme=="https" ? 443 : 80))
    }
    var keyService: String {
        let digest=SHA256.hash(data:Data(origin.utf8)).prefix(12).map{String(format:"%02x",$0)}.joined()
        if let service=credentialService {
            if let stored=profiles?.first(where:{$0.id==selectedProfileID}) {
                var prior=ModelPreferences();prior.provider=stored.provider
                if stored.provider=="cloud" {prior.cloudURL=stored.baseURL}else{prior.localURL=stored.baseURL}
                if prior.origin != origin || stored.provider != provider {return "TaskSecretary.Profile."+stored.id+"."+provider+"."+digest}
            }
            return service
        }
        return "TaskSecretary.AI."+provider+"."+digest
    }
    func endpoint() throws -> URL {
        guard var url = URLComponents(string:baseURL), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || url.scheme == "http" && ["127.0.0.1","localhost","::1"].contains(host) else {
            throw AppFailure.message("模型地址需要 HTTPS；本地服务可使用 HTTP 回环地址。")
        }
        url.path = url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        url.path = (url.path.isEmpty ? "" : "/" + url.path) + "/chat/completions"
        guard let endpoint = url.url else { throw AppFailure.message("模型地址无效。") }
        return endpoint
    }
}

struct RequestRecord: Codable {
    let id: String
    let source: String
    let text: String
    let createdAt: String
    var phase: String = "received"
    var command: TaskCommand? = nil
    var targetId: String? = nil
    var targetFingerprint: String? = nil
    var beforeTask: ManagedTask? = nil
    var metadataParents: [String] = []
    var dueAt: Date? = nil
    var reply: String? = nil
    var confirmationNumber:Int? = nil
    var clearDue:Bool? = nil
    var groupCalendarID:String? = nil
}

struct ServiceResult: Codable {
    let ok: Bool
    let status: String
    let message: String
    let requestId: String
}

struct ModelProfile:Codable,Equatable,Identifiable {
    var id:String
    var name:String
    var provider:String
    var baseURL:String
    var model:String
    var credentialService:String
}

extension ModelPreferences {
    mutating func migrateProfiles() {
        guard profiles?.isEmpty != false else{return}
        let current=self
        var cloud=current;cloud.provider="cloud";cloud.credentialService=nil
        var local=current;local.provider="local";local.credentialService=nil
        profiles=[ModelProfile(id:"legacy-cloud",name:"云端 Qwen",provider:"cloud",baseURL:cloudURL,model:cloudModel,credentialService:cloud.keyService),
                  ModelProfile(id:"legacy-local",name:"本地 Ollama",provider:"local",baseURL:localURL,model:localModel,credentialService:local.keyService)]
        activateProfile(provider == "cloud" ? "legacy-cloud" : "legacy-local")
    }
    mutating func activateProfile(_ id:String) {
        guard let profile=profiles?.first(where:{$0.id==id}) else{return}
        selectedProfileID=id;provider=profile.provider;credentialService=profile.credentialService
        if provider == "cloud" {cloudURL=profile.baseURL;cloudModel=profile.model}
        else {localURL=profile.baseURL;localModel=profile.model}
    }
    var activeName:String {profiles?.first(where:{$0.id==selectedProfileID})?.name ?? model}
}
