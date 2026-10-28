import Foundation
import Combine
import EventKit
import AppKit

@MainActor
final class TaskService: ObservableObject {
    @Published var composerCollapsed=UserDefaults.standard.bool(forKey:"TaskSecretary.composerCollapsed") {didSet{UserDefaults.standard.set(composerCollapsed,forKey:"TaskSecretary.composerCollapsed")}}
    @Published var profileNameDraft=""
    @Published var groupRenameDraft=""
    @Published var groupEditingID=""
    @Published var groupsNotice=""
    @Published var destructiveAction:DestructiveAction?
    @Published var progressCompletionPresented=false
    @Published var barkPreferences=BarkPreferences()
    @Published var barkKeyDraft=""
    @Published var barkNotice="尚未启用到期推送"
    @Published var loginEnabled=false
    @Published var loginNotice=""
    var reminderTimer:Timer?
    var barkSending=false
    @Published var inputText=""
    @Published var tasksExpanded=false
    @Published var dataNotice="备份包含任务与扩展数据，不包含 API Key 或微信会话。"
    @Published var restorePending=false
    @Published var backupRestorePresented=false
    var proposedBackup:TaskBackup?
    @Published var selectedTab="tasks"
    @Published var taskLens:TaskLens = .active
    @Published var feedback:[FeedbackItem]=[]
    @Published var processingStage=""
    @Published var processingInput=""
    @Published var groups:[TaskGroup]=[.inbox]
    @Published var groupDraft=""
    let groupingPrompt="按用户明确指定的分组优先分类；否则匹配已有项目或主题，只有任务有明确独立项目且现有分组均不适合时才创建分组；日常零散事项和归属不明事项放收件箱。不按职业、开发阶段或个人/工作自动划分，不创建重复或近义分组。"
    @Published var groupsPresented=false
    @Published var editorPresented=false
    @Published var editTitle=""
    @Published var editNotes=""
    @Published var editGroup="inbox"
    @Published var editStatus="todo"
    @Published var editProgress=0.0
    @Published var editHasProgress=false
    @Published var editHasDue=false
    @Published var editDue=Date()
    @Published var pendingDateChecked=false
    var editingTask:ManagedTask?
    var taskNumbers=TaskNumbers()

    @Published var keyDraft=""
    @Published var settingsNotice=""
    @Published var tasks:[ManagedTask]=[]
    @Published var isConnected=false
    @Published var busy=false
    /// True while the periodic sync refresh holds `busy`. It still excludes concurrent writes,
    /// but the UI ignores it so controls don't dim every 12 seconds.
    @Published private(set) var backgroundSyncing=false
    var uiBusy:Bool {busy && !backgroundSyncing}
    // Storage work also holds busy; only a submitted conversation may replace the input UI.
    var conversationProcessing:Bool {busy && !processingInput.isEmpty}
    @Published var message="一句话，安排好接下来的事。"
    @Published var errorMessage:String?=nil
    @Published var pending:RequestRecord?=nil
    @Published var pendingDate=Date()
    @Published var selectedGroup:String="all"
    @Published var showCompleted=false
    @Published var showTrash=false
    @Published var settingsPresented=false
    /// "popover" or "window": the surface the user last used; only it presents sheets and alerts.
    @Published var activeSurface="popover"
    @Published var settingsTab="general"
    /// Latest exchange shown under the composer; the full history lives in 对话.
    @Published var latestReply:FeedbackItem?
    @Published var briefingInProgress=false
    @Published var highlightedTaskID:String?
    @Published var undoNotice:UndoNotice?
    @Published var searchText=""
    @Published var searchVisible=false
    /// Bumped by the global shortcut; the visible surface focuses its input.
    @Published var focusRequest=0
    @Published var modelTestNotice=""
    @Published var dailyBriefingEnabled=UserDefaults.standard.object(forKey:"TaskSecretary.briefing.enabled") as? Bool ?? true {didSet{UserDefaults.standard.set(dailyBriefingEnabled,forKey:"TaskSecretary.briefing.enabled")}}
    @Published var hotKeyEnabled=UserDefaults.standard.object(forKey:"TaskSecretary.hotkey.enabled") as? Bool ?? true {didSet{UserDefaults.standard.set(hotKeyEnabled,forKey:"TaskSecretary.hotkey.enabled")}}
    @Published var menuBadgeEnabled=UserDefaults.standard.object(forKey:"TaskSecretary.menuBadge.enabled") as? Bool ?? true {didSet{UserDefaults.standard.set(menuBadgeEnabled,forKey:"TaskSecretary.menuBadge.enabled")}}
    @Published var preferences=ModelPreferences()
    @Published var sourceChoices:[(id:String,title:String)]=[]
    @Published var syncNote="任务由系统提醒事项管理；扩展数据先在本机持久保存。"
    @Published var oldOwnerStopped=false
    @Published var wechatState="stopped"
    @Published var wechatQRCode:NSImage?=nil
    var wechatBridge:WeChatBridge?
    /// The number WeChat shows on the phone when it asks to confirm a new connection.
    @Published var wechatVerifyCode=""
    var metadataTimer:Timer?
    var metadataSyncProblem:String?
    @Published var metadataSyncEnabled=false
    let reminders=RemindersStore()
    let model=ModelClient()
    var journal:OperationJournal!
    var actorID=""
    private var refreshObserver:NSObjectProtocol?
    private var lastArchive=Date.distantPast

