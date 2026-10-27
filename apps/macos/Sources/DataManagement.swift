import Foundation
import AppKit
import EventKit
import UniformTypeIdentifiers
import Darwin

extension TaskService {
    private var pendingRestoreURL:URL {AppPaths.root.appendingPathComponent("pending-restore.taskcatbackup")}
    private func persistBackup(_ data:Data,to url:URL)throws {
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let handle=try FileHandle(forWritingTo:url);try handle.synchronize();try handle.close()
        let fd=Darwin.open(url.deletingLastPathComponent().path,O_RDONLY)
        guard fd>=0 else{throw AppFailure.message("备份目录无法同步。")};defer{Darwin.close(fd)}
        guard Darwin.fsync(fd)==0 else{throw AppFailure.message("备份目录同步失败。")}
    }
    func makeBackup()async throws->TaskBackup {
        try await reload();let rows=try await reminders.fetch(),store=try TaskTrashStore(directory:AppPaths.trash)
        var snapshots:[TaskSnapshot]=[],trash:[TrashEntry]=[]
        for task in tasks where !task.archived {
            if task.softDeleted {
                if let entry=try store.load(task.id) {trash.append(entry)}
                else if let native=rows.first(where:{RemindersStore.taskID($0)==task.id}) {
                    trash.append(TrashEntry(operationID:UUID().uuidString.lowercased(),snapshot:try TaskSnapshot(task:task,reminder:native)))
                } else {throw AppFailure.message("任务缺少可备份的系统实体与回收快照。")}
            } else if let native=rows.first(where:{RemindersStore.taskID($0)==task.id}) {snapshots.append(try TaskSnapshot(task:task,reminder:native))}
        }
        return TaskBackup(snapshots:snapshots,trash:trash,operations:Array(try journal.load().values).sorted{$0.operationId<$1.operationId},numbers:taskNumbers)
    }
    func exportBackup()async {
        guard isConnected,!busy,!restorePending else{dataNotice="请先连接提醒事项并完成已有恢复。";return}
        busy=true;defer{busy=false}
        do {
            let backup=try await makeBackup();_=try backup.mergedProjection(existing:[:]);let data=try backup.encoded()
            let panel=NSSavePanel();panel.title="导出记事喵备份";panel.nameFieldStringValue="TaskCat-"+ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")+".taskcatbackup"
            panel.allowedContentTypes=[UTType(filenameExtension:"taskcatbackup") ?? .data]
            panel.begin {response in
                guard response == .OK,let url=panel.url else{return}
                do {try self.persistBackup(data,to:url);self.dataNotice="备份已导出；含任务内容，请妥善保管。不含模型 Key 和微信会话。"}
                catch {self.dataNotice="备份失败："+error.localizedDescription}
            }
        } catch {dataNotice="备份失败："+error.localizedDescription}
    }
    func chooseBackup() {
        guard !busy,isConnected,!restorePending else{dataNotice="请先连接提醒事项并完成已有恢复。";return}
        let panel=NSOpenPanel();panel.title="选择记事喵备份";panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.allowedContentTypes=[UTType(filenameExtension:"taskcatbackup") ?? .data,.json]
        panel.begin {response in
            guard response == .OK,let url=panel.url else{return}
            do {
                let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size<=80_000_000 else{throw AppFailure.message("备份超过80MB限制。")}
                let backup=try TaskBackup.decode(Data(contentsOf:url));_=try backup.mergedProjection(existing:self.journal.load())
                self.proposedBackup=backup;self.backupRestorePresented=true
            } catch {self.dataNotice="备份无法恢复："+error.localizedDescription}
        }
    }
    func confirmBackupRestore()async {
        guard let backup=proposedBackup else{return};proposedBackup=nil
        await restoreBackup(backup)
    }
    func continueBackupRestore()async {
        do {let backup=try TaskBackup.decode(Data(contentsOf:pendingRestoreURL));await restoreBackup(backup)}
        catch {dataNotice="恢复文件无法读取："+error.localizedDescription}
    }
    func restoreBackup(_ backup:TaskBackup)async {
        guard !busy,isConnected else{return};busy=true;defer{busy=false}
        do {
            let merged=try backup.mergedProjection(existing:journal.load())
            let states=Dictionary(uniqueKeysWithValues:merged.entities.filter{$0.entityType=="task"}.map{($0.entityId,$0)})
            let rows=try await reminders.fetch()
            for row in rows {
                if let id=RemindersStore.taskID(row),(states[id]?.values["softDeleted"] == .flag(true) || states[id]?.values["archived"] == .flag(true)),tasks.first(where:{$0.id==id})?.softDeleted != true {
                    throw AppFailure.message("备份中的已删除任务在本机仍为活动任务，已停止以避免隐藏现有任务。")
                }
            }
            if !restorePending {
                let safety=AppPaths.root.appendingPathComponent("before-restore-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:safety,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                for dir in [AppPaths.operations,AppPaths.requests,AppPaths.trash] {try FileManager.default.copyItem(at:dir,to:safety.appendingPathComponent(dir.lastPathComponent))}
                try persistBackup(try await makeBackup().encoded(),to:safety.appendingPathComponent("native-state.taskcatbackup"))
            }
            try persistBackup(try backup.encoded(),to:pendingRestoreURL);restorePending=true
            for op in backup.operations {_=try journal.append(op)}
            let store=try TaskTrashStore(directory:AppPaths.trash)
            var created=0,preserved=0
            for snapshot in backup.snapshots+backup.trash.map(\.snapshot) {
                guard let state=states[snapshot.task.id],state.values["archived"] != .flag(true) else{continue}
                let deleted=state.values["softDeleted"] == .flag(true)
                if deleted {
                    if try store.load(snapshot.task.id)==nil {
                        let entry=backup.trash.first{$0.snapshot.task.id==snapshot.task.id} ?? TrashEntry(operationID:UUID().uuidString.lowercased(),snapshot:snapshot)
                        try store.save(entry)
                    }
                } else if rows.contains(where:{RemindersStore.taskID($0)==snapshot.task.id}) {preserved+=1}
                else {try await reminders.restoreSnapshot(snapshot);created+=1}
            }
            // Existing local numbering wins; never introduce a reused number on merge.
            for (id,n) in backup.numbers.values.sorted(by:{$0.value<$1.value}) where taskNumbers.values[id]==nil {
                if !taskNumbers.values.values.contains(n){taskNumbers.values[id]=n}
            }
            try await reload();try FileManager.default.removeItem(at:pendingRestoreURL);restorePending=false
            dataNotice="恢复完成：重建 \(created) 项，保留 \(preserved) 项现有任务；现有系统任务内容未被覆盖。"
        } catch {dataNotice="恢复未完成："+error.localizedDescription+(restorePending ? " 可点击继续恢复；已有系统任务未被覆盖。" : "")}
    }
    func repairLegacyTrash()async {
        guard !busy,isConnected,!restorePending else{return}
        do {
            try await reload();let nativeIDs=Set(try await reminders.fetch().compactMap(RemindersStore.taskID))
            let legacy=tasks.filter{$0.softDeleted && !$0.archived && nativeIDs.contains($0.id)}
            var count=0
            for task in legacy {await manualAction(task,intent:"delete_task",text:"修复历史回收站同步");if let errorMessage {throw AppFailure.message(errorMessage)};count+=1}
            dataNotice="历史回收站已同步 \(count) 项，均已保存可恢复快照。"
        } catch {dataNotice="同步暂停："+error.localizedDescription}
    }
    func repairFutureAlarms()async {
        guard !busy,isConnected,!restorePending else{return};busy=true;defer{busy=false}
        do {
            try await reload();let allowed=Set(tasks.filter{!$0.softDeleted && !$0.archived && !$0.completed && !$0.conflicted && $0.status != "cancelled"}.map(\.id))
            var count=0
            for row in try await reminders.fetch() {
                guard let id=RemindersStore.taskID(row),allowed.contains(id),let date=reminders.due(row),date>Date(),row.alarms?.isEmpty != false else{continue}
                row.addAlarm(EKAlarm(absoluteDate:date));try reminders.eventStore.save(row,commit:true);count+=1
            }
            dataNotice="已为 \(count) 项未来到期任务补齐系统闹钟；请确认系统提醒事项允许通知。"
        } catch {dataNotice="系统提醒同步失败："+error.localizedDescription}
    }
}

extension RemindersStore {
    func restoreSnapshot(_ snapshot:TaskSnapshot)async throws {
        guard try await fetch().allSatisfy({Self.taskID($0) != snapshot.task.id}) else{return}
        try ensureGroup(snapshot.task.group)
        let row=EKReminder(eventStore:eventStore);row.url=Self.url(snapshot.task.id);row.calendar=calendars[snapshot.task.group]!
        snapshot.fill(row);try eventStore.save(row,commit:true)
    }
}
