import Foundation
import CryptoKit

struct BarkPreferences:Codable {
    var enabled=false
    var baseURL="https://api.day.app"
    var enabledAt:Date?=nil
    var keyService:String {
        var p=ModelPreferences();p.cloudURL=baseURL
        return "TaskSecretary.Bark."+SHA256.hash(data:Data(p.origin.utf8)).prefix(12).map{String(format:"%02x",$0)}.joined()
    }
    func endpoint()throws->URL {
        guard var c=URLComponents(string:baseURL),c.scheme=="https",c.host != nil,c.user==nil,c.password==nil,c.query==nil,c.fragment==nil else{throw AppFailure.message("Bark 地址需要 HTTPS，不能包含 Key 或其他凭证。")}
        c.path=c.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"));c.path=(c.path.isEmpty ? "" : "/"+c.path)+"/push"
        guard let url=c.url else{throw AppFailure.message("Bark 地址无效。")};return url
    }
}
struct BarkAttempt:Codable {var state:String;var date:Date}

struct BarkSchedule {
    static func isDue(_ task:ManagedTask,enabledAt:Date,now:Date)->Bool {
        guard !task.softDeleted,!task.archived,!task.completed,!task.conflicted,task.status != "cancelled",let due=task.dueAt else{return false}
        return due>=enabledAt && due<=now
    }
}
