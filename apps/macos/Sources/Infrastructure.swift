import Foundation
import CryptoKit
import EventKit
import Darwin

struct AppPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TaskSecretary")
    static let operations = root.appendingPathComponent("operations")
    static let requests = root.appendingPathComponent("requests")
    static let trash = root.appendingPathComponent("trash")
    static let preferences = root.appendingPathComponent("preferences.json")
    static let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tasksecretary/runtime")
    static func prepare() throws {
        for url in [root,operations,requests,trash,runtime] {
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
    }
    static func write<T: Encodable>(_ item: T,to url:URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(item)
        // Periodic sync re-saves unchanged state; identical bytes were already fsynced by an
        // earlier call, so rewriting them only burns SSD writes (gigabytes per day at 12 s).
        if (try? Data(contentsOf:url)) == data { return }
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let file = try FileHandle(forWritingTo:url); try file.synchronize(); try file.close()
        let directory=Darwin.open(url.deletingLastPathComponent().path,O_RDONLY)
        guard directory>=0 else { throw AppFailure.message("本地目录无法持久保存。") };defer{Darwin.close(directory)}
        guard Darwin.fsync(directory)==0 else {throw AppFailure.message("本地目录同步失败。") }
    }
}

struct SecretStore {
    static let local=LocalSecrets(directory:AppPaths.root.appendingPathComponent("local-secrets",isDirectory:true))
    static func read(service:String,account:String="app")throws->String? {try local.read(service:service,account:account)}
    static func save(_ secret:String,service:String)throws {try local.save(secret,service:service)}
    static func modelKey(_ p:ModelPreferences) throws -> String? {
        if let own = try read(service:p.keyService), !own.isEmpty { return own }
        guard p.selectedProfileID==nil || p.selectedProfileID?.hasPrefix("legacy-")==true else{return nil}
        var original=ModelPreferences();original.provider=p.provider
        let originHash=SHA256.hash(data:Data(p.origin.utf8)).map{String(format:"%02x",$0)}.joined()
        let matches=p.provider == "cloud" ? originHash=="a141df35cf93e03eed0327c9c0a6fde86d8b30a0d84b30bb1422c945c8c8b13a" : original.origin==p.origin
        guard matches else{return nil}
        return try read(service:"TaskSecretary.PoC.AI." + (p.provider == "cloud" ? "cloud" : "ollama"),account:"poc")
    }
}

final class ModelClient: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func analyze(_ text:String,id:String,tasks:[ManagedTask],preferences:ModelPreferences,recentActivity:[[String:String]],groups:[TaskGroup],groupingPrompt:String,numbers:TaskNumbers) async throws -> TaskCommand {
        let endpoint = try preferences.endpoint()
        guard !preferences.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw AppFailure.message("请先在设置中填写模型 ID；也可直接手动添加待办。")}
        let key = try await Task.detached { try SecretStore.modelKey(preferences) }.value
        if preferences.provider == "cloud", key?.isEmpty != false {
            throw AppFailure.message("尚未配置云端模型 Key，请打开右上角模型设置。")
        }
        let instructions = try String(contentsOf:Bundle.main.url(forResource:"instructions",withExtension:"txt")!,encoding:.utf8)
        let schema = try String(contentsOf:Bundle.main.url(forResource:"command.schema",withExtension:"json")!,encoding:.utf8)
        let localClock=DateFormatter();localClock.locale=Locale(identifier:"zh_CN");localClock.timeZone=TimeZone.current;localClock.dateFormat="yyyy-MM-dd EEEE HH:mm:ss"
        let context:[String:Any] = ["now":ISO8601DateFormatter().string(from:Date()),
            "timeZone":TimeZone.current.identifier,"localDate":localClock.string(from:Date()) ,"groupingInstructions":groupingPrompt,"operationId":id,"input":text,"recentActivity":recentActivity,
            "tasks":ModelContextSelection.select(tasks,input:text,numbers:numbers).map{
                ["id":$0.id,"number":String(numbers.values[$0.id] ?? 0),"title":$0.title,"status":$0.status,"groupId":$0.group.rawValue] },
            "groups":groups.map{["id":$0.rawValue,"name":$0.title]}]
        var request = URLRequest(url:endpoint)
        request.httpMethod="POST"; request.timeoutInterval=preferences.provider == "cloud" ? 35 : 65
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let key=key,!key.isEmpty { request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization") }
        request.httpBody=try JSONSerialization.data(withJSONObject:["model":preferences.model,"temperature":0,
            "response_format":["type":"json_object"],"messages":[
                ["role":"system","content":instructions + "\nJSON Schema: " + schema],
                ["role":"user","content":String(data:try JSONSerialization.data(withJSONObject:context),encoding:.utf8)!]]])
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=request.timeoutInterval
        let session=URLSession(configuration:config,delegate:self,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse else { throw AppFailure.message("模型服务没有有效响应。") }
        guard http.statusCode==200 else { throw AppFailure.message("模型服务返回 HTTP \(http.statusCode)，未修改任务。") }
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let choices=json["choices"] as? [[String:Any]],let message=choices.first?["message"] as? [String:Any],
              let content=message["content"] as? String,let commandData=content.data(using:.utf8) else {
            throw AppFailure.message("模型未返回有效命令，未修改任务。")
        }
        let decoded=try TaskCommand.decode(commandData,expectedId:id,tasks:tasks)
        let refined=ConversationRules.refine(decoded,input:text)
        return try TaskCommand.decode(JSONEncoder().encode(refined),expectedId:id,tasks:tasks)
    }
}

