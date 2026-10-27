import Foundation
import CryptoKit

struct TaskBackup:Codable {
    var schemaVersion=1
    var createdAt=Date()
    var snapshots:[TaskSnapshot]
    var trash:[TrashEntry]
    var operations:[MetadataOperation]
    var numbers:TaskNumbers
    func validate()throws {
        guard schemaVersion==1,snapshots.count+trash.count<=100_000,operations.count<=500_000 else{throw AppFailure.message("备份版本或大小不受支持。")}
        let all=snapshots+trash.map(\.snapshot)
        guard Set(all.map{$0.task.id}).count==all.count else{throw AppFailure.message("备份含重复任务编号。")}
        for s in all {
            guard MetadataOperation.isID(s.task.id),!s.task.title.isEmpty,s.task.title.count<=5000,s.task.notes.count<=1_000_000,
                  ["todo","doing","waiting","done","cancelled"].contains(s.task.status),s.task.progress.map({(0...100).contains($0)}) ?? true,
                  TaskGroup.named(s.task.group.rawValue) != nil,s.alarms.count<=100 else{throw AppFailure.message("备份任务字段无效。")}
        }
        guard snapshots.allSatisfy({!$0.task.softDeleted}),trash.allSatisfy({$0.schemaVersion==1 && MetadataOperation.isID($0.operationID)}) else{throw AppFailure.message("备份回收状态无效。")}
        for op in operations {_=try MetadataOperation.decode(op.canonicalData())}
        guard Set(operations.map(\.operationId)).count==operations.count,numbers.values.keys.allSatisfy(MetadataOperation.isID),Set(numbers.values.values).count==numbers.values.count,numbers.values.values.allSatisfy({$0>0}) else{throw AppFailure.message("备份日志或任务编号无效。")}
    }
    func mergedProjection(existing:[String:MetadataOperation])throws->JournalProjection {
        try validate()
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("taskcat-backup-check-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let journal=try OperationJournal(directory:directory)
        for op in existing.values {_=try journal.append(op)}
        for op in operations {_=try journal.append(op)}
        let result=try journal.project()
        guard result.causallyCompleteAndConflictFree else{throw AppFailure.message("备份与本机日志存在冲突或缺少前序，未开始恢复。")}
        let entities=Dictionary(uniqueKeysWithValues:result.entities.filter{$0.entityType=="task"}.map{($0.entityId,$0)})
        for s in snapshots+trash.map(\.snapshot) {guard entities[s.task.id] != nil else{throw AppFailure.message("备份缺少任务扩展数据。")}}
        return result
    }
    func encoded()throws->Data {
        try validate();let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let payload=try encoder.encode(self)
        return try encoder.encode(BackupEnvelope(payload:payload,sha256:Self.digest(payload)))
    }
    static func decode(_ data:Data)throws->TaskBackup {
        guard data.count<=80_000_000 else{throw AppFailure.message("备份超过80MB限制。")}
        let envelope=try JSONDecoder().decode(BackupEnvelope.self,from:data)
        guard envelope.payload.count<=50_000_000,envelope.sha256==digest(envelope.payload) else{throw AppFailure.message("备份校验失败，文件可能损坏。")}
        let backup=try JSONDecoder().decode(TaskBackup.self,from:envelope.payload);try backup.validate();return backup
    }
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}
private struct BackupEnvelope:Codable {let payload:Data;let sha256:String}
