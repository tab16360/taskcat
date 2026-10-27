import Foundation

struct MetadataSyncSettings:Codable {
    let workspace:String
    var bootstrapped=false
}
extension TaskService {
    static var sharedMetadataDirectory:URL {FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/TaskCat/MetadataSync-v1")}
    private var syncSettingsURL:URL {AppPaths.root.appendingPathComponent("metadata-sync.json")}
    func startMetadataTimer() {
        metadataTimer?.invalidate()
        metadataTimer=Timer.scheduledTimer(withTimeInterval:12,repeats:true){[weak self] _ in
            Task { @MainActor in guard let self,self.metadataSyncEnabled,!self.busy else{return};await self.refresh() }
        }
    }
    func configureMetadataSync(create:Bool) async {
        guard !busy,isConnected,!restorePending,pending==nil else{syncNote="请先连接任务并完成待确认操作。";return}
        guard sourceChoices.contains(where:{$0.id==preferences.sourceIdentifier && $0.title.localizedCaseInsensitiveContains("iCloud")}) else{syncNote="双机扩展同步仅支持 iCloud 提醒事项账户。";return}
        busy=true;defer{busy=false}
        do {
            let store=SharedMetadataStore(directory:Self.sharedMetadataDirectory)
            if create {try store.initialize(actor:actorID,numbers:taskNumbers.values)}
            let workspace=try store.workspace()
            let local=try journal.load()
            guard workspace.owner==actorID || local.values.filter({$0.operationId==$0.entityId}).allSatisfy({workspace.numbers[$0.entityId] != nil}) else{throw AppFailure.message("此机含另一批独立创建的任务，请先导出备份并合并后再加入，避免改错编号。")}
            let safety=AppPaths.root.appendingPathComponent("before-sync-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:safety,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for folder in [AppPaths.operations,AppPaths.trash,AppPaths.requests] {try FileManager.default.copyItem(at:folder,to:safety.appendingPathComponent(folder.lastPathComponent))}
            try AppPaths.write(taskNumbers,to:safety.appendingPathComponent("task-numbers.json"))
            try store.register(actor:actorID)
            try AppPaths.write(MetadataSyncSettings(workspace:workspace.id),to:syncSettingsURL)
            metadataSyncEnabled=true
            try await reload()
        } catch {syncNote="设置未完成："+error.localizedDescription}
    }
    func syncMetadata() async {
        guard metadataSyncEnabled else{return}
        var config:MetadataSyncSettings
        do {config=try JSONDecoder().decode(MetadataSyncSettings.self,from:Data(contentsOf:syncSettingsURL))}
        catch {metadataSyncProblem="扩展同步配置损坏，请从备份恢复。";syncNote=metadataSyncProblem!;return}
        do {
            let store=SharedMetadataStore(directory:Self.sharedMetadataDirectory)
            let workspace=try store.workspace()
            guard workspace.id==config.workspace else{throw MetadataSyncError.invalid("同步空间已改变，请先备份并重新加入。")}
            let local=try journal.load()
            let exportedNumbers=config.bootstrapped ? taskNumbers.values.filter{workspace.numbers[$0.key] != nil || local[$0.key] != nil} : workspace.numbers
            let entries=try TaskTrashStore(directory:AppPaths.trash).all()
            let actor=actorID
            let merge=try await Task.detached {try store.exchange(actor:actor,operations:local,numbers:exportedNumbers,trash:entries)}.value
            // Skip exact duplicates only; a same-ID mismatch must still reach append and fail loudly.
            for op in merge.operations.values where local[op.operationId] != op {_=try journal.append(op)}
            let projection=try journal.project()
            let states=Dictionary(uniqueKeysWithValues:projection.entities.filter{$0.entityType=="task"}.map{($0.entityId,$0)})
            let trash=try TaskTrashStore(directory:AppPaths.trash)
            for entry in SharedMetadataStore.latestTrash(merge.trash,operations:merge.operations) where states[entry.snapshot.task.id]?.values["archived"] != .flag(true) {
                try trash.save(entry)
            }
            // The first join intentionally adopts the primary map; a local safety copy was saved first.
            taskNumbers=TaskNumbers(values:merge.numbers,lane:merge.lane)
            try AppPaths.write(taskNumbers,to:AppPaths.root.appendingPathComponent("task-numbers.json"))
            config.bootstrapped=true;try AppPaths.write(config,to:syncSettingsURL)
            metadataSyncProblem=nil
            syncNote="iCloud 扩展同步已就绪 · 本机编号段 \(merge.lane*1000+1)–\(merge.lane*1000+999) · 每12秒检查。"
            if !projection.causallyCompleteAndConflictFree {syncNote="扩展数据已接收，但存在并发修改冲突；相关任务仍需核对。"}
        } catch MetadataSyncError.waiting {
            syncNote=MetadataSyncError.waiting.localizedDescription
            if !config.bootstrapped {metadataSyncProblem="首次扩展数据尚未下载完整，请稍候再修改。"}
        } catch {
            metadataSyncProblem="扩展同步异常，已暂停修改："+error.localizedDescription;syncNote=metadataSyncProblem!
        }
    }
}
