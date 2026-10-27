import Foundation
import CryptoKit
import Darwin

/// Device-local credentials. Never included in task backup or the application bundle.
struct LocalSecrets {
    let directory:URL
    private func file(service:String,account:String)->URL {
        let key=SHA256.hash(data:Data((account+"\u{0}"+service).utf8)).map{String(format:"%02x",$0)}.joined()
        return directory.appendingPathComponent(key+".json")
    }
    private func prepare()throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let values=try directory.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey])
        guard values.isDirectory==true,values.isSymbolicLink != true else{throw AppFailure.message("本机 Key 目录不可用。")}
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        var url=directory;var valuesToSet=URLResourceValues();valuesToSet.isExcludedFromBackup=true
        try url.setResourceValues(valuesToSet)
    }
    func read(service:String,account:String="app")throws->String? {
        guard FileManager.default.fileExists(atPath:directory.path) else{return nil}
        try prepare()
        let url=file(service:service,account:account)
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        let values=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true else{throw AppFailure.message("本机 Key 文件不可用。")}
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        return try JSONDecoder().decode(String.self,from:Data(contentsOf:url))
    }
    func save(_ value:String,service:String,account:String="app")throws {
        try prepare()
        let url=file(service:service,account:account)
        if FileManager.default.fileExists(atPath:url.path) {
            guard try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw AppFailure.message("本机 Key 文件不可用。")}
        }
        let temp=directory.appendingPathComponent(".stage-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temp)}
        // Create with 0600 before writing any bytes, irrespective of the process umask.
        let fd=Darwin.open(temp.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else{throw AppFailure.message("无法创建本机 Key 文件。")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        try handle.write(contentsOf:JSONEncoder().encode(value));try handle.synchronize();try handle.close()
        guard Darwin.rename(temp.path,url.path)==0 else{throw AppFailure.message("无法保存本机 Key。")}
        let dir=Darwin.open(directory.path,O_RDONLY);guard dir>=0 else{throw AppFailure.message("无法保存本机 Key 目录。")}
        defer{Darwin.close(dir)}
        guard Darwin.fsync(dir)==0 else{throw AppFailure.message("无法持久保存本机 Key。")}
    }
}