@MainActor
final class RemindersStore {
    let eventStore=EKEventStore()
    var sourceIdentifier:String?
    var sourceChoices:[(id:String,title:String)] = []
    var calendars:[TaskGroup:EKCalendar] = [:]
    func connect(source:String?) async throws {
        switch EKEventStore.authorizationStatus(for:.reminder) {
        case .fullAccess:break
        case .notDetermined:
            guard try await eventStore.requestFullAccessToReminders() else{throw AppFailure.message("提醒事项访问未获允许。可在系统设置 → 隐私与安全性 → 提醒事项中为记事喵开启。")}
        default:throw AppFailure.message("提醒事项访问已被关闭。请在系统设置 → 隐私与安全性 → 提醒事项中为记事喵开启，不会重复弹出授权。")
        }
        eventStore.reset()
        var seen=Set<String>()
        sourceChoices=eventStore.calendars(for:.reminder).filter{$0.allowsContentModifications}.compactMap { c in
            guard seen.insert(c.source.sourceIdentifier).inserted else { return nil }
            return (c.source.sourceIdentifier,c.source.title)
        }
        sourceIdentifier=source ?? sourceChoices.first(where:{$0.title.localizedCaseInsensitiveContains("iCloud")})?.id ?? sourceChoices.first?.id
        guard let selected=sourceIdentifier,let account=eventStore.sources.first(where:{$0.sourceIdentifier==selected}) else {
            throw AppFailure.message("没有可用的提醒事项账户，请先在系统提醒事项中启用账户。")
        }
        calendars=[:]
        for list in eventStore.calendars(for:.reminder) where list.source.sourceIdentifier==selected {
            let prefix=list.title.hasPrefix("AI任务秘书-") ? "AI任务秘书-" : list.title.hasPrefix("AI任务秘书 · ") ? "AI任务秘书 · " : ""
            guard !prefix.isEmpty,let group=TaskGroup.named(String(list.title.dropFirst(prefix.count))) else{continue}
            guard calendars[group]==nil else{throw AppFailure.message("发现重名的专用分组，请先核对提醒事项。")}
            calendars[group]=list
        }
        _=account
        try ensureGroup(.inbox)
        if let inbox=calendars[.inbox],inbox.title != TaskGroup.inbox.calendarTitle {
            inbox.title=TaskGroup.inbox.calendarTitle;try eventStore.saveCalendar(inbox,commit:true)
        }
    }
    func ensureGroup(_ group:TaskGroup)throws {
        guard calendars[group]==nil else{return}
        guard let selected=sourceIdentifier,let source=eventStore.sources.first(where:{$0.sourceIdentifier==selected}) else{throw AppFailure.message("请先连接提醒事项账户。")}
        // Re-read immediately before create, making crash/retry idempotent.
        let matches=eventStore.calendars(for:.reminder).filter{$0.source.sourceIdentifier==selected && $0.title==group.calendarTitle}
        guard matches.count<=1 else{throw AppFailure.message("分组重名，请先核对提醒事项。")}
        if let found=matches.first {calendars[group]=found;return}
        let list=EKCalendar(for:.reminder,eventStore:eventStore);list.title=group.calendarTitle;list.source=source
        try eventStore.saveCalendar(list,commit:true);calendars[group]=list
    }

