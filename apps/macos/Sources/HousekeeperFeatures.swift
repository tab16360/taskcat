import Foundation
import Combine
import CryptoKit
import ServiceManagement

enum DestructiveAction {
    case deleteTask(ManagedTask),purgeTask(ManagedTask),emptyTrash([ManagedTask]),deleteGroup(TaskGroup)
    var title:String {
        switch self {case .deleteTask:return "移入回收站？";case .purgeTask:return "彻底删除任务？";case .emptyTrash:return "清空回收站？";case .deleteGroup:return "删除分组？"}
    }
    var detail:String {
        switch self {
        case .deleteTask(let t):return "「\(t.title)」将移入回收站，可以恢复。"
        case .purgeTask(let t):return "「\(t.title)」将从系统提醒事项永久删除，无法恢复。"
        case .emptyTrash(let tasks):return "永久删除当前回收站全部 \(tasks.count) 项任务，无法恢复。"
        case .deleteGroup(let g):return "删除「\(g.title)」分组；其中所有任务保留并移至收件箱。"
        }
    }
}


extension TaskService {
    func loadExperiencePreferences() {
        if let d=try? Data(contentsOf:AppPaths.root.appendingPathComponent("bark-preferences.json")),let p=try? JSONDecoder().decode(BarkPreferences.self,from:d){barkPreferences=p}
        barkNotice=barkPreferences.enabled ? "到期推送已启用 · 运行时每30秒检查" : "尚未启用到期推送"
        loginEnabled=SMAppService.mainApp.status == .enabled
        profileNameDraft=preferences.activeName
    }
    func saveExperiencePreferences()throws {
        _=try barkPreferences.endpoint()
        if barkPreferences.enabled && barkPreferences.enabledAt==nil {barkPreferences.enabledAt=Date()}
        if !barkPreferences.enabled {barkPreferences.enabledAt=nil}
        if !barkKeyDraft.isEmpty {try SecretStore.save(barkKeyDraft,service:barkPreferences.keyService);barkKeyDraft=""}
        try AppPaths.write(barkPreferences,to:AppPaths.root.appendingPathComponent("bark-preferences.json"))
    }
    func saveProfile()throws {
        _=try preferences.endpoint()
        let name=profileNameDraft.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=60,!preferences.model.isEmpty else{throw AppFailure.message("请填写配置名称和模型 ID。")}
        let id=preferences.selectedProfileID ?? UUID().uuidString.lowercased()
        let old=preferences.profiles?.first(where:{$0.id==id})
        // A changed origin must never inherit the previous server's credential.
        var previous=preferences
        if let old {if old.provider=="cloud" {previous.cloudURL=old.baseURL}else{previous.localURL=old.baseURL};previous.provider=old.provider}
        if old==nil || previous.origin != preferences.origin || old?.provider != preferences.provider {
            var isolated=preferences;isolated.credentialService=nil
            preferences.credentialService="TaskSecretary.Profile."+id+"."+isolated.keyService
        }
        let profile=ModelProfile(id:id,name:name,provider:preferences.provider,baseURL:preferences.baseURL,model:preferences.model,credentialService:preferences.keyService)
        var profiles=preferences.profiles ?? []
        if let index=profiles.firstIndex(where:{$0.id==id}) {profiles[index]=profile}else{profiles.append(profile)}
        if !keyDraft.isEmpty {try SecretStore.save(keyDraft,service:profile.credentialService);keyDraft=""}
        preferences.profiles=profiles;preferences.selectedProfileID=id;preferences.credentialService=profile.credentialService
        try savePreferences();settingsNotice="已保存模型配置。"
    }
    @discardableResult func selectModel(_ id:String)->Bool {
        guard !busy else{return false}
        let prior=preferences
        preferences.activateProfile(id);profileNameDraft=preferences.activeName;keyDraft=""
        do {_=try preferences.endpoint();try AppPaths.write(preferences,to:AppPaths.preferences);return true}catch{preferences=prior;profileNameDraft=prior.activeName;settingsNotice=error.localizedDescription;return false}
    }
    func addProfile() {
        guard !busy else{return}
        let id=UUID().uuidString.lowercased();let service="TaskSecretary.Profile."+id
        let p=ModelProfile(id:id,name:"新模型",provider:"cloud",baseURL:"https://api.example.com/v1",model:"",credentialService:service)
        preferences.profiles=(preferences.profiles ?? [])+[p];preferences.activateProfile(id);profileNameDraft="";keyDraft=""
    }
    func removeProfile() {
        guard !busy,let id=preferences.selectedProfileID,(preferences.profiles?.count ?? 0)>1 else{return}
        preferences.profiles?.removeAll{$0.id==id}
        if let first=preferences.profiles?.first {preferences.activateProfile(first.id);profileNameDraft=first.name}
        keyDraft="";try? savePreferences()
    }
    func modelControl(_ input:String,id:String,source:String)->ServiceResult? {
        guard let control=ModelConversation.request(input) else{return nil}
        do {
            if let old=try loadRecord(id) {
                guard old.text==input,old.source==source else{throw AppFailure.message("请求内容不一致。")}
                return ServiceResult(ok:old.phase=="applied",status:old.phase,message:old.reply ?? "已处理。",requestId:id)
            }
            let profiles=preferences.profiles ?? [];var reply=""
            if control == .help {reply="我可以帮你管理待办：新增、查询、编辑、完成、调整日期和进度、移动分组、移入回收站；也支持分组创建/改名/删除及多模型切换。\n\n可说：明天提醒我提交材料；任务5标记完成；wenshu分组改名mircrosung；模型列表。\n\nBark 到期推送与开机自启动在控制中心设置，彻底删除需要在回收站中确认。"}
            else if control == .query {reply="当前模型：\(preferences.activeName)\n模型 ID：\(preferences.model)\n\n可用配置\n\n"+profiles.enumerated().map{"\($0.offset+1)、\($0.element.name) · \($0.element.model)\($0.element.id==preferences.selectedProfileID ? "（当前）" : "")"}.joined(separator:"\n")+"\n\n可回复：切换模型2，或切换模型 本地 Ollama。"}
            else {
                guard case .select(let name)=control else{throw AppFailure.message("请说明要切换的模型。")}
                let target=try ModelConversation.resolve(name,profiles:profiles)
                guard selectModel(target.id) else{throw AppFailure.message(settingsNotice.isEmpty ? "模型切换未保存，请重试。" : settingsNotice)}
                reply="已切换模型：\(preferences.activeName)\n模型 ID：\(preferences.model)"

            }
            var r=RequestRecord(id:id,source:source,text:input,createdAt:ISO8601DateFormatter().string(from:Date()));r.phase="applied";r.reply=reply;try saveRecord(r)
            return ServiceResult(ok:true,status:"applied",message:reply,requestId:id)
        } catch{return ServiceResult(ok:false,status:"rejected",message:error.localizedDescription,requestId:id)}
    }
    func setLogin(_ enabled:Bool) {
        do {if enabled {try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
            loginEnabled=SMAppService.mainApp.status == .enabled
            loginNotice=SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许待办管家。" : loginEnabled ? "已启用登录时启动。" : "已关闭开机自启动。"
        } catch{loginEnabled=SMAppService.mainApp.status == .enabled;loginNotice="设置失败："+error.localizedDescription}
    }
    func runDestructiveAction(_ action:DestructiveAction) async {
        destructiveAction=nil
        switch action {
        case .deleteTask(let t):await manualAction(t,intent:"delete_task",text:"手动移入回收站")
        case .purgeTask(let t):await manualAction(t,intent:"purge_task",text:"手动彻底删除回收站任务")
        case .emptyTrash(let snapshot):
            for task in snapshot {await manualAction(task,intent:"purge_task",text:"手动清空回收站");if errorMessage != nil {break}}
        case .deleteGroup(let g):await manualGroup(g,intent:"delete_group")
        }
    }
    func renameGroup(_ group:TaskGroup) async {await manualGroup(group,intent:"rename_group",newName:groupRenameDraft)}
    func manualGroup(_ group:TaskGroup,intent:String,newName:String?=nil) async {
        guard !busy else{return};busy=true;groupsNotice="";defer{busy=false}
        do {
            try await reload()
            var patch:[String:FieldValue]=["groupId":.text(group.rawValue)]
            if let newName {guard let next=TaskGroup.named(newName),!groups.contains(next) else{throw AppFailure.message("新分组名无效或已存在。")};patch["newGroupId"] = .text(next.rawValue)}
            var r=RequestRecord(id:UUID().uuidString.lowercased(),source:"menu",text:"手动管理分组",createdAt:ISO8601DateFormatter().string(from:Date()))
            r.command=try TaskCommand.decode(JSONEncoder().encode(TaskCommand(operationId:r.id,intent:intent,taskId:nil,patch:patch,dateText:nil,requiresConfirmation:true)),expectedId:r.id,tasks:tasks)
            guard let calendar=reminders.calendars[group] else{throw AppFailure.message("分组已不存在。")}
            r.targetId=group.uuid;r.groupCalendarID=calendar.calendarIdentifier
            try saveRecord(r);try await apply(&r,recovery:false);groupsNotice=r.reply ?? "已处理";groupEditingID=""
        } catch{groupsNotice=error.localizedDescription}
    }
    func applyPermanentDeletion(_ record:inout RequestRecord,recovery:Bool) async throws {
        guard let before=record.beforeTask,before.softDeleted else{throw AppFailure.message("仅支持彻底删除回收站任务。")}
        try await reload();let current=tasks.first{$0.id==before.id}
        if let current {guard current.fingerprint==before.fingerprint,!current.conflicted else{throw AppFailure.message("任务已变化，请刷新回收站后重试。")}}
        else if !recovery {throw AppFailure.message("任务已不存在。")}
        let existing=try journal.load()[record.id]
        if !recovery {let projection=try journal.project();guard projection.causallyCompleteAndConflictFree else{throw AppFailure.message("扩展数据有冲突，已暂停删除。")};record.metadataParents=projection.heads}
        record.phase="applying";try saveRecord(record)
        if existing==nil {
            try await reminders.permanentlyDelete(record,recovery:recovery)
            let op=MetadataOperation(schemaVersion:1,operationId:record.id,entityType:"task",entityId:before.id,actorId:actorID,parents:record.metadataParents,createdAt:record.createdAt,source:"manual",summary:"彻底删除回收站任务",patch:["softDeleted":.flag(true),"archived":.flag(true)])
            _=try journal.append(op)
        }
        try await reload();guard !tasks.contains(where:{$0.id==before.id}) else{throw AppFailure.message("删除后仍读到任务，暂不确认成功。")}
        record.phase="applied";record.reply="已彻底删除回收站任务。";try saveRecord(record);message=record.reply!;errorMessage=nil
        try? TaskTrashStore(directory:AppPaths.trash).remove(before.id)
    }
}

extension TaskService {
    func startReminderScheduler() {
        guard reminderTimer==nil else{return}
        reminderTimer=Timer.scheduledTimer(withTimeInterval:30,repeats:true){[weak self] _ in
            Task { @MainActor in await self?.deliverDueReminders() }
        }
    }
    func deliverDueReminders() async {
        guard barkPreferences.enabled,isConnected,!busy,!barkSending,let enabledAt=barkPreferences.enabledAt else{return}
        barkSending=true;defer{barkSending=false}
        do {
            try await reload()
            let due=tasks.filter{BarkSchedule.isDue($0,enabledAt:enabledAt,now:Date())}
            for task in due {
                guard let date=task.dueAt else{continue}
                let file=AppPaths.root.appendingPathComponent("bark-\(task.id)-\(Int(date.timeIntervalSince1970)).json")
                guard !FileManager.default.fileExists(atPath:file.path) else{continue}
                // Claim on disk before the request. An unknown delivery result is not retried automatically.
                let result=try await barkPush(title:"待办到期 · \(task.group.title)",body:task.title,attemptFile:file)
                barkNotice=result
            }
        } catch{barkNotice="到期推送暂停："+error.localizedDescription}
    }
    func testBark() async {
        guard !barkSending else{return};barkSending=true;barkNotice="正在连接 Bark…";defer{barkSending=false}
        do {
            try saveExperiencePreferences()
            let file=AppPaths.root.appendingPathComponent("bark-test-\(UUID().uuidString).json")
            barkNotice=try await barkPush(title:"待办管家",body:"Bark 连接测试，请核对手机是否收到。",attemptFile:file)
        } catch{barkNotice=error.localizedDescription}
    }
    func barkPush(title:String,body:String,attemptFile:URL) async throws->String {
        let config=barkPreferences
        let key=try await Task.detached {()->String? in
            if let own=try SecretStore.read(service:config.keyService),!own.isEmpty{return own}
            guard config.baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/"))=="https://api.day.app" else{return nil}
            return try SecretStore.read(service:"TaskSecretary.PoC.Bark",account:"poc")
        }.value
        guard let key,!key.isEmpty else{throw AppFailure.message("尚未配置 Bark Device Key。已有 P0 Key 仅供 api.day.app 使用。")}
        var request=URLRequest(url:try config.endpoint());request.httpMethod="POST";request.timeoutInterval=15
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONSerialization.data(withJSONObject:["device_key":key,"title":title,"body":body,"group":"待办管家","level":"active"])
        try AppPaths.write(BarkAttempt(state:"sending",date:Date()),to:attemptFile)
        let session=URLSession(configuration:.ephemeral,delegate:model,delegateQueue:nil);defer{session.invalidateAndCancel()}
        do {
            let (data,response)=try await session.data(for:request)
            let accepted=(response as? HTTPURLResponse)?.statusCode==200 && ((try? JSONSerialization.jsonObject(with:data)) as? [String:Any])?["code"] as? Int==200
            try AppPaths.write(BarkAttempt(state:accepted ? "accepted" : "failed",date:Date()),to:attemptFile)
            return accepted ? "Bark API 已接受；请在手机核对实际送达。" : "Bark API 未确认接受，本次不自动重试。"
        } catch {try? AppPaths.write(BarkAttempt(state:"uncertain",date:Date()),to:attemptFile);throw AppFailure.message("推送结果不明，为避免重复，本次不自动重试。")}
    }
}

