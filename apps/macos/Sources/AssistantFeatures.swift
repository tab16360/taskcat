import Foundation

struct UndoNotice:Identifiable,Equatable {
    let id=UUID()
    let taskID:String
    let title:String
}

extension TaskService {
    // MARK: Feedback on what just changed

    func highlight(_ taskID:String) {
        highlightedTaskID=taskID
        DispatchQueue.main.asyncAfter(deadline:.now()+2.2){[weak self] in if self?.highlightedTaskID == taskID {self?.highlightedTaskID=nil}}
    }
    func offerUndo(_ task:ManagedTask) {
        let notice=UndoNotice(taskID:task.id,title:task.title);undoNotice=notice
        DispatchQueue.main.asyncAfter(deadline:.now()+6){[weak self] in if self?.undoNotice == notice {self?.undoNotice=nil}}
    }
    func undoCompletion() async {
        guard let notice=undoNotice,let task=tasks.first(where:{$0.id == notice.taskID}),task.completed else{undoNotice=nil;return}
        undoNotice=nil
        await manualAction(task,intent:"reopen_task",text:"撤销完成")
    }

    // MARK: Row shortcuts (same validated, durable path as the editor)

    func quickUpdate(_ task:ManagedTask,intent:String="update_task",patch:[String:FieldValue]=[:],dueAt:Date?=nil,text:String) async {
        guard await waitUntilIdle() else{errorMessage=Self.busyNotice;return}
        busy=true;errorMessage=nil;defer{busy=false}
        var r=RequestRecord(id:UUID().uuidString.lowercased(),source:"menu",text:text,createdAt:ISO8601DateFormatter().string(from:Date()))
        do {
            let command=TaskCommand(operationId:r.id,intent:intent,taskId:task.id,patch:patch,dateText:nil,requiresConfirmation:false)
            r.command=try TaskCommand.decode(JSONEncoder().encode(command),expectedId:r.id,tasks:[task])
            r.targetId=task.id;r.beforeTask=task;r.targetFingerprint=task.fingerprint;r.dueAt=dueAt
            try saveRecord(r);try await apply(&r,recovery:false)
        } catch {errorMessage=error.localizedDescription}
    }
    func postpone(_ task:ManagedTask,toNextMonday:Bool=false) async {
        let date=TaskBoard.postponed(task.dueAt,nextWeekday:toNextMonday ? 2 : nil)
        await quickUpdate(task,dueAt:date,text:toNextMonday ? "推迟到下周一" : "推迟到明天")
    }
    func setStatus(_ task:ManagedTask,_ status:String) async {
        await quickUpdate(task,patch:["status":.text(status)],text:"标记为"+(["todo":"待办","doing":"进行中","waiting":"等待"][status] ?? status))
    }
    func move(_ task:ManagedTask,to group:TaskGroup) async {
        await quickUpdate(task,intent:"move_task",patch:["groupId":.text(group.rawValue)],text:"移到分组 "+group.title)
    }

    // MARK: Daily briefing

    /// Called whenever a surface opens; runs once per calendar day.
    func briefIfNeeded() {
        guard dailyBriefingEnabled,isConnected,!briefingInProgress,
              UserDefaults.standard.string(forKey:"TaskSecretary.briefing.day") != DailyBriefing.dayKey(Date()) else{return}
        Task {await runBriefing()}
    }
    func runBriefing() async {
        guard isConnected,!briefingInProgress else{return}
        briefingInProgress=true;defer{briefingInProgress=false}
        let now=Date(),items=DailyBriefing.items(tasks,now:now)
        var text=DailyBriefing.fallback(items,now:now),origin="briefing-local"
        if !items.isEmpty,!preferences.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let clock=DateFormatter();clock.locale=Locale(identifier:"zh_CN");clock.dateFormat="yyyy-MM-dd EEEE HH:mm"
            let payload:[String:Any]=["localTime":clock.string(from:now),"greeting":DailyBriefing.greeting(now),"tasks":items.map{
                ["title":$0.title,"group":$0.group,"due":$0.due ?? "未定","bucket":$0.bucket.title,"status":$0.status,"progress":$0.progress.map{"\($0)%"} ?? ""]}]
            let system="你是记事喵，用户的待办管家。根据给出的任务清单写今日提醒：先一句问候（使用给定的 greeting），再点出最需要关注的一到三件事（优先已逾期、今天到期、进行中），最后可给一条简短可执行的建议。只提清单里的任务，不编造任务或时间；使用简体中文，不用 Markdown、编号或表情，不超过 120 字。"
            if let data=try? JSONSerialization.data(withJSONObject:payload),let user=String(data:data,encoding:.utf8),
               let reply=try? await model.chat(system:system,user:user,preferences:preferences) {text=reply;origin="briefing"}
        }
        let item=FeedbackItem(input:"今日待办提醒",output:text,isError:false,origin:origin)
        feedback.insert(item,at:0);latestReply=item
        UserDefaults.standard.set(DailyBriefing.dayKey(now),forKey:"TaskSecretary.briefing.day")
    }

    // MARK: Settings helpers

    func openSettings(_ tab:String) {settingsTab=tab;settingsPresented=true}
    var savedKeyHint:String? {
        guard let key=try? SecretStore.read(service:preferences.keyService),!key.isEmpty else{return nil}
        return "已保存 ••••"+String(key.suffix(4))
    }
    func testModel() async {
        modelTestNotice="正在测试…"
        do {
            _=try await model.chat(system:"只回复：好",user:"连接测试",preferences:preferences,key:keyDraft,maxTokens:8)
            modelTestNotice="连接成功 · \(preferences.model)"
        } catch {modelTestNotice="连接失败："+error.localizedDescription}
    }
}
