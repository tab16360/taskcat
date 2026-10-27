import Foundation
import CryptoKit
import Darwin

// P0 domain-metadata journal. Only immutable operation JSON files may be synced.
// Projection is rebuilt locally; this does NOT implement a distributed execution lock.
enum JournalError: Error {
    case invalid(String), operationIDCollision, cycle, io(Int32)
}

indirect enum FieldValue: Codable, Equatable {
    case text(String), number(Int), flag(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .flag(b) }
        else if let n = try? c.decode(Int.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else { throw JournalError.invalid("scalar value required") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .flag(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

struct MetadataOperation: Codable, Equatable {
    let schemaVersion: Int
    let operationId: String
    let entityType: String
    let entityId: String
    let actorId: String
    let parents: [String]
    let createdAt: String
    let source: String
    let summary: String
    let patch: [String: FieldValue]

    static func isID(_ s: String) -> Bool {
        guard let id = UUID(uuidString: s) else { return false }
        return id.uuidString.lowercased() == s
    }
    static func decode(_ data: Data) throws -> MetadataOperation {
        guard data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schemaVersion", "operationId", "entityType", "entityId", "actorId", "parents", "createdAt", "source", "summary", "patch"]) else {
            throw JournalError.invalid("unexpected envelope or oversized file")
        }
        let op = try JSONDecoder().decode(MetadataOperation.self, from: data)
        guard op.schemaVersion == 1, isID(op.operationId), isID(op.entityId), isID(op.actorId),
              op.parents.count <= 128, Set(op.parents).count == op.parents.count,
              op.parents == op.parents.sorted(), op.parents.allSatisfy(isID), !op.parents.contains(op.operationId),
              ISO8601DateFormatter().date(from: op.createdAt) != nil,
              ["manual", "wechat", "reconcile", "poc"].contains(op.source),
              !op.summary.isEmpty, op.summary.count <= 512,
              !op.patch.isEmpty else { throw JournalError.invalid("invalid operation metadata") }
        let taskFields: Set<String> = ["status", "progress", "archived", "softDeleted", "groupId"]
        let groupFields: Set<String> = ["sortOrder", "softDeleted"]
        let fields = op.entityType == "task" ? taskFields : op.entityType == "group" ? groupFields : []
        for (key, value) in op.patch {
            guard fields.contains(key) else { throw JournalError.invalid("unsupported field") }
            switch (key, value) {
            case ("status", .text(let s)) where ["todo", "doing", "waiting", "done", "cancelled"].contains(s): break
            case ("progress", .number(let n)) where (0...100).contains(n): break
            case ("progress", .null), ("groupId", .null): break
            case ("groupId", .text(let id)) where isID(id): break
            case ("archived", .flag), ("softDeleted", .flag): break
            case ("sortOrder", .number(let n)) where n >= 0: break
            default: throw JournalError.invalid("invalid field value")
            }
        }
        return op
    }
    func canonicalData() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

struct Candidate: Codable, Equatable {
    let operationId: String
    let value: FieldValue
}
struct EntityProjection: Codable {
    let entityType: String
    let entityId: String
    let values: [String: FieldValue]
    let conflicts: [String: [Candidate]]
    let activityOperationIds: [String]
}
struct JournalProjection: Encodable {
    let schemaVersion = 1
    let operationCount: Int
    let missingParents: [String]
    let heads: [String]
    let causallyCompleteAndConflictFree: Bool
    let entities: [EntityProjection]
    let operations: [MetadataOperation]
    let digest: String
}

struct OperationJournal {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    // Write complete bytes to a hidden staging file; link publishes without replacing an existing op.
    // Coordinated writers still verify payload identity on retries. No wall-clock winner selection.
    func append(_ op: MetadataOperation, barrier: ((String) -> Void)? = nil) throws -> Bool {
        let data = try op.canonicalData()
        _ = try MetadataOperation.decode(data)
        let target = directory.appendingPathComponent(op.operationId + ".json")
        // Already published: answer without staging and fsyncing a throwaway copy.
        if let existing = try? Data(contentsOf: target) {
            guard try MetadataOperation.decode(existing) == op else { throw JournalError.operationIDCollision }
            return false
        }
        let temporary = directory.appendingPathComponent(".staging-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
            attributes: [.posixPermissions: 0o600]) else { throw JournalError.invalid("staging failed") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        barrier?("before_publish")
        var coordinateError: NSError?
        var result: Result<Bool, Error>?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordinateError) { url in
            do {
                if Darwin.link(temporary.path, url.path) == 0 {
                    let fd = Darwin.open(directory.path, O_RDONLY)
                    guard fd >= 0 else { throw JournalError.io(errno) }
                    defer { Darwin.close(fd) }
                    guard Darwin.fsync(fd) == 0 else { throw JournalError.io(errno) }
                    barrier?("after_publish")
                    result = .success(true)
                } else if errno == EEXIST {
                    let old = try MetadataOperation.decode(Data(contentsOf: url))
                    guard old == op else { throw JournalError.operationIDCollision }
                    result = .success(false)
                } else { throw JournalError.io(errno) }
            } catch { result = .failure(error) }
        }
        if let e = coordinateError { throw e }
        guard let outcome = result else { throw JournalError.invalid("coordinator did not run") }
        return try outcome.get()
    }

    func load() throws -> [String: MetadataOperation] {
        var result: [String: MetadataOperation] = [:]
        // Read only flat files in the dedicated directory, including conflict-copy JSON names.
        for file in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter({ $0.pathExtension == "json" }) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw JournalError.invalid("unexpected journal entry")
            }
            var e: NSError?
            var read: Result<MetadataOperation, Error>?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &e) { url in
                read = Result { try MetadataOperation.decode(Data(contentsOf: url)) }
            }
            if let e = e { throw e }
            guard let read = read else { throw JournalError.invalid("coordinated read did not run") }
            let op = try read.get()
            if let old = result[op.operationId], old != op { throw JournalError.operationIDCollision }
            result[op.operationId] = op
        }
        return result
    }

    func project() throws -> JournalProjection { try Self.project(try load()) }

    /// Same projection over operations already in memory, e.g. to validate a merge before writing.
    static func project(_ byID: [String: MetadataOperation]) throws -> JournalProjection {
        let ids = Set(byID.keys)
        let parentIDs = Set(byID.values.flatMap(\.parents))
        let missing = parentIDs.subtracting(ids).sorted()
        let heads = ids.subtracting(parentIDs).sorted()
        let ordered = byID.values.sorted { $0.operationId < $1.operationId }
        let canonical = try ordered.map { String(data: try $0.canonicalData(), encoding: .utf8)! }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        // Missing files may arrive later. Do not materialize a partial, apparently valid entity.
        guard missing.isEmpty else {
            return JournalProjection(operationCount: byID.count, missingParents: missing, heads: heads,
                causallyCompleteAndConflictFree: false, entities: [], operations: ordered, digest: digest)
        }
        var ancestors: [String: Set<String>] = [:]
        var visiting = Set<String>()
        func visit(_ id: String) throws -> Set<String> {
            if let cached = ancestors[id] { return cached }
            guard !visiting.contains(id) else { throw JournalError.cycle }
            visiting.insert(id)
            var value = Set<String>()
            for parent in byID[id]!.parents {
                value.insert(parent); value.formUnion(try visit(parent))
            }
            visiting.remove(id); ancestors[id] = value
            return value
        }
        for id in ids { _ = try visit(id) }
        let grouped = Dictionary(grouping: ordered, by: { $0.entityType + ":" + $0.entityId })
        var entities: [EntityProjection] = []
        var anyConflicts = false
        for key in grouped.keys.sorted() {
            let ops = grouped[key]!
            var fields: [String: [Candidate]] = [:]
            for op in ops {
                for (field, value) in op.patch {
                    fields[field, default: []].append(Candidate(operationId: op.operationId, value: value))
                }
            }
            var values: [String: FieldValue] = [:]
            var conflicts: [String: [Candidate]] = [:]
            for (field, candidates) in fields {
                let tips = candidates.filter { c in
                    !candidates.contains { other in ancestors[other.operationId]!.contains(c.operationId) }
                }.sorted { $0.operationId < $1.operationId }
                if tips.allSatisfy({ $0.value == tips[0].value }) {
                    values[field] = tips[0].value
                } else { conflicts[field] = tips; anyConflicts = true }
            }
            entities.append(EntityProjection(entityType: ops[0].entityType, entityId: ops[0].entityId,
                values: values, conflicts: conflicts, activityOperationIds: ops.map(\.operationId)))
        }
        return JournalProjection(operationCount: byID.count, missingParents: [], heads: heads,
            causallyCompleteAndConflictFree: !anyConflicts, entities: entities, operations: ordered, digest: digest)
    }
}