    func refreshGroups()throws {
        guard let selected=sourceIdentifier else{return}
        var result:[TaskGroup:EKCalendar]=[:]
        for list in eventStore.calendars(for:.reminder) where list.source.sourceIdentifier==selected {
            let prefix=list.title.hasPrefix("AI任务秘书-") ? "AI任务秘书-" : list.title.hasPrefix("AI任务秘书 · ") ? "AI任务秘书 · " : ""
            guard !prefix.isEmpty,let group=TaskGroup.named(String(list.title.dropFirst(prefix.count))) else{continue}
            guard result[group]==nil else{throw AppFailure.message("发现重名专用分组，已暂停。")};result[group]=list
        }
        calendars=result
    }

    func fetch() async throws -> [EKReminder] {
        guard !calendars.isEmpty else { return [] }
        let predicate=eventStore.predicateForReminders(in:Array(calendars.values))
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching:predicate) { items in
                if let items=items { continuation.resume(returning:items) }
                else { continuation.resume(throwing:AppFailure.message("读取提醒事项失败，请刷新后重试。")) }
            }
        }
    }
    static func url(_ id:String) -> URL { URL(string:"tasksecretary://task/"+id)! }
    static func taskID(_ reminder:EKReminder) -> String? {
        guard let url=reminder.url,url.scheme=="tasksecretary",url.host=="task" else { return nil }
        let id=url.lastPathComponent
        return MetadataOperation.isID(id) ? id : nil
    }
    func listGroup(_ r:EKReminder) -> TaskGroup? { calendars.first(where:{$0.value.calendarIdentifier==r.calendar.calendarIdentifier})?.key }
    func due(_ r:EKReminder) -> Date? { r.dueDateComponents.flatMap{Calendar(identifier:.gregorian).date(from:$0)} }
    func apply(_ record:RequestRecord) async throws {
        guard let c=record.command,let id=record.targetId else { throw AppFailure.message("执行记录不完整。") }
        let matches=try await fetch().filter{Self.taskID($0)==id}
        guard matches.count<=1 else { throw AppFailure.message("业务ID对应多个任务，已暂停执行。") }
        let trash=try TaskTrashStore(directory:AppPaths.trash)
        if c.intent=="delete_task" {
            guard let before=record.beforeTask else{throw AppFailure.message("缺少可恢复的删除前快照。")}
            if let found=matches.first {
                if try trash.load(id)?.operationID != record.id {
                    try trash.save(TrashEntry(operationID:record.id,snapshot:TaskSnapshot(task:before,reminder:found)))
                }
                // Never remove the system entity until a durable recoverable snapshot exists.
                guard try trash.load(id) != nil else{throw AppFailure.message("回收快照未保存，未删除任务。")}
                try eventStore.remove(found,commit:true)
            } else if try trash.load(id)==nil {throw AppFailure.message("系统任务与回收快照均不存在，无法安全删除。")}
            guard try await fetch().allSatisfy({Self.taskID($0) != id}) else{throw AppFailure.message("系统任务删除尚未回读确认。")}
            return
        }
        let reminder:EKReminder
        if let found=matches.first { reminder=found }
        else {
            guard c.intent=="create_task" || c.intent=="restore_task" else { throw AppFailure.message("任务已不存在，已暂停执行。") }
            reminder=EKReminder(eventStore:eventStore);reminder.url=Self.url(id);reminder.calendar=calendars[.inbox]!
            if c.intent=="restore_task" {
                guard let entry=try trash.load(id) else{throw AppFailure.message("没有完整的回收快照，无法恢复。")}
                entry.snapshot.fill(reminder)
                reminder.calendar=calendars[record.beforeTask?.group ?? entry.snapshot.task.group] ?? calendars[.inbox]!
            }
        }
        if let title=c.text("title") { reminder.title=title.trimmingCharacters(in:.whitespacesAndNewlines) }
        if let notes=c.text("notes") {reminder.notes=notes}
        if let group=c.text("groupId").flatMap(TaskGroup.init(rawValue:)) {try ensureGroup(group);reminder.calendar=calendars[group]}
        if c.intent=="complete_task" || c.text("status")=="done" { reminder.isCompleted=true }
        if c.intent=="reopen_task" || c.text("status").map({$0 != "done"})==true { reminder.isCompleted=false }
        let previousDue=due(reminder)
        if record.clearDue==true {
            reminder.startDateComponents=nil;reminder.dueDateComponents=nil
            reminder.alarms=reminder.alarms?.filter{$0.structuredLocation != nil}
        }
        if let due=record.dueAt {
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone.current
            let components=calendar.dateComponents([.calendar,.timeZone,.year,.month,.day,.hour,.minute,.second],from:due)
            reminder.startDateComponents=components;reminder.dueDateComponents=components
            if let previousDue {
                for alarm in reminder.alarms ?? [] {
                    if let absolute=alarm.absoluteDate {alarm.absoluteDate=absolute.addingTimeInterval(due.timeIntervalSince(previousDue))}
                }
            }
            if reminder.alarms?.isEmpty != false {reminder.addAlarm(EKAlarm(absoluteDate:due))}
        }
        try eventStore.save(reminder,commit:true)
    }
}

