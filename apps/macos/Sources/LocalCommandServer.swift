import Foundation
import Darwin

struct LocalCommandRequest: Decodable {
    let token:String
    let requestId:String
    let source:String
    let text:String
}

final class LocalCommandServer {
    private let fd:Int32
    private let token:String
    private let handler:(LocalCommandRequest,@escaping(ServiceResult)->Void)->Void
    private let socketPath=AppPaths.runtime.appendingPathComponent("command.sock").path
    init(handler:@escaping(LocalCommandRequest,@escaping(ServiceResult)->Void)->Void)throws {
        self.handler=handler
        let tokenFile=AppPaths.runtime.appendingPathComponent("command-token.json")
        if let bytes=try? Data(contentsOf:tokenFile),let old=try? JSONDecoder().decode(String.self,from:bytes) { token=old }
        else { token=UUID().uuidString+UUID().uuidString;try AppPaths.write(token,to:tokenFile) }
        fd=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else { throw AppFailure.message("无法创建本机任务接口。") }
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        guard socketPath.utf8.count<MemoryLayout.size(ofValue:address.sun_path) else { Darwin.close(fd);throw AppFailure.message("本机接口路径过长。") }
        _=withUnsafeMutablePointer(to:&address.sun_path) { p in socketPath.withCString{strcpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to:CChar.self),$0)} }
        address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        if FileManager.default.fileExists(atPath:socketPath) {
            let probe=Darwin.socket(AF_UNIX,SOCK_STREAM,0)
            let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(probe,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
            Darwin.close(probe)
            guard connected != 0 else { Darwin.close(fd);throw AppFailure.message("任务管家已经在运行，请使用现有菜单栏图标。") }
            Darwin.unlink(socketPath)
        }
        let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard bound==0,Darwin.chmod(socketPath,0o600)==0,Darwin.listen(fd,8)==0 else { Darwin.close(fd);throw AppFailure.message("本机任务接口启动失败。") }
        DispatchQueue.global(qos:.utility).async { [weak self] in self?.acceptLoop() }
    }
    private func acceptLoop() {
        while true {
            let connection=Darwin.accept(fd,nil,nil)
            if connection<0 { if errno==EINTR {continue};return }
            DispatchQueue.global(qos:.utility).async { [weak self] in self?.serve(connection) }
        }
    }
    private func serve(_ connection:Int32) {
        defer{Darwin.close(connection)}
        var timeout=timeval(tv_sec:80,tv_usec:0);var one:Int32=1
        setsockopt(connection,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
        var data=Data();var byte:UInt8=0
        while data.count<32_768 {
            guard Darwin.read(connection,&byte,1)==1 else{return}
            if byte==10 {break};data.append(byte)
        }
        guard data.count<32_768,let request=try? JSONDecoder().decode(LocalCommandRequest.self,from:data),
              request.token.utf8.count==token.utf8.count,
              zip(request.token.utf8,token.utf8).reduce(UInt8(0),{$0 | ($1.0 ^ $1.1)})==0,
              request.source.hasPrefix("wechat:"),request.source.count<=100,
              MetadataOperation.isID(request.requestId) else {return}
        let semaphore=DispatchSemaphore(value:0)
        var result:ServiceResult?
        handler(request){ result=$0;semaphore.signal() }
        guard semaphore.wait(timeout:.now()+75) == .success,let result=result,
              let encoded=try? JSONEncoder().encode(result) else{return}
        let payload=encoded+Data([10])
        payload.withUnsafeBytes { buffer in
            var offset=0
            while offset<buffer.count {
                let n=Darwin.write(connection,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if n<=0 {return};offset+=n
            }
        }
    }
    deinit { Darwin.close(fd);Darwin.unlink(socketPath) }
}
