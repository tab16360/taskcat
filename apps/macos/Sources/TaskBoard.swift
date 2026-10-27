import Foundation

enum TaskLens:String,CaseIterable {
    case active,doing,waiting,completed
    var title:String {switch self {case .active:return "待办";case .doing:return "进行中";case .waiting:return "等待";case .completed:return "已完成"}}
    func includes(_ task:ManagedTask)->Bool {
        guard !task.softDeleted,!task.archived else{return false}
        if self == .completed {return task.completed}
        guard !task.completed,task.status != "cancelled" else{return false}
        switch self {case .doing:return task.status == "doing";case .waiting:return task.status == "waiting";default:return true}
    }
}

enum TaskBoard {
    static let collapsedLimit=10
    static func page<T>(_ items:[T],expanded:Bool)->[T] {expanded ? items : Array(items.prefix(collapsedLimit))}
    static func select(_ tasks:[ManagedTask],group:String,lens:TaskLens,trash:Bool=false,includeCompleted:Bool=false)->[ManagedTask] {
        tasks.filter {task in
            (group == "all" || task.group.rawValue == group) &&
            (trash ? task.softDeleted : includeCompleted ? !task.softDeleted && !task.archived : lens.includes(task))
        }.sorted {a,b in
            if a.completed != b.completed {return !a.completed}
            if a.dueAt != b.dueAt {return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture)}
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

// Timeline buckets follow the existing due-date sort, so each bucket stays contiguous.
enum DueBucket:String,CaseIterable {
    case overdue,today,tomorrow,week,later,none
    var title:String {
        switch self {case .overdue:return "已逾期";case .today:return "今天";case .tomorrow:return "明天";case .week:return "7 天内";case .later:return "以后";case .none:return "未定时间"}
    }
    var symbol:String {
        switch self {case .overdue:return "exclamationmark.circle";case .today:return "sun.max";case .tomorrow:return "sunrise";case .week:return "calendar";case .later:return "calendar.badge.clock";case .none:return "tray"}
    }
}

extension TaskBoard {
    static func bucket(_ due:Date?,now:Date,calendar:Calendar = .current)->DueBucket {
        guard let due else{return .none}
        if due<now {return .overdue}
        let days=dayDistance(from:now,to:due,calendar:calendar)
        return days == 0 ? .today : days == 1 ? .tomorrow : days<7 ? .week : .later
    }
    static func dueLabel(_ due:Date,now:Date,calendar:Calendar = .current)->String {
        let time=formatted(due,"HH:mm",calendar:calendar)
        switch bucket(due,now:now,calendar:calendar) {
        case .overdue:
            let days=dayDistance(from:due,to:now,calendar:calendar)
            return days == 0 ? "已过 \(time)" : "逾期 \(days) 天"
        case .today:return "今天 \(time)"
        case .tomorrow:return "明天 \(time)"
        case .week:return formatted(due,"EEE HH:mm",calendar:calendar)
        case .later,.none:return formatted(due,"M月d日",calendar:calendar)
        }
    }
    static func timeline(_ tasks:[ManagedTask],now:Date,calendar:Calendar = .current)->[(bucket:DueBucket,tasks:[ManagedTask])] {
        let grouped=Dictionary(grouping:tasks){bucket($0.dueAt,now:now,calendar:calendar)}
        return DueBucket.allCases.compactMap {key in grouped[key].map{(key,$0)}}
    }
    private static func dayDistance(from a:Date,to b:Date,calendar:Calendar)->Int {
        calendar.dateComponents([.day],from:calendar.startOfDay(for:a),to:calendar.startOfDay(for:b)).day ?? 0
    }
    private static func formatted(_ date:Date,_ pattern:String,calendar:Calendar)->String {
        let f=DateFormatter();f.calendar=calendar;f.timeZone=calendar.timeZone;f.locale=Locale(identifier:"zh_CN");f.dateFormat=pattern
        return f.string(from:date)
    }
}
