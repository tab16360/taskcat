import Foundation
import EventKit

struct StoredAlarm:Codable {
    var absoluteDate:Date?
    var relativeOffset:TimeInterval
    init(_ alarm:EKAlarm)throws {
        guard alarm.structuredLocation==nil,alarm.type == .display else{throw AppFailure.message("此任务含位置或特殊提醒，暂不能完整备份；请先在系统提醒事项中处理。")}
        absoluteDate=alarm.absoluteDate;relativeOffset=alarm.relativeOffset
    }
    func alarm()->EKAlarm {absoluteDate.map{EKAlarm(absoluteDate:$0)} ?? EKAlarm(relativeOffset:relativeOffset)}
}

struct TaskSnapshot:Codable {
    var task:ManagedTask
    var priority:Int
    var location:String?
    var start:DateComponents?
    var due:DateComponents?
    var completionDate:Date?
    var alarms:[StoredAlarm]
    init(task:ManagedTask,reminder:EKReminder)throws {
        guard reminder.recurrenceRules?.isEmpty != false else{throw AppFailure.message("此任务含重复规则，暂不能保证完整恢复；请先在系统提醒事项中处理。")}
        self.task=task;priority=reminder.priority;location=reminder.location
        start=reminder.startDateComponents;due=reminder.dueDateComponents;completionDate=reminder.completionDate
        alarms=try (reminder.alarms ?? []).map(StoredAlarm.init)
    }
    func fill(_ reminder:EKReminder) {
        reminder.title=task.title;reminder.notes=task.notes;reminder.priority=priority;reminder.location=location
        reminder.startDateComponents=start;reminder.dueDateComponents=due;reminder.isCompleted=task.completed
        reminder.completionDate=completionDate;reminder.alarms=alarms.map{$0.alarm()}
    }
}

struct TrashEntry:Codable {
    var schemaVersion=1
    var operationID:String
    var snapshot:TaskSnapshot
    var capturedAt=Date()
}

struct TaskTrashStore {
    let directory:URL
    init(directory:URL)throws {
        self.directory=directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    private func file(_ id:String)throws->URL {
        guard MetadataOperation.isID(id) else{throw AppFailure.message("回收站任务编号无效。")}
        return directory.appendingPathComponent(id+".json")
    }
    func load(_ id:String)throws->TrashEntry? {
        let url=try file(id);guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        let entry=try JSONDecoder().decode(TrashEntry.self,from:Data(contentsOf:url))
        guard entry.schemaVersion==1,entry.snapshot.task.id==id,MetadataOperation.isID(entry.operationID) else{throw AppFailure.message("回收快照损坏，请从备份恢复。")}
        return entry
    }
    func all()throws->[TrashEntry] {
        try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil,options:.skipsHiddenFiles).filter{$0.pathExtension=="json"}.compactMap{try load($0.deletingPathExtension().lastPathComponent)}
    }
    func save(_ entry:TrashEntry)throws {
        guard entry.schemaVersion==1,MetadataOperation.isID(entry.operationID) else{throw AppFailure.message("回收快照无效。")}
        try AppPaths.write(entry,to:file(entry.snapshot.task.id))
    }
    func remove(_ id:String)throws {let url=try file(id);if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}}
}