extension RemindersStore {
    func mutateGroup(_ record:RequestRecord) async throws {
        guard let c=record.command,let raw=c.text("groupId"),let group=TaskGroup(rawValue:raw),group != .inbox,
              let calendarID=record.groupCalendarID else{throw AppFailure.message("分组操作记录不完整。")}
        let sourceLists=eventStore.calendars(for:.reminder).filter{$0.source.sourceIdentifier==sourceIdentifier}
        guard let list=sourceLists.first(where:{$0.calendarIdentifier==calendarID}) else {
            if c.intent=="delete_group" {calendars.removeValue(forKey:group);return}
            throw AppFailure.message("原分组已不存在，请刷新。")
        }
        if c.intent=="rename_group" {
            guard let new=c.text("newGroupId").flatMap(TaskGroup.init(rawValue:)),new != .inbox else{throw AppFailure.message("新分组名称无效。")}
            guard !sourceLists.contains(where:{$0.calendarIdentifier != calendarID && $0.title==new.calendarTitle}) else{throw AppFailure.message("已有同名分组，请换一个名称。")}
            guard list.title==group.calendarTitle || list.title==new.calendarTitle else{throw AppFailure.message("分组名称已经变化，请重新操作。")}
            list.title=new.calendarTitle;try eventStore.saveCalendar(list,commit:true)
            calendars.removeValue(forKey:group);calendars[new]=list
        } else {
            guard list.title==group.calendarTitle else{throw AppFailure.message("分组已变化，未删除。")}
            try ensureGroup(.inbox)
            let predicate=eventStore.predicateForReminders(in:[list])
            let rows:[EKReminder]=try await withCheckedThrowingContinuation { continuation in
                eventStore.fetchReminders(matching:predicate){items in
                    if let items {continuation.resume(returning:items)} else{continuation.resume(throwing:AppFailure.message("读取分组任务失败。"))}
                }
            }
            // Preserve every reminder, including entries made in Apple's app, before removing the list.
            for row in rows {row.calendar=calendars[.inbox];try eventStore.save(row,commit:false)}
            try eventStore.commit()
            let remaining:[EKReminder]=try await withCheckedThrowingContinuation { continuation in
                eventStore.fetchReminders(matching:predicate){items in
                    if let items {continuation.resume(returning:items)}else{continuation.resume(throwing:AppFailure.message("无法核对分组是否为空。"))}
                }
            }
            guard remaining.isEmpty else{throw AppFailure.message("分组中有新任务，请重试；任务已保留。")}
            try eventStore.removeCalendar(list,commit:true);calendars.removeValue(forKey:group)
        }
    }
    func permanentlyDelete(_ record:RequestRecord,recovery:Bool) async throws {
        guard let id=record.targetId,record.beforeTask?.softDeleted==true else{throw AppFailure.message("只能彻底删除回收站里的任务。")}
        let matches=try await fetch().filter{Self.taskID($0)==id}
        guard matches.count<=1 else{throw AppFailure.message("发现重复任务，已暂停删除。")}
        if let row=matches.first {try eventStore.remove(row,commit:true)}
        else if !recovery,try TaskTrashStore(directory:AppPaths.trash).load(id)==nil {throw AppFailure.message("任务已不存在，请刷新回收站。")}
    }
}