    init() {
        do {
            try AppPaths.prepare()
            restorePending=FileManager.default.fileExists(atPath:AppPaths.root.appendingPathComponent("pending-restore.taskcatbackup").path)
            if restorePending {dataNotice="上次恢复尚未完成，请在数据与恢复中继续；未覆盖系统中的已有任务。"}
            journal=try OperationJournal(directory:AppPaths.operations)
            if let data=try? Data(contentsOf:AppPaths.preferences),let p=try? JSONDecoder().decode(ModelPreferences.self,from:data) { preferences=p }
            if let data=try? Data(contentsOf:AppPaths.root.appendingPathComponent("task-numbers.json")) {taskNumbers=try JSONDecoder().decode(TaskNumbers.self,from:data)}
            preferences.migrateProfiles()
            // Earlier versions turned "confirm everything" on for local models; confirmation is now
            // asked only when a request is uncertain, so reset that automatic default once.
            if !UserDefaults.standard.bool(forKey:"TaskSecretary.confirmWhenUnsure") {
                if preferences.confirmAll {preferences.confirmAll=false;try? AppPaths.write(preferences,to:AppPaths.preferences)}
                UserDefaults.standard.set(true,forKey:"TaskSecretary.confirmWhenUnsure")
            }
            loadExperiencePreferences()
            let file=AppPaths.root.appendingPathComponent("actor.json")
            if let data=try? Data(contentsOf:file),let id=try? JSONDecoder().decode(String.self,from:data) { actorID=id }
            else { actorID=UUID().uuidString.lowercased();try AppPaths.write(actorID,to:file) }
            // WeChat now runs in-process; the local socket the Python worker used is gone.
            for stale in ["command.sock","command-token.json"] {try? FileManager.default.removeItem(at:AppPaths.runtime.appendingPathComponent(stale))}
            refreshObserver=NotificationCenter.default.addObserver(forName:.EKEventStoreChanged,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in guard let self=self,self.isConnected,!self.busy else { return };try? await self.reload() }
            }
            if EKEventStore.authorizationStatus(for:.reminder) == .fullAccess {
                Task { await connect() }
            }
        } catch { errorMessage="本地数据目录初始化失败：\(error.localizedDescription)" }
    }
    var visibleTasks:[ManagedTask] {
        TaskBoard.select(tasks,group:selectedGroup,lens:taskLens,trash:showTrash,includeCompleted:showCompleted,query:searchVisible ? searchText : "")
    }
    var activeCount:Int { tasks.filter{!$0.softDeleted && !$0.archived && !$0.completed && $0.status != "cancelled"}.count }
    func connect() async {
        guard !busy else { return };busy=true;defer{busy=false}
        do {
            try await reminders.connect(source:preferences.sourceIdentifier)
            preferences.sourceIdentifier=reminders.sourceIdentifier;sourceChoices=reminders.sourceChoices
            try savePreferences();isConnected=true
            metadataSyncEnabled=FileManager.default.fileExists(atPath:AppPaths.root.appendingPathComponent("metadata-sync.json").path)
            try await reload()
            try await recover()
            archiveOldRequests()
            startReminderScheduler()
            startMetadataTimer()
            if UserDefaults.standard.bool(forKey:"TaskSecretary.wechatAutoConnect") && UserDefaults.standard.bool(forKey:"TaskSecretary.confirmedSingleOwner") {
                oldOwnerStopped=true;startWeChat()
            }
            message="已连接提醒事项，可以开始安排任务。"
        } catch { errorMessage=error.localizedDescription }
    }
    func savePreferences() throws {try AppPaths.write(preferences,to:AppPaths.preferences);try saveExperiencePreferences() }
    func refresh(background:Bool=false) async {
        guard !busy,isConnected else{return}
        busy=true;backgroundSyncing=background;defer{busy=false;backgroundSyncing=false}
        do { try await reload() } catch { errorMessage=error.localizedDescription }
    }
    func reload() async throws {
        await syncMetadata()
        try reminders.refreshGroups()
        let rows=try await reminders.fetch()
        let projection=try journal.project()
        let metadata=Dictionary(uniqueKeysWithValues:projection.entities.filter{$0.entityType=="task"}.map{($0.entityId,$0)})
        var ids=Set<String>();var result:[ManagedTask]=[]
        for r in rows {
            guard let id=RemindersStore.taskID(r),let group=reminders.listGroup(r) else { continue }
            guard ids.insert(id).inserted else { throw AppFailure.message("发现重复业务ID，已暂停处理，请核对系统提醒事项。") }
            let m=metadata[id];let values=m?.values ?? [:]
            func flag(_ k:String)->Bool { if case .flag(let b)=values[k] { return b };return false }
            var status=r.isCompleted ? "done" : "todo"
            if case .text(let s)=values["status"],s != "done",!r.isCompleted { status=s }
            var progress:Int?=nil;if case .number(let n)=values["progress"] { progress=max(10,min(100,Int((Double(n)/10).rounded())*10)) }
            result.append(ManagedTask(id:id,title:r.title ?? "未命名任务",notes:r.notes ?? "",group:group,
                status:status,progress:progress,dueAt:reminders.due(r),completed:r.isCompleted,
                softDeleted:flag("softDeleted"),archived:flag("archived"),
                conflicted:m == nil || !projection.missingParents.isEmpty || !(m?.conflicts.isEmpty ?? true) || (metadataSyncEnabled && taskNumbers.values[id]==nil)))
        }
        for entry in try TaskTrashStore(directory:AppPaths.trash).all() where !ids.contains(entry.snapshot.task.id) {
            let m=metadata[entry.snapshot.task.id]
            if case .flag(true)=m?.values["archived"] {continue}
            var task=entry.snapshot.task;task.softDeleted=true
            let committed=m?.values["softDeleted"] == .flag(true)
            task.conflicted = !committed || !projection.missingParents.isEmpty || !(m?.conflicts.isEmpty ?? true)
            if reminders.calendars[task.group]==nil {task.group = .inbox}
            result.append(task);ids.insert(task.id)
        }
        taskNumbers.assign(result)
        try AppPaths.write(taskNumbers,to:AppPaths.root.appendingPathComponent("task-numbers.json"))
        tasks=result
        groups=reminders.calendars.keys.sorted {a,b in a == .inbox ? b != .inbox : b == .inbox ? false : a.title.localizedStandardCompare(b.title) == .orderedAscending}
    }
    private func recordURL(_ id:String)->URL { AppPaths.requests.appendingPathComponent(id+".json") }
    func loadRecord(_ id:String)throws->RequestRecord? {
        guard MetadataOperation.isID(id) else { throw AppFailure.message("请求ID无效。") }
        // Archived records still answer by ID, so a late WeChat retry is never executed twice.
        for file in [recordURL(id),AppPaths.requestArchive.appendingPathComponent(id+".json")] where FileManager.default.fileExists(atPath:file.path) {
            return try JSONDecoder().decode(RequestRecord.self,from:Data(contentsOf:file))
        }
        return nil
    }
    private func nextConfirmationNumber(source:String)throws->Int {
        let stored=(try? JSONDecoder().decode([String:Int].self,from:Data(contentsOf:AppPaths.confirmationCounters))) ?? [:]
        let current=try allRecords().filter{$0.source==source}.compactMap(\.confirmationNumber).max() ?? 0
        return max(stored[source] ?? 0,current)+1
    }
    /// Moves old finished records out of the scanned folder; runs at connect and at most hourly.
    func archiveOldRequests(now:Date=Date()) {
        lastArchive=now
        let fm=FileManager.default
        guard let files=try? fm.contentsOfDirectory(at:AppPaths.requests,includingPropertiesForKeys:nil).filter({$0.pathExtension=="json"}),
              files.count>RequestRetention.keepRecent else{return}
        let items=files.compactMap{file->RequestRetention.Item? in
            guard let r=try? JSONDecoder().decode(RequestRecord.self,from:Data(contentsOf:file)) else{return nil}
            return RequestRetention.Item(id:r.id,phase:r.phase,createdAt:r.createdAt,source:r.source,confirmationNumber:r.confirmationNumber)
        }
        let ids=RequestRetention.archivable(items,now:now)
        guard !ids.isEmpty else{return}
        do {
            // Record the numbers first: once archived they no longer count towards the next one.
            let stored=(try? JSONDecoder().decode([String:Int].self,from:Data(contentsOf:AppPaths.confirmationCounters))) ?? [:]
            try AppPaths.write(RequestRetention.counters(items,merging:stored),to:AppPaths.confirmationCounters)
            for id in ids {try fm.moveItem(at:recordURL(id),to:AppPaths.requestArchive.appendingPathComponent(id+".json"))}
        } catch {dataNotice="整理旧请求记录未完成："+error.localizedDescription}
    }
    func saveRecord(_ record:RequestRecord)throws { try AppPaths.write(record,to:recordURL(record.id)) }
    func submit(_ text:String,source:String="menu",id:String=UUID().uuidString.lowercased()) async -> ServiceResult {
        let result=await execute(text,source:source,id:id)
        if Date().timeIntervalSince(lastArchive)>3600 {archiveOldRequests()}
        if result.status != "busy" {
            let item=FeedbackItem(input:text,output:result.message,isError:!result.ok,origin:source.hasPrefix("wechat:") ? "wechat" : "menu")
            feedback.insert(item,at:0);latestReply=item
            if feedback.count>40 {feedback.removeLast(feedback.count-40)}
        }
        return result
    }
    private func execute(_ text:String,source:String,id:String) async -> ServiceResult {
        let input=text.trimmingCharacters(in:.whitespacesAndNewlines)
        if restorePending {return ServiceResult(ok:false,status:"busy",message:"数据恢复尚未完成，请在设置中继续恢复。",requestId:id)}
        if ConversationRules.confirmation(input) != nil {
            return await handleConfirmationText(input,source:source,id:id)
        }
        guard MetadataOperation.isID(id),!input.isEmpty,input.count<=2000 else { return ServiceResult(ok:false,status:"rejected",message:"请输入1到2000字的任务描述。",requestId:id) }
        if !(await waitUntilIdle()) { return ServiceResult(ok:false,status:"busy",message:"正在处理上一条，请稍后重试。",requestId:id) }
        if let control=modelControl(input,id:id,source:source) {return control}
        guard isConnected else { return ServiceResult(ok:false,status:"rejected",message:"请先在菜单栏连接提醒事项。",requestId:id) }
        busy=true;errorMessage=nil;processingInput=input;processingStage="正在读取任务与上下文";defer{busy=false;processingStage="";processingInput=""}
        var record:RequestRecord?
        do {
            if let existing=try loadRecord(id) {
                guard existing.source==source,existing.text==input else { throw AppFailure.message("相同请求ID的内容不一致，已拒绝。") }
                if ["applied","awaiting_confirmation","cancelled"].contains(existing.phase) {
                    if existing.phase=="awaiting_confirmation" { pending=existing;pendingDate=existing.dueAt ?? Date();pendingDateChecked=existing.dueAt != nil }
                    return ServiceResult(ok:true,status:existing.phase,message:existing.reply ?? "请求已处理。",requestId:id)
                }
                if ["applying","uncertain"].contains(existing.phase) {
                    var recovery=existing;try await apply(&recovery,recovery:true)
                    return ServiceResult(ok:true,status:recovery.phase,message:recovery.reply ?? "已恢复处理。",requestId:id)
                }
                record=existing
            } else {
                record=RequestRecord(id:id,source:source,text:input,createdAt:ISO8601DateFormatter().string(from:Date()))
                try saveRecord(record!)
            }
            try await reload()
            let snapshot=tasks
            message="正在理解你的安排…";processingStage="正在思考 · 分析任务、分组与日期"
            var command:TaskCommand
            if let local=try localCommand(input,id:id,snapshot:snapshot) {command=local}
            else {command=try await model.analyze(input,id:id,tasks:snapshot,preferences:preferences,recentActivity:try recentActivity(),groups:groups,groupingPrompt:groupingPrompt,numbers:taskNumbers)}
            processingStage="正在校验操作与日期"
            command=try ConversationRules.cleanCreation(ConversationRules.scopeQuery(ConversationRules.refine(command,input:input),input:input,groups:groups),input:input,groups:groups)
            command=try TaskCommand.decode(JSONEncoder().encode(command),expectedId:id,tasks:snapshot)
            command.requiresConfirmation=preferences.confirmAll || ConversationRules.needsConfirmation(command,input:input,tasks:snapshot,numbers:taskNumbers)
            record!.command=command
            if command.intent=="clarify" { throw AppFailure.message("还不能确定要处理哪件事，请补充具体任务名称或操作。") }
            if command.intent=="query_tasks" {
                let filtered=ConversationRules.query(snapshot,input:input,command:command).sorted{(taskNumbers.values[$0.id] ?? 0)<(taskNumbers.values[$1.id] ?? 0)}
                let reply=ConversationRules.list(filtered,numbers:taskNumbers)
                record!.phase="applied";record!.reply=reply;try saveRecord(record!);message=reply
                return ServiceResult(ok:true,status:"applied",message:reply,requestId:id)
            }
            if command.intent=="query_groups" {
                let reply="当前分组（\(groups.count)）\n\n"+groups.enumerated().map{"\($0.offset+1)、\($0.element.title)"}.joined(separator:"\n")+"\n\n可说：创建分组 项目A；项目A分组改名项目B；删除分组项目A；把任务5移到项目A。"
                record!.phase="applied";record!.reply=reply;try saveRecord(record!);message=reply
                return ServiceResult(ok:true,status:"applied",message:reply,requestId:id)
            }
            record!.targetId=command.intent=="create_task" ? id : ["create_group","rename_group","delete_group"].contains(command.intent) ? TaskGroup(rawValue:command.text("groupId") ?? "")?.uuid : command.taskId
            if ["rename_group","delete_group"].contains(command.intent) {
                guard let group=command.text("groupId").flatMap(TaskGroup.init(rawValue:)),let calendar=reminders.calendars[group] else{throw AppFailure.message("没有找到该分组，请先查看分组。")}
                if let new=command.text("newGroupId").flatMap(TaskGroup.init(rawValue:)),groups.contains(new){throw AppFailure.message("已有同名分组，请换一个名称。")}
                record!.groupCalendarID=calendar.calendarIdentifier
            }
            record!.beforeTask=snapshot.first{$0.id==command.taskId}
            record!.targetFingerprint=record!.beforeTask?.fingerprint
            if let date=command.dateText { record!.dueAt=DateSuggestion.date(for:date) }
            if command.requiresConfirmation {
                record!.confirmationNumber=try nextConfirmationNumber(source:source)
                record!.phase="awaiting_confirmation"
                let reply=confirmationMessage(record!)
                record!.reply=reply;try saveRecord(record!);pending=record;pendingDate=record!.dueAt ?? Date();pendingDateChecked=record!.dueAt != nil
                message="已分析，等待你确认。"
                return ServiceResult(ok:true,status:"awaiting_confirmation",message:reply,requestId:id)
            }
            try await apply(&record!,recovery:false)
            return ServiceResult(ok:true,status:"applied",message:record!.reply ?? "已处理。",requestId:id)
        } catch {
            let text=error.localizedDescription
            if var failed=record {
                if failed.phase != "applying" && failed.phase != "uncertain" { failed.phase="failed" }
                else { failed.phase="uncertain" }
                failed.reply=text;try? saveRecord(failed)
            }
            errorMessage=text;message="任务未确认成功，请查看提示。"
            return ServiceResult(ok:false,status:record?.phase=="applying" ? "uncertain" : "failed",message:text,requestId:id)
        }
    }
    private func allRecords()throws->[RequestRecord] {
        try FileManager.default.contentsOfDirectory(at:AppPaths.requests,includingPropertiesForKeys:nil)
            .filter{$0.pathExtension=="json"}.map{try JSONDecoder().decode(RequestRecord.self,from:Data(contentsOf:$0))}
    }
    func confirmationMessage(_ r:RequestRecord)->String {
        let target=r.beforeTask?.title ?? r.command?.text("title") ?? r.command?.text("groupId") ?? "任务"
        let number=r.beforeTask.flatMap{taskNumbers.values[$0.id]}.map{"任务\($0) · "} ?? ""
        let code=r.confirmationNumber.map(String.init) ?? String(r.id.prefix(8))
        var result="待确认 \(code)\n\n操作：\(r.command?.description ?? "处理")\n目标：\(number)\(target)"
        if case .number(100)=r.command?.patch["progress"] {result+="\n进度：100% · 是否将此任务标记完成？"}
        if r.command?.intent=="delete_group" {result+="\n分组里的全部任务将移至收件箱，任务不会删除。"}
        if let status=r.command?.text("status") {result+="\n状态："+(["todo":"待办","doing":"进行中","waiting":"等待","done":"已完成","cancelled":"已取消"][status] ?? status)}
        if let text=r.command?.dateText {
            let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.timeZone=TimeZone.current;f.dateFormat="yyyy-MM-dd HH:mm"
            result+="\n日期："+(r.dueAt.map{f.string(from:$0)+"（本机时区；未指定时刻默认09:00）"} ?? "“\(text)”尚不能确定，请在菜单栏选择")
        }
        return result+"\n\n回复「确认\(code)」或「取消\(code)」"
    }
    func apply(_ record:inout RequestRecord,recovery:Bool) async throws {
        if let problem=metadataSyncProblem {throw AppFailure.message(problem)}
        guard !restorePending else{throw AppFailure.message("请先在设置中完成数据恢复，再修改任务。")}
        guard let c=record.command,let targetID=record.targetId else { throw AppFailure.message("执行记录不完整。") }
        if ["rename_group","delete_group"].contains(c.intent) {
            record.phase="applying";try saveRecord(record)
            try await reminders.mutateGroup(record);try await reload()
            if let new=c.text("newGroupId"),selectedGroup==c.text("groupId") {selectedGroup=new}
            if c.intent=="delete_group",selectedGroup==c.text("groupId") {selectedGroup="inbox"}
            record.phase="applied";record.reply=c.intent=="rename_group" ? "已重命名分组：\(c.text("newGroupId") ?? "")" : "已删除分组，原任务已保留并移至收件箱。"
            try saveRecord(record);message=record.reply!;return
        }
        if c.intent=="purge_task" {try await applyPermanentDeletion(&record,recovery:recovery);return}
        if c.intent=="create_group" {
            guard let raw=c.text("groupId"),let group=TaskGroup(rawValue:raw) else{throw AppFailure.message("分组名称无效。")}
            record.phase="applying";try saveRecord(record);try reminders.ensureGroup(group);try await reload()
            record.phase="applied";record.reply="已创建分组：\(group.title)";try saveRecord(record);message=record.reply!;return
        }
        processingStage="正在保存并回读任务"
        try await reload()
        if let problem=metadataSyncProblem {throw AppFailure.message(problem)}
        if c.intent=="create_task" {try taskNumbers.reserve(targetID);try AppPaths.write(taskNumbers,to:AppPaths.root.appendingPathComponent("task-numbers.json"))}
        let current=tasks.first{$0.id==targetID}
        let existing=try journal.load()[record.id]
        if !recovery {
            if let before=record.beforeTask {
                guard current?.fingerprint==before.fingerprint else { throw AppFailure.message("任务在分析后发生了变化，请重新描述操作。") }
            } else if current != nil { throw AppFailure.message("新增任务ID已存在，请刷新后重试。") }
            let projection=try journal.project()
            guard projection.causallyCompleteAndConflictFree else { throw AppFailure.message("扩展数据存在缺失或冲突，已暂停写入。") }
            record.metadataParents=projection.heads;record.phase="applying";try saveRecord(record)
        } else if existing == nil,let current=current {
            var expected=record.beforeTask ?? ManagedTask(id:targetID,title:c.text("title") ?? "",notes:"",group:.inbox,status:"todo",progress:nil,dueAt:nil,completed:false,softDeleted:false,archived:false,conflicted:false)
            if let title=c.text("title") { expected.title=title.trimmingCharacters(in:.whitespacesAndNewlines) }
            if let notes=c.text("notes") {expected.notes=notes}
            if record.clearDue==true {expected.dueAt=nil}
            if let group=c.text("groupId").flatMap(TaskGroup.init(rawValue:)) { expected.group=group }
            if let due=record.dueAt { expected.dueAt=due }
            if c.intent=="complete_task" || c.text("status")=="done" { expected.completed=true }
            if c.intent=="reopen_task" || c.text("status").map({$0 != "done"})==true { expected.completed=false }
            guard current.nativeFingerprint==record.beforeTask?.nativeFingerprint || current.nativeFingerprint==expected.nativeFingerprint else {
                throw AppFailure.message("恢复时发现任务被其他客户端修改，已暂停，请核对任务。")
            }
        }
        var patch:[String:FieldValue]=[:]
        if c.intent=="create_task" { patch=["status":.text("todo"),"progress":.null,"softDeleted":.flag(false),"archived":.flag(false)] }
        for field in ["status","progress"] { if let value=c.patch[field] { patch[field]=value } }
        if c.intent=="complete_task" { patch["status"] = .text("done") }
        if c.intent=="reopen_task" { patch["status"] = .text("todo") }
        if c.intent=="delete_task" { patch["softDeleted"] = .flag(true) }
        if c.intent=="restore_task" { patch["softDeleted"] = .flag(false) }
        if let group=c.text("groupId").flatMap(TaskGroup.init(rawValue:)) { patch["groupId"] = .text(group.uuid) }
        if patch.isEmpty { patch["groupId"] = .text((record.beforeTask?.group ?? .inbox).uuid) }
        let op=MetadataOperation(schemaVersion:1,operationId:record.id,entityType:"task",entityId:targetID,actorId:actorID,
            parents:record.metadataParents,createdAt:record.createdAt,source:record.source.hasPrefix("wechat:") ? "wechat" : "manual",
            summary:String(record.text.prefix(512)),patch:patch)
        if let existing=existing,existing != op { throw AppFailure.message("相同操作ID的内容不一致，已暂停恢复。") }
        if existing == nil {
            try await reminders.apply(record)
            _=try journal.append(op)
        }
        try await reload()
        guard tasks.contains(where:{$0.id==targetID}) else { throw AppFailure.message("保存后未读到任务，暂不确认成功。") }
        record.phase="applied"
        let saved=tasks.first{$0.id==targetID}!
        let n=taskNumbers.values[targetID].map(String.init) ?? "?"
        record.reply="已处理任务\(n)\n\n\(saved.title)\n\(saved.softDeleted ? "已移入回收站，系统提醒已同步移除" : saved.statusLabel) · \(saved.group.title)"
        try saveRecord(record);message=record.reply!;errorMessage=nil
        highlight(targetID)
        if c.intent=="restore_task" {try? TaskTrashStore(directory:AppPaths.trash).remove(targetID)}
    }
    func confirmPending() async {
        guard await waitUntilIdle(),var r=pending else { return }
        if r.command?.dateText != nil,r.dueAt==nil,!pendingDateChecked {errorMessage="日期尚不明确，请先选择具体截止时间。";return}
        busy=true;errorMessage=nil;defer{busy=false}
        do {
            if r.command?.dateText != nil {
                guard r.dueAt != nil || pendingDateChecked else{throw AppFailure.message("日期尚不明确，请先选择具体截止时间。")}
                r.dueAt=pendingDate
            }
            try await apply(&r,recovery:false);pending=nil
        } catch { errorMessage=error.localizedDescription;r.reply=error.localizedDescription;r.phase=r.phase=="applying" ? "uncertain" : "failed";try? saveRecord(r);pending=nil }
    }
    func cancelPending() {
        guard var r=pending else{return};r.phase="cancelled";r.reply="已取消，未修改任务。";try? saveRecord(r);pending=nil;message=r.reply!
    }
    private func handleConfirmationText(_ text:String,source:String,id:String) async -> ServiceResult {
        guard await waitUntilIdle() else { return ServiceResult(ok:false,status:"busy",message:"正在处理，请稍后重试。",requestId:id) }
        guard let confirmation=ConversationRules.confirmation(text) else{return ServiceResult(ok:false,status:"rejected",message:"请回复“确认1”或“取消1”。",requestId:id)}
        do {
            if let receipt=try loadRecord(id),["applied","cancelled"].contains(receipt.phase) {
                guard receipt.source==source,receipt.text==text else{throw AppFailure.message("请求ID内容不一致。")}
                return ServiceResult(ok:true,status:receipt.phase,message:receipt.reply ?? "已处理。",requestId:id)
            }
            func receipt(_ phase:String,_ reply:String)throws->ServiceResult {
                var r=RequestRecord(id:id,source:source,text:text,createdAt:ISO8601DateFormatter().string(from:Date()))
                r.phase=phase;r.reply=reply;try saveRecord(r)
                return ServiceResult(ok:true,status:phase,message:reply,requestId:id)
            }
            let records=try FileManager.default.contentsOfDirectory(at:AppPaths.requests,includingPropertiesForKeys:nil)
                .filter{$0.pathExtension=="json"}.map{try JSONDecoder().decode(RequestRecord.self,from:Data(contentsOf:$0))}
            let matches=records.filter{ConversationRules.matchesConfirmation($0,source:source,code:confirmation.code)}
            guard matches.count==1 else { throw AppFailure.message("没有找到对应的待确认操作，或它已处理。") }
            pending=matches[0]
            if confirmation.cancel { cancelPending();return try receipt("cancelled",message) }
            if let date=pending!.command?.dateText,pending!.dueAt==nil {
                return ServiceResult(ok:false,status:"awaiting_confirmation",message:"“\(date)”需要核对具体日期，请在菜单栏选择日期后确认。",requestId:id)
            }
            pendingDate=pending!.dueAt ?? Date();pendingDateChecked=pending!.dueAt != nil;await confirmPending()
            if errorMessage==nil {return try receipt("applied",message)}
            return ServiceResult(ok:false,status:"failed",message:errorMessage ?? message,requestId:id)
        } catch { return ServiceResult(ok:false,status:"rejected",message:error.localizedDescription,requestId:id) }
    }
    private func recover() async throws {
        let files=try FileManager.default.contentsOfDirectory(at:AppPaths.requests,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
        for file in files.sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
            var record=try JSONDecoder().decode(RequestRecord.self,from:Data(contentsOf:file))
            if ["applying","uncertain"].contains(record.phase) {
                do { try await apply(&record,recovery:true) }
                catch { errorMessage="有一项操作待核对："+error.localizedDescription }
            } else if record.phase=="awaiting_confirmation" {
                if record.confirmationNumber==nil {
                    record.confirmationNumber=try nextConfirmationNumber(source:record.source)
                    record.reply=confirmationMessage(record);try saveRecord(record)
                }
                pending=record;pendingDate=record.dueAt ?? Date();pendingDateChecked=record.dueAt != nil
            }
        }
    }
    private func recentActivity() throws -> [[String:String]] {
        let records=try FileManager.default.contentsOfDirectory(at:AppPaths.requests,includingPropertiesForKeys:nil)
            .filter{$0.pathExtension=="json"}.compactMap{try? JSONDecoder().decode(RequestRecord.self,from:Data(contentsOf:$0))}
            .filter{$0.phase=="applied" && $0.targetId != nil}.sorted{$0.createdAt<$1.createdAt}
        return records.suffix(6).map{["input":$0.text,"taskId":$0.targetId!,"intent":$0.command?.intent ?? ""]}
    }
    func number(for task:ManagedTask)->Int {taskNumbers.values[task.id] ?? 0}
    func localCommand(_ input:String,id:String,snapshot:[ManagedTask])throws->TaskCommand? {
        func command(_ intent:String,task:String?=nil,patch:[String:FieldValue]=[:],date:String?=nil,confirm:Bool=false)->TaskCommand {
            TaskCommand(operationId:id,intent:intent,taskId:task,patch:patch,dateText:date,requiresConfirmation:confirm)
        }
        if input.contains("清空回收站") || input.contains("彻底删除") {throw AppFailure.message("彻底删除不可恢复，请在菜单栏回收站选择任务或清空，并核对确认提示。")}
        if input.hasPrefix("手动新增任务：") || input.hasPrefix("手动新增任务:") {
            let title=String(input.dropFirst(7)).trimmingCharacters(in:.whitespacesAndNewlines)
            guard !title.isEmpty else{throw AppFailure.message("请提供任务标题。")}
            return command("create_task",patch:["title":.text(title),"groupId":.text("inbox")])
        }
        if let groupCommand=try GroupConversation.command(input,id:id,groups:groups) {return groupCommand}
        if ["查看分组","查询分组","有哪些分组","几个分组","列出分组"].contains(where:input.contains) {return command("query_groups")}
        let pattern=#"^(?:请)?(?:创建|新建|新增)(?:一个)?分组[：:\s]*(.+)$"#
        if let range=input.range(of:pattern,options:.regularExpression) {
            let text=String(input[range]);let regex=try NSRegularExpression(pattern:pattern)
            let m=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text))!
            let name=(text as NSString).substring(with:m.range(at:1)).trimmingCharacters(in:CharacterSet(charactersIn:" ‘“”’\"。"))
            guard let group=TaskGroup.named(name) else{throw AppFailure.message("请输入1到40字的分组名称，不含换行或斜杠。")}
            return command("create_group",patch:["groupId":.text(group.rawValue)])
        }
        if let number=ConversationRules.taskNumber(input) {
            let regex=try NSRegularExpression(pattern:#"(?:任务|待办)\s*#?\s*[0-9]+"#)
            guard regex.numberOfMatches(in:input,range:NSRange(input.startIndex...,in:input))==1 else{return command("clarify")}
            guard let task=taskNumbers.task(number,in:snapshot) else{throw AppFailure.message("没有找到任务\(number)，请先查询待办核对编号。")}
            if ["不要","不是","别","不想","不准"].contains(where:input.contains) {return command("clarify")}
            if let range=input.range(of:#"(?:移到|移动到|移入|放到|归到|分到)[：:\s]*(.+)$"#,options:.regularExpression) {
                let part=String(input[range]).replacingOccurrences(of:#"^(?:移到|移动到|移入|放到|归到|分到)[：:\s]*"#,with:"",options:.regularExpression)
                    .replacingOccurrences(of:#"分组$"#,with:"",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:" ‘“”’\"。"))
                guard let group=TaskGroup.named(part) else{throw AppFailure.message("分组名称无效。")}
                return command("move_task",task:task.id,patch:["groupId":.text(group.rawValue)])
            }
            if input.contains("待测试") || input.contains("待验收") {return command("update_task",task:task.id,patch:["status":.text("waiting")],date:DateSuggestion.explicitDateText(in:input))}
            if ["标记完成","已完成","完成了"].contains(where:input.contains),DateSuggestion.explicitDateText(in:input)==nil,!["明天","下周","之前","计划","准备"].contains(where:input.contains) {return command("complete_task",task:task.id)}
            if input.contains("删除") {return command("delete_task",task:task.id)}
            if let range=input.range(of:#"进度\s*(10|20|30|40|50|60|70|80|90|100)\s*%?$"#,options:.regularExpression) {
                let value=Int(input[range].filter(\.isNumber))!
                return command("update_task",task:task.id,patch:["progress":.number(value)])
            }
            if ["重新打开","撤销完成","恢复待办"].contains(where:input.contains) {return command("reopen_task",task:task.id)}

        }
        if ConversationRules.isQuery(input) {
            var patch:[String:FieldValue]=[:]
            let matches=groups.filter{input.contains($0.title)}
            if matches.count==1 {patch["groupId"] = .text(matches[0].rawValue)}
            if input.contains("进行中") {patch["status"] = .text("doing")}
            else if input.contains("等待") || input.contains("待测试") {patch["status"] = .text("waiting")}
            return command("query_tasks",patch:patch)
        }
        return nil
    }
    func beginEdit(_ task:ManagedTask) {
        guard !task.conflicted else{return}
        editingTask=task;editTitle=task.title;editNotes=task.notes;editGroup=task.group.rawValue
        editStatus=task.status;editHasProgress=task.progress != nil;editProgress=Double(max(10,min(100,Int((Double(task.progress ?? 10)/10).rounded())*10)))
        editHasDue=task.dueAt != nil;editDue=task.dueAt ?? Date();editorPresented=true
    }
    func saveEdit(markComplete:Bool=false) async {
        if editHasProgress && editProgress==100 && editStatus != "done" && !markComplete {progressCompletionPresented=true;return}
        if markComplete {editStatus="done"}
        guard let before=editingTask else{return}
        guard await waitUntilIdle() else{errorMessage=Self.busyNotice;return}
        busy=true;errorMessage=nil;processingStage="正在保存任务";defer{busy=false;processingStage=""}
        do {
            var r=RequestRecord(id:UUID().uuidString.lowercased(),source:"menu",text:"手动编辑任务",createdAt:ISO8601DateFormatter().string(from:Date()))
            let patch:[String:FieldValue]=["title":.text(editTitle.trimmingCharacters(in:.whitespacesAndNewlines)),"notes":.text(editNotes),"status":.text(editStatus),"groupId":.text(editGroup),"progress":editHasProgress ? .number(Int(editProgress)) : .null]
            let command=TaskCommand(operationId:r.id,intent:"update_task",taskId:before.id,patch:patch,dateText:nil,requiresConfirmation:false)
            r.command=try TaskCommand.decode(JSONEncoder().encode(command),expectedId:r.id,tasks:[before]);r.targetId=before.id;r.beforeTask=before;r.targetFingerprint=before.fingerprint
            r.dueAt=editHasDue ? editDue : nil;r.clearDue = !editHasDue
            try saveRecord(r);try await apply(&r,recovery:false);editorPresented=false;selectedTab="tasks"
        } catch {errorMessage=error.localizedDescription}
    }
    func createGroup() async {
        guard !busy,let group=TaskGroup.named(groupDraft) else{groupsNotice="请填写有效的分组名称。";return}
        busy=true;defer{busy=false}
        do {
            var r=RequestRecord(id:UUID().uuidString.lowercased(),source:"menu",text:"手动创建分组",createdAt:ISO8601DateFormatter().string(from:Date()))
            r.command=TaskCommand(operationId:r.id,intent:"create_group",taskId:nil,patch:["groupId":.text(group.rawValue)],dateText:nil,requiresConfirmation:false);r.targetId=group.uuid
            try saveRecord(r);try await apply(&r,recovery:false);groupDraft="";groupsNotice="已创建分组。"
        } catch {groupsNotice=error.localizedDescription}
    }
    func manualAdd() async {
        let title=inputText.trimmingCharacters(in:.whitespacesAndNewlines)
        guard isConnected,!title.isEmpty else{return}
        guard await waitUntilIdle() else{errorMessage=Self.busyNotice;return}
        busy=true;defer{busy=false}
        do {
            try await reload()
            var r=RequestRecord(id:UUID().uuidString.lowercased(),source:"menu",text:title,createdAt:ISO8601DateFormatter().string(from:Date()))
            let group=TaskGroup(rawValue:selectedGroup) ?? .inbox
            let candidate=TaskCommand(operationId:r.id,intent:"create_task",taskId:nil,patch:["title":.text(title),"groupId":.text(group.rawValue)],dateText:nil,requiresConfirmation:false)
            r.command=try TaskCommand.decode(JSONEncoder().encode(ConversationRules.cleanCreation(candidate,input:title,groups:groups)),expectedId:r.id,tasks:tasks)
            r.targetId=r.id;try saveRecord(r);try await apply(&r,recovery:false);inputText=""
        } catch {errorMessage=error.localizedDescription}
    }
    static let busyNotice="正在同步任务，请稍后再试。"
    /// Background sync holds busy for a moment every 12 s; a click waits it out instead of being dropped.
    func waitUntilIdle(seconds:Double=3) async->Bool {
        var waited=0.0
        while busy && waited<seconds {try? await Task.sleep(nanoseconds:100_000_000);waited+=0.1}
        return !busy
    }
    func restore(_ task:ManagedTask) async { await manualAction(task,intent:"restore_task",text:"恢复回收站任务") }
    func complete(_ task:ManagedTask) async {
        let completing = !task.completed
        await manualAction(task,intent:completing ? "complete_task" : "reopen_task",text:completing ? "手动标记完成" : "重新打开任务")
        if completing,errorMessage == nil {offerUndo(task)}
    }
    func manualAction(_ task:ManagedTask,intent:String,text:String) async {
        // Manual checkbox uses the same durable execution path without spending a model request.
        guard await waitUntilIdle() else{errorMessage=Self.busyNotice;return};busy=true;errorMessage=nil;defer{busy=false}
        var r=RequestRecord(id:UUID().uuidString.lowercased(),source:"menu",text:text,createdAt:ISO8601DateFormatter().string(from:Date()))
        r.command=TaskCommand(operationId:r.id,intent:intent,taskId:task.id,patch:[:],dateText:nil,requiresConfirmation:false)
        r.targetId=task.id;r.beforeTask=task;r.targetFingerprint=task.fingerprint
        do { try saveRecord(r);try await apply(&r,recovery:false) } catch {errorMessage=error.localizedDescription}
    }
}
