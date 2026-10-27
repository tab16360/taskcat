// Internal setup/inspection helper; uses the exact App sync implementation, prints counts only.
import Foundation
private struct SyncConfig:Codable {let workspace:String;var bootstrapped:Bool}
@main struct MetadataSyncTool {
    static func main() {
        do {try run()}catch {fputs("Setup incomplete: \(error.localizedDescription)\n",stderr);exit(2)}
    }
    static func run() throws {
        let mode=CommandLine.arguments[1]
        let root=AppPaths.root
        let shared=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/TaskCat/MetadataSync-v1")
        let store=SharedMetadataStore(directory:shared),journal=try OperationJournal(directory:AppPaths.operations)
        let actor=try JSONDecoder().decode(String.self,from:Data(contentsOf:root.appendingPathComponent("actor.json")))
        let old=try JSONDecoder().decode(TaskNumbers.self,from:Data(contentsOf:root.appendingPathComponent("task-numbers.json")))
        if mode=="initialize" {try store.initialize(actor:actor,numbers:old.values)}
        let workspace=try store.workspace()
        if mode=="initialize" || mode=="join" {
            let local=try journal.load()
            guard workspace.owner==actor || local.values.filter({$0.operationId==$0.entityId}).allSatisfy({workspace.numbers[$0.entityId] != nil}) else{throw AppFailure.message("此机独立任务尚未合并，不可直接加入。")}
            let safety=root.appendingPathComponent("before-sync-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:safety,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            for dir in [AppPaths.operations,AppPaths.requests,AppPaths.trash] {try FileManager.default.copyItem(at:dir,to:safety.appendingPathComponent(dir.lastPathComponent))}
            try AppPaths.write(old,to:safety.appendingPathComponent("task-numbers.json"))
            try store.register(actor:actor)
            try AppPaths.write(SyncConfig(workspace:workspace.id,bootstrapped:false),to:root.appendingPathComponent("metadata-sync.json"))
        }
        let config=try JSONDecoder().decode(SyncConfig.self,from:Data(contentsOf:root.appendingPathComponent("metadata-sync.json")))
        guard config.workspace==workspace.id else{throw AppFailure.message("同步空间不匹配。")}
        let merge=try store.exchange(actor:actor,operations:journal.load(),numbers:config.bootstrapped ? old.values : workspace.numbers,trash:TaskTrashStore(directory:AppPaths.trash).all())
        for op in merge.operations.values {_=try journal.append(op)}
        let projection=try journal.project()
        let states=Dictionary(uniqueKeysWithValues:projection.entities.map{($0.entityId,$0)})
        let trash=try TaskTrashStore(directory:AppPaths.trash)
        for entry in SharedMetadataStore.latestTrash(merge.trash,operations:merge.operations) where states[entry.snapshot.task.id]?.values["archived"] != .flag(true) {try trash.save(entry)}
        try AppPaths.write(TaskNumbers(values:merge.numbers,lane:merge.lane),to:root.appendingPathComponent("task-numbers.json"))
        try AppPaths.write(SyncConfig(workspace:workspace.id,bootstrapped:true),to:root.appendingPathComponent("metadata-sync.json"))
        print("operations=\(merge.operations.count) numbers=\(merge.numbers.count) lane=\(merge.lane) conflictFree=\(projection.causallyCompleteAndConflictFree)")
    }
}
