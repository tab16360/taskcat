import Foundation

// Pure update decisions: no network, files or processes, so they can be tested in isolation.
struct AppVersion:Comparable,CustomStringConvertible {
    let numbers:[Int]
    let prerelease:[String]
    let description:String
    init?(_ raw:String) {
        let text=raw.trimmingCharacters(in:.whitespaces).drop{$0 == "v" || $0 == "V"}
        let parts=text.split(separator:"-",maxSplits:1).map(String.init)
        guard let core=parts.first,!core.isEmpty else{return nil}
        let numbers=core.split(separator:".",omittingEmptySubsequences:false).map{Int($0)}
        guard !numbers.isEmpty,numbers.count<=4,numbers.allSatisfy({$0 != nil && $0! >= 0}) else{return nil}
        self.numbers=numbers.map{$0!}
        prerelease=parts.count>1 ? parts[1].split(separator:".").map(String.init) : []
        description=String(text)
    }
    static func < (a:AppVersion,b:AppVersion)->Bool {
        let n=max(a.numbers.count,b.numbers.count)
        for i in 0..<n {
            let x=i<a.numbers.count ? a.numbers[i] : 0,y=i<b.numbers.count ? b.numbers[i] : 0
            if x != y {return x<y}
        }
        // A final release outranks its own previews (0.3.0 > 0.3.0-preview.2).
        if a.prerelease.isEmpty != b.prerelease.isEmpty {return !a.prerelease.isEmpty}
        for (x,y) in zip(a.prerelease,b.prerelease) where x != y {
            if let i=Int(x),let j=Int(y) {return i<j}
            return x<y
        }
        return a.prerelease.count<b.prerelease.count
    }
    static func == (a:AppVersion,b:AppVersion)->Bool {!(a<b) && !(b<a)}
}

struct ReleaseFeedItem:Decodable {
    struct Asset:Decodable {let name:String;let browser_download_url:String;let size:Int?}
    let tag_name:String
    let draft:Bool
    let prerelease:Bool
    let body:String?
    let html_url:String?
    let assets:[Asset]
}

struct UpdateCandidate:Equatable {
    let version:AppVersion
    let tag:String
    let archive:URL
    let checksum:URL
    let archiveName:String
    let notes:String
    let page:URL?
}

enum UpdateRules {
    static let repository="tab16360/taskcat"
    static let feed=URL(string:"https://api.github.com/repos/\(repository)/releases?per_page=20")!
    static var architecture:String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func archiveName(arch:String)->String {"TaskCat-\(arch).zip"}
    // Only this repository's release downloads are accepted; GitHub then redirects to its CDN.
    static func allowedDownload(_ url:URL)->Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repository)/releases/download/")
    }
    static func pick(_ releases:[ReleaseFeedItem],current:AppVersion,arch:String)->UpdateCandidate? {
        let name=archiveName(arch:arch)
        return releases.compactMap {release->UpdateCandidate? in
            guard !release.draft,let version=AppVersion(release.tag_name),version>current else{return nil}
            guard let zip=release.assets.first(where:{$0.name == name}).flatMap({URL(string:$0.browser_download_url)}),
                  let sum=release.assets.first(where:{$0.name == name+".sha256"}).flatMap({URL(string:$0.browser_download_url)}),
                  allowedDownload(zip),allowedDownload(sum) else{return nil}
            return UpdateCandidate(version:version,tag:release.tag_name,archive:zip,checksum:sum,archiveName:name,notes:release.body ?? "",page:release.html_url.flatMap(URL.init(string:)))
        }.max{$0.version<$1.version}
    }
    // shasum format: "<64 hex>  <file name>"; the name must match the archive being installed.
    static func checksum(_ text:String,archiveName:String)->String? {
        for line in text.split(whereSeparator:\.isNewline) {
            let fields=line.split(whereSeparator:{$0 == " " || $0 == "\t"})
            guard fields.count>=2,fields[0].count == 64,fields[0].allSatisfy(\.isHexDigit) else{continue}
            if fields[1].trimmingCharacters(in:CharacterSet(charactersIn:"*")) == archiveName {return fields[0].lowercased()}
        }
        return nil
    }
    static func summary(_ notes:String,lines:Int=6)->String {
        notes.split(whereSeparator:\.isNewline).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}.prefix(lines).joined(separator:"\n")
    }
    static let checkInterval:TimeInterval=24*3600
    static func checkDue(lastCheck:Date?,now:Date)->Bool {lastCheck.map{now.timeIntervalSince($0)>=checkInterval || $0>now} ?? true}
}
