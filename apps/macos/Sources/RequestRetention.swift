import Foundation

// Request records are scanned on the main actor for confirmation numbers, recent activity
// and text confirmations, so finished ones are moved out of the scanned folder over time.
enum RequestRetention {
    struct Item {let id:String;let phase:String;let createdAt:String;let source:String;let confirmationNumber:Int?}
    /// Only finished records move; unfinished ones drive recovery and pending confirmations.
    static let finished:Set<String>=["applied","cancelled","failed","rejected"]
    static let keepRecent=200
    static let keepDays=14.0

    /// Finished records beyond the newest `keepRecent` that are also older than `keepDays`.
    static func archivable(_ items:[Item],now:Date)->[String] {
        let parser=ISO8601DateFormatter()
        let done=items.filter{finished.contains($0.phase)}.sorted{$0.createdAt>$1.createdAt}
        let cutoff=now.addingTimeInterval(-keepDays*86400)
        return done.dropFirst(keepRecent).filter{(parser.date(from:$0.createdAt) ?? .distantPast)<cutoff}.map(\.id)
    }
    /// Highest confirmation number seen per source, so numbers keep rising after archiving.
    static func counters(_ items:[Item],merging stored:[String:Int])->[String:Int] {
        items.reduce(into:stored){result,item in
            if let n=item.confirmationNumber {result[item.source]=max(result[item.source] ?? 0,n)}
        }
    }
}
