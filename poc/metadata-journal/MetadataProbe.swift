import Foundation
import Darwin

@main
struct MetadataProbe {
    static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(data: try encoder.encode(value), encoding: .utf8)!)
    }
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw JournalError.invalid("usage: MetadataProbe import|project|cloud-status DIRECTORY [OPERATION_JSON]") }
            let dir = URL(fileURLWithPath: args[2], isDirectory: true)
            switch args[1] {
            case "import", "crash-import":
                let crash = args[1] == "crash-import"
                guard args.count == (crash ? 5 : 4) else { throw JournalError.invalid("operation file required") }
                if crash && !["before_publish", "after_publish"].contains(args[4]) {
                    throw JournalError.invalid("unknown crash barrier")
                }
                let op = try MetadataOperation.decode(Data(contentsOf: URL(fileURLWithPath: args[3])))
                let added = try OperationJournal(directory: dir).append(op) { stage in
                    if crash && stage == args[4] { Darwin._exit(stage == "before_publish" ? 91 : 92) }
                }
                try output(ImportResult(operationId: op.operationId, added: added))
            case "project": try output(try OperationJournal(directory: dir).project())
            case "cloud-status":
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                var statuses: [[String: Any]] = []
                for file in files {
                    let v = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                        .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey,
                        .ubiquitousItemHasUnresolvedConflictsKey])
                    statuses.append(["file": file.lastPathComponent,
                        "is_ubiquitous": v.isUbiquitousItem as Any? ?? NSNull(),
                        "is_uploaded": v.ubiquitousItemIsUploaded as Any? ?? NSNull(),
                        "is_uploading": v.ubiquitousItemIsUploading as Any? ?? NSNull(),
                        "unresolved_file_conflicts": v.ubiquitousItemHasUnresolvedConflicts as Any? ?? NSNull(),
                        "upload_error_domain": v.ubiquitousItemUploadingError?.domain as Any? ?? NSNull(),
                        "upload_error_code": v.ubiquitousItemUploadingError?.code as Any? ?? NSNull()])
                }
                let result: [String: Any] = ["event": "icloud_file_resource_values", "files": statuses,
                    "other_device_receipt_verified": false,
                    "recorded_at_utc": ISO8601DateFormatter().string(from: Date())]
                print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
            default: throw JournalError.invalid("unknown command")
            }
        } catch {
            // P0 fixtures only. Domain errors do not include file contents or secrets.
            fputs("MetadataProbe failed: \(error)\n", stderr)
            exit(2)
        }
    }
    struct ImportResult: Encodable {
        let operationId: String
        let added: Bool
    }
}
