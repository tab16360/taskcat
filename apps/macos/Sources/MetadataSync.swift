import Foundation
import CryptoKit

enum MetadataSyncError:LocalizedError {
    case waiting,invalid(String)
    var errorDescription:String? {switch self {case .waiting:return "扩展数据正在等待 iCloud Drive 下载；已有本机任务仍可使用。";case .invalid(let s):return "扩展同步已暂停："+s}}
}
struct SyncWorkspace:Codable,Equatable {
    var version=1
    let id:String
    let owner:String
    let numbers:[String:Int]
}
struct SyncDevice:Codable,Equatable {let actor:String;let lane:Int}
struct MetadataPacket:Codable {
    var version=1
    let workspace:String
    let actor:String
    let operations:[MetadataOperation]
    let numbers:[String:Int]
    let trash:[TrashEntry]
}
struct MetadataMerge {
    let operations:[String:MetadataOperation]
    let numbers:[String:Int]
    let trash:[TrashEntry]
    let lane:Int
}

/// Immutable, checksummed snapshots on iCloud Drive; never used as an execution lease.
struct SharedMetadataStore {
    let directory:URL
    private let encoder:JSONEncoder = {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return e}()
    private struct Envelope:Codable {let payload:Data;let digest:String}
    private func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func encode<T:Encodable>(_ value:T)throws->Data {
        let data=try encoder.encode(value);return try encoder.encode(Envelope(payload:data,digest:digest(data)))
    }
    private func read<T:Decodable>(_ url:URL,as type:T.Type)throws->T {
        guard FileManager.default.fileExists(atPath:url.path) else{
            try? FileManager.default.startDownloadingUbiquitousItem(at:directory.deletingLastPathComponent())
            try? FileManager.default.startDownloadingUbiquitousItem(at:directory)
            try? FileManager.default.startDownloadingUbiquitousItem(at:url)
            throw MetadataSyncError.waiting
        }
        let v=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey,.ubiquitousItemDownloadingStatusKey])
        guard v.isSymbolicLink != true,v.isRegularFile==true,(v.fileSize ?? 0)<=80_000_000 else{throw MetadataSyncError.invalid("文件类型或大小异常。")}
        if let status=v.ubiquitousItemDownloadingStatus,status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at:url);throw MetadataSyncError.waiting
        }
        var error:NSError?;var data:Data?;var failure:Error?
        NSFileCoordinator().coordinate(readingItemAt:url,options:[],error:&error){u in do{data=try Data(contentsOf:u)}catch{failure=error}}
        if let e=error {throw e};if let e=failure {throw e}
        guard let data, data.count<=80_000_000 else{throw MetadataSyncError.invalid("文件读取失败。")}
        let envelope=try JSONDecoder().decode(Envelope.self,from:data)
        guard envelope.digest==digest(envelope.payload) else{throw MetadataSyncError.invalid("文件校验失败。")}
        return try JSONDecoder().decode(type,from:envelope.payload)
    }
    private func publish<T:Encodable>(_ item:T,to file:URL)throws {
        let data=try encode(item)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if FileManager.default.fileExists(atPath:file.path) {
            guard try Data(contentsOf:file)==data else{throw MetadataSyncError.invalid("不可变文件发生冲突。")};return
        }
        let temp=file.deletingLastPathComponent().appendingPathComponent(".stage-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temp)}
        try AppPaths.write(item,to:temp) // establishes private permissions and durable staging
        try data.write(to:temp);let h=try FileHandle(forWritingTo:temp);try h.synchronize();try h.close()
        var error:NSError?;var failure:Error?
        NSFileCoordinator().coordinate(writingItemAt:file,options:[],error:&error){u in
            do {
                if FileManager.default.fileExists(atPath:u.path) {
                    guard try Data(contentsOf:u)==data else{throw MetadataSyncError.invalid("不可变文件发生冲突。")}
                } else {try FileManager.default.moveItem(at:temp,to:u)}
            } catch {failure=error}
        }
        if let e=error {throw e};if let e=failure {throw e}
    }
    private func files(_ name:String)throws->[URL] {
        let root=directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:root.path) else{return []}
        let all=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey])
        if all.contains(where:{$0.pathExtension=="icloud"}) {
            for file in all where file.pathExtension=="icloud" {
                let filename=String(file.lastPathComponent.dropFirst().dropLast(".icloud".count))
                try? FileManager.default.startDownloadingUbiquitousItem(at:root.appendingPathComponent(filename))
            }
            throw MetadataSyncError.waiting
        }
        let visible=all.filter{!$0.lastPathComponent.hasPrefix(".") && $0.pathExtension=="json"}
        guard visible.count<=2000 else{throw MetadataSyncError.invalid("同步快照过多，请先导出备份并维护同步目录。")}
        return visible.sorted{$0.lastPathComponent<$1.lastPathComponent}
    }
    func workspace()throws->SyncWorkspace {
        let w=try read(directory.appendingPathComponent("workspace.json"),as:SyncWorkspace.self)
        guard w.version==1,MetadataOperation.isID(w.id),MetadataOperation.isID(w.owner),w.numbers.keys.allSatisfy(MetadataOperation.isID),w.numbers.values.allSatisfy({$0>0 && $0<1000}),Set(w.numbers.values).count==w.numbers.count else{throw MetadataSyncError.invalid("初始化编号表无效。")}
        return w
    }
    func initialize(actor:String,numbers:[String:Int])throws {
        guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent("workspace.json").path),MetadataOperation.isID(actor),numbers.values.allSatisfy({$0>0 && $0<1000}) else{throw MetadataSyncError.invalid("已有同步空间或原编号超出初始化范围。")}
        let w=SyncWorkspace(id:UUID().uuidString.lowercased(),owner:actor,numbers:numbers)
        try publish(w,to:directory.appendingPathComponent("workspace.json"))
        try publish(SyncDevice(actor:actor,lane:0),to:directory.appendingPathComponent("devices/"+actor+".json"))
    }
    func register(actor:String)throws {
        let w=try workspace();let known=try devices(workspace:w)
        if known.contains(where:{$0.actor==actor}){return}
        let used=Set(known.map(\.lane));let lane=(1..<1000).first{!used.contains($0)}
        guard let lane else{throw MetadataSyncError.invalid("设备编号段已用完。")}
        try publish(SyncDevice(actor:actor,lane:lane),to:directory.appendingPathComponent("devices/"+actor+".json"))
        // Registration is not a cross-machine CAS: duplicate lanes are explicitly rejected on exchange.
    }
    private func devices(workspace:SyncWorkspace)throws->[SyncDevice] {
        let list=try files("devices").map{try read($0,as:SyncDevice.self)}
        guard !list.isEmpty,list.allSatisfy({MetadataOperation.isID($0.actor) && (0..<1000).contains($0.lane)}),Set(list.map(\.actor)).count==list.count,Set(list.map(\.lane)).count==list.count,list.contains(SyncDevice(actor:workspace.owner,lane:0)) else{throw MetadataSyncError.invalid("设备登记冲突；请暂停新增并重新登记冲突设备。")}
        return list
    }
    func exchange(actor:String,operations:[String:MetadataOperation],numbers:[String:Int],trash:[TrashEntry])throws->MetadataMerge {
        let w=try workspace(),devices=try devices(workspace:w)
        guard let device=devices.first(where:{$0.actor==actor}) else{throw MetadataSyncError.invalid("此设备尚未加入同步空间。")}
        var ops=operations,mapping=w.numbers,entries:[String:TrashEntry]=[:]
        let packetFiles=try files("packets")
        let total=try packetFiles.reduce(0){$0 + (try $1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)}
        guard total<=200_000_000 else{throw MetadataSyncError.invalid("同步历史超过200MB，请先备份并维护同步目录。")}
        let packets=try packetFiles.map{try read($0,as:MetadataPacket.self)}
        for packet in packets {
            guard packet.version==1,packet.workspace==w.id,devices.contains(where:{$0.actor==packet.actor}) else{throw MetadataSyncError.invalid("同步空间或设备身份不匹配。")}
            let backup=TaskBackup(snapshots:[],trash:packet.trash,operations:packet.operations,numbers:TaskNumbers(values:packet.numbers))
            try backup.validate()
            for op in packet.operations {
                if let old=ops[op.operationId],old != op{throw MetadataSyncError.invalid("操作ID内容冲突。")};ops[op.operationId]=op
            }
        }
        // Validate the complete union before committing any imported operation. This used to
        // replay every operation into a temporary on-disk journal (two fsyncs each, every 12 s);
        // the same decode and projection checks run in memory now.
        for op in ops.values {_=try MetadataOperation.decode(op.canonicalData())}
        let projection=try OperationJournal.project(ops)
        guard projection.missingParents.isEmpty else{throw MetadataSyncError.waiting}
        func mergeNumbers(_ source:[String:Int])throws {
            for (id,n) in source {
                guard MetadataOperation.isID(id),n>0 else{throw MetadataSyncError.invalid("任务编号无效。")}
                if let initial=w.numbers[id] {guard initial==n else{throw MetadataSyncError.invalid("原始任务编号被改变。")}}
                else {
                    guard let creation=ops[id],creation.entityId==id,let owner=devices.first(where:{$0.actor==creation.actorId}),n/1000==owner.lane,n%1000>0 else{throw MetadataSyncError.invalid("新任务编号不属于创建设备的编号段。")}
                }
                if let old=mapping[id],old != n{throw MetadataSyncError.invalid("同一任务收到不同编号。")}
                mapping[id]=n
            }
        }
        for packet in packets {try mergeNumbers(packet.numbers)}
        try mergeNumbers(numbers)
        guard Set(mapping.values).count==mapping.count else{throw MetadataSyncError.invalid("不同任务使用了同一编号。")}
        for entry in packets.flatMap(\.trash)+trash {
            guard let op=ops[entry.operationID],op.entityId==entry.snapshot.task.id,op.patch["softDeleted"] == .flag(true) else{throw MetadataSyncError.invalid("回收快照缺少对应删除记录。")}
            // Keep each immutable deletion snapshot; select the causal latest for local restoration below.
            if let old=entries[entry.operationID],try encoder.encode(old) != encoder.encode(entry){throw MetadataSyncError.invalid("同一删除记录的快照不一致。")}
            entries[entry.operationID]=entry
        }
        let packet=MetadataPacket(workspace:w.id,actor:actor,operations:ops.values.sorted{$0.operationId<$1.operationId},numbers:mapping,trash:entries.values.sorted{$0.operationID<$1.operationID})
        try TaskBackup(snapshots:[],trash:packet.trash,operations:packet.operations,numbers:TaskNumbers(values:packet.numbers)).validate()
        let data=try encoder.encode(packet)
        try publish(packet,to:directory.appendingPathComponent("packets/"+actor+"-"+digest(data)+".json"))
        return MetadataMerge(operations:ops,numbers:mapping,trash:packet.trash,lane:device.lane)
    }
    static func latestTrash(_ entries:[TrashEntry],operations:[String:MetadataOperation])->[TrashEntry] {
        func descends(_ child:String,from parent:String)->Bool {
            var todo=operations[child]?.parents ?? [],seen=Set<String>()
            while let next=todo.popLast(){if next==parent{return true};if seen.insert(next).inserted{todo += operations[next]?.parents ?? []}}
            return false
        }
        return Dictionary(grouping:entries,by:{$0.snapshot.task.id}).values.compactMap { versions in
            let tips=versions.filter{a in !versions.contains{b in b.operationID != a.operationID && descends(b.operationID,from:a.operationID)}}
            return tips.count==1 ? tips[0] : nil
        }
    }
}
