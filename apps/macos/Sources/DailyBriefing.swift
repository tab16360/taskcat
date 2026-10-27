import Foundation

// The first open each day shows a short summary of what needs attention. The model writes
// the prose; these rules pick the tasks and provide a local text when no model answers.
enum DailyBriefing {
    struct Item:Equatable {
        let title:String
        let group:String
        let due:String?
        let bucket:DueBucket
        let status:String
        let progress:Int?
    }
    static func isOpen(_ task:ManagedTask)->Bool {!task.completed && !task.softDeleted && !task.archived && task.status != "cancelled"}

    /// Overdue, due today, in progress, waiting, due tomorrow, then the rest of the week.
    static func items(_ tasks:[ManagedTask],now:Date,calendar:Calendar = .current,limit:Int=12)->[Item] {
        func rank(_ t:ManagedTask)->Int? {
            switch TaskBoard.bucket(t.dueAt,now:now,calendar:calendar) {
            case .overdue:return 0
            case .today:return 1
            case _ where t.status == "doing":return 2
            case _ where t.status == "waiting":return 3
            case .tomorrow:return 4
            case .week:return 5
            default:return nil
            }
        }
        var ranked:[(task:ManagedTask,rank:Int)]=[]
        for t in tasks where isOpen(t) {if let r=rank(t) {ranked.append((t,r))}}
        ranked.sort {a,b in
            if a.rank != b.rank {return a.rank<b.rank}
            return (a.task.dueAt ?? .distantFuture)<(b.task.dueAt ?? .distantFuture)
        }
        return ranked.prefix(limit).map {entry->Item in
            let t=entry.task
            let due:String?=t.dueAt.map{TaskBoard.dueLabel($0,now:now,calendar:calendar)}
            return Item(title:t.title,group:t.group.title,due:due,bucket:TaskBoard.bucket(t.dueAt,now:now,calendar:calendar),status:t.status,progress:t.progress)
        }
    }

    /// Overdue plus due today; shown next to the menu bar icon.
    static func attentionCount(_ tasks:[ManagedTask],now:Date,calendar:Calendar = .current)->Int {
        tasks.filter(isOpen).filter{[.overdue,.today].contains(TaskBoard.bucket($0.dueAt,now:now,calendar:calendar))}.count
    }

    static func dayKey(_ now:Date,calendar:Calendar = .current)->String {
        let c=calendar.dateComponents([.year,.month,.day],from:now)
        return String(format:"%04d-%02d-%02d",c.year ?? 0,c.month ?? 0,c.day ?? 0)
    }

    static func greeting(_ now:Date,calendar:Calendar = .current)->String {
        switch calendar.component(.hour,from:now) {
        case ..<11:return "早上好"
        case ..<14:return "中午好"
        case ..<18:return "下午好"
        default:return "晚上好"
        }
    }

    /// Used when no model is configured or the request fails, so the reminder still appears.
    static func fallback(_ items:[Item],now:Date,calendar:Calendar = .current)->String {
        let hello=greeting(now,calendar:calendar)
        guard !items.isEmpty else {return "\(hello)。今天没有到期或进行中的事项，可以从容安排。"}
        func names(_ list:[Item],withDue:Bool=false)->String {
            list.prefix(3).map{"「\($0.title)」"+(withDue ? $0.due.map{"（\($0)）"} ?? "" : "")}.joined(separator:"、")+(list.count>3 ? " 等" : "")
        }
        var lines=["\(hello)。"]
        let overdue=items.filter{$0.bucket == .overdue},today=items.filter{$0.bucket == .today}
        let doing=items.filter{$0.status == "doing" && ![.overdue,.today].contains($0.bucket)}
        let tomorrow=items.filter{$0.bucket == .tomorrow && $0.status != "doing"}
        if !overdue.isEmpty {lines.append("已逾期 \(overdue.count) 件：\(names(overdue))。")}
        if !today.isEmpty {lines.append("今天到期 \(today.count) 件：\(names(today,withDue:true))。")}
        if !doing.isEmpty {lines.append("进行中 \(doing.count) 件：\(names(doing))。")}
        if !tomorrow.isEmpty {lines.append("明天要交的有\(names(tomorrow))。")}
        if let first=overdue.first ?? today.first {lines.append("建议先处理「\(first.title)」。")}
        return lines.joined(separator:"\n")
    }
}
