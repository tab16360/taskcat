import Foundation
import SQLite3
import CryptoKit

// Durable batch barrier: a polled batch and its cursor commit in one SQLite transaction
// before anything is handled; a message is acknowledged only after its task change is
// durable. Same file and schema as the earlier Python bridge, so pending work carries over.
final class WeChatInbox {
    private var db:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)

    init(path:URL)throws {
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if !FileManager.default.fileExists(atPath:path.path) {FileManager.default.createFile(atPath:path.path,contents:nil,attributes:[.posixPermissions:0o600])}
        guard sqlite3_open(path.path,&db) == SQLITE_OK else{throw ILinkError("无法打开微信收件箱")}
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=FULL")
        try exec("CREATE TABLE IF NOT EXISTS cursors (account TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS inbox (operation_id TEXT PRIMARY KEY, account TEXT NOT NULL, payload TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)")
        try exec("CREATE TABLE IF NOT EXISTS replies (operation_id TEXT PRIMARY KEY,state TEXT NOT NULL)")
    }
    deinit {sqlite3_close(db)}

    static func accountKey(_ account:String)->String {ILinkHash.sha256(account)}

    func cursor(_ account:String)throws->String {
        try query("SELECT value FROM cursors WHERE account=?",[Self.accountKey(account)]){row in String(cString:sqlite3_column_text(row,0))}.first ?? ""
    }
    /// Raw message objects plus the server cursor, all or nothing. Returns operation IDs.
    @discardableResult func commitBatch(_ account:String,messages:[[String:Any]],cursor next:String)throws->[String] {
        let key=Self.accountKey(account)
        let prepared=try messages.map{m->(String,String) in
            guard let id=ILinkProtocol.string(m["message_id"]),let sender=ILinkProtocol.string(m["from_user_id"]),!sender.isEmpty else {
                throw ILinkError("消息缺少稳定 ID 或发送者，游标未前进")
            }
            let payload=try JSONSerialization.data(withJSONObject:m,options:[.sortedKeys,.withoutEscapingSlashes])
            return (ILinkProtocol.operationID(account:account,sender:sender,messageID:id),String(decoding:payload,as:UTF8.self))
        }
        try exec("BEGIN IMMEDIATE")
        do {
            for (op,payload) in prepared {try run("INSERT OR IGNORE INTO inbox(operation_id,account,payload) VALUES (?,?,?)",[op,key,payload])}
            try run("INSERT INTO cursors VALUES (?,?) ON CONFLICT(account) DO UPDATE SET value=excluded.value",[key,next])
            try exec("COMMIT")
        } catch {try? exec("ROLLBACK");throw error}
        return prepared.map(\.0)
    }
    func pending(_ account:String)throws->[(operationID:String,message:[String:Any])] {
        try query("SELECT operation_id,payload FROM inbox WHERE account=? AND done=0 ORDER BY rowid",[Self.accountKey(account)]){row in
            let op=String(cString:sqlite3_column_text(row,0)),payload=String(cString:sqlite3_column_text(row,1))
            let message=(try? ILinkProtocol.losslessJSON(Data(payload.utf8))) as? [String:Any] ?? [:]
            return (op,message)
        }
    }
    func acknowledge(_ operationID:String)throws {
        try run("UPDATE inbox SET done=1 WHERE operation_id=?",[operationID])
        guard sqlite3_changes(db) == 1 else{throw ILinkError("未知的消息编号")}
    }
    /// Durable pre-claim: an uncertain send is never blindly repeated after a crash.
    func claimReply(_ operationID:String)throws->Bool {
        try run("INSERT OR IGNORE INTO replies VALUES (?,?)",[operationID,"uncertain"])
        return sqlite3_changes(db) == 1
    }
    func replyState(_ operationID:String)throws->String? {
        try query("SELECT state FROM replies WHERE operation_id=?",[operationID]){row in String(cString:sqlite3_column_text(row,0))}.first
    }
    func markReplied(_ operationID:String)throws {try run("UPDATE replies SET state='accepted' WHERE operation_id=?",[operationID])}

    // MARK: SQLite helpers
    private func exec(_ sql:String)throws {
        guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else{throw ILinkError("收件箱写入失败："+String(cString:sqlite3_errmsg(db)))}
    }
    private func prepare(_ sql:String,_ args:[String])throws->OpaquePointer? {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK else{throw ILinkError("收件箱查询无效："+String(cString:sqlite3_errmsg(db)))}
        for (i,arg) in args.enumerated() {sqlite3_bind_text(statement,Int32(i+1),arg,-1,transient)}
        return statement
    }
    private func run(_ sql:String,_ args:[String])throws {
        let statement=try prepare(sql,args);defer{sqlite3_finalize(statement)}
        guard sqlite3_step(statement) == SQLITE_DONE else{throw ILinkError("收件箱写入失败："+String(cString:sqlite3_errmsg(db)))}
    }
    private func query<T>(_ sql:String,_ args:[String],_ map:(OpaquePointer?)->T)throws->[T] {
        let statement=try prepare(sql,args);defer{sqlite3_finalize(statement)}
        var rows:[T]=[]
        while sqlite3_step(statement) == SQLITE_ROW {rows.append(map(statement))}
        return rows
    }
}

enum ILinkHash {
    static func sha256(_ text:String)->String {SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
}
