import Foundation

enum ModelContextSelection {
    static func select(_ tasks:[ManagedTask],input:String,numbers:TaskNumbers,limit:Int=100)->[ManagedTask] {
        let eligible=tasks.filter{!$0.softDeleted && !$0.archived && !$0.conflicted}
        let query=input.lowercased(),number=ConversationRules.taskNumber(input)
        func score(_ task:ManagedTask)->Int {
            if let number,numbers.values[task.id]==number {return 100_000}
            let title=task.title.lowercased()
            if query.contains(title) {return 50_000+title.count}
            let chars=Array(title)
            let pairs=chars.count>1 ? Set((0..<chars.count-1).map{String(chars[$0...$0+1])}) : []
            return pairs.filter{query.contains($0)}.count*10+(query.contains(task.group.title.lowercased()) ? 5 : 0)
        }
        return Array(eligible.sorted {a,b in
            let sa=score(a),sb=score(b)
            if sa != sb {return sa>sb}
            if a.completed != b.completed {return !a.completed}
            return (numbers.values[a.id] ?? 0)<(numbers.values[b.id] ?? 0)
        }.prefix(max(0,limit)))
    }
}

struct TaskNumbers:Codable {
    var values:[String:Int]=[:]
    var lane:Int?=nil
    mutating func assign(_ tasks:[ManagedTask]) {
        guard lane==nil else{return} // synced tasks receive the creator's number, never a local guess
        var next=(values.values.max() ?? 0)+1
        for task in tasks.sorted(by:{$0.id<$1.id}) where values[task.id] == nil {values[task.id]=next;next+=1}
    }
    mutating func reserve(_ id:String)throws {
        guard values[id]==nil,let lane else{return}
        let base=lane*1000
        let next=(values.values.filter{$0/1000==lane}.max() ?? base)+1
        guard next<base+1000 else{throw AppFailure.message("此设备的任务编号段已用完，请先维护设备登记。")}
        values[id]=next
    }
    func task(_ number:Int,in tasks:[ManagedTask])->ManagedTask? {tasks.first{values[$0.id]==number && !$0.softDeleted && !$0.archived}}
}

struct FeedbackItem:Identifiable {
    let id=UUID()
    let input:String
    let output:String
    let date=Date()
    let isError:Bool
    /// "menu", "wechat" or "briefing" (the daily summary); shown as a small label.
    var origin:String="menu"
    var sections:FeedbackSections {FeedbackSections(output)}
}

struct ConversationRules {
    static func confirmation(_ input:String)->(cancel:Bool,code:String)? {
        let s=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let range=s.range(of:#"^(确认|取消)\s*([0-9]+|[0-9a-f]{8})$"#,options:.regularExpression) else{return nil}
        let text=String(s[range]);let cancel=text.hasPrefix("取消")
        return (cancel,String(text.dropFirst(2)).trimmingCharacters(in:.whitespaces))
    }
    static func matchesConfirmation(_ record:RequestRecord,source:String,code:String)->Bool {
        record.source==source && record.phase=="awaiting_confirmation" &&
        (record.confirmationNumber.map(String.init)==code || code.count==8 && record.id.hasPrefix(code))
    }
    /// Ask only when unsure: the model said so, the target task was guessed rather than named,
    /// or the date came from the model instead of the message. Group changes always ask.
    static func needsConfirmation(_ c:TaskCommand,input:String,tasks:[ManagedTask],numbers:TaskNumbers)->Bool {
        if c.requiresConfirmation || ["rename_group","delete_group"].contains(c.intent) {return true}
        if let id=c.taskId,let task=tasks.first(where:{$0.id==id}) {
            let named=taskNumber(input).map{numbers.values[id]==$0} ?? false
            if !named && !input.localizedCaseInsensitiveContains(task.title) {return true}
        }
        if let date=c.dateText,DateSuggestion.date(for:date)==nil || DateSuggestion.explicitDateText(in:input)==nil {return true}
        return false
    }
    static func taskNumber(_ text:String)->Int? {
        guard let range=text.range(of:#"(?:任务|待办)\s*#?\s*[0-9]+"#,options:.regularExpression) else{return nil}
        let digits=text[range].filter{$0.isNumber};return Int(digits)
    }
    static func isQuery(_ text:String)->Bool {
        ["几个待办","多少待办","多少个待办","有哪些待办","查看待办","查询待办","列出待办","几个任务","多少任务","有哪些任务","查询任务","列出任务","未完成任务","已完成任务","所有任务","全部任务"].contains(where:text.contains)
    }
    static func query(_ tasks:[ManagedTask],input:String,command:TaskCommand)->[ManagedTask] {
        let completed=input.contains("已完成") && !input.contains("未完成")
        let all=["所有任务","全部任务","包括已完成","包含已完成"].contains(where:input.contains)
        return tasks.filter { task in
            guard !task.softDeleted,!task.archived else{return false}
            if let group=command.text("groupId"),task.group.rawValue != group {return false}
            if completed && !all {return task.completed}
            if !all && (task.completed || task.status=="cancelled") {return false}
            if let status=command.text("status"),status != "todo",!completed {return task.status==status}
            if command.text("status")=="todo",input.contains("未开始") {return task.status=="todo" && !task.completed}
            return true
        }
    }
    static func list(_ tasks:[ManagedTask],numbers:TaskNumbers)->String {
        guard !tasks.isEmpty else{return "目前没有匹配的待办。"}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN");formatter.timeZone=TimeZone.current;formatter.dateFormat="MM.dd HH:mm"
        let blocks=tasks.prefix(15).map {task in
            let n=numbers.values[task.id].map(String.init) ?? "?"
            let date=task.dueAt.map{" · "+formatter.string(from:$0)} ?? ""
            return "\(n)、\(task.title)\n   \(task.statusLabel) · \(task.group.title)\(date)"
        }
        let tail=tasks.count>15 ? "\n\n仅显示前15项，请指定分组继续查询。" : ""
        var chosen:[String]=[]
        for block in blocks {if chosen.joined(separator:"\n\n").count+block.count>1250 {break};chosen.append(block)}
        let omitted=chosen.count<min(tasks.count,15) ? "\n\n内容较长，已显示\(chosen.count)项，可指定分组查询。" : tail
        return "共 \(tasks.count) 项\n\n"+chosen.joined(separator:"\n\n")+omitted+"\n\n回复「任务编号 + 操作」，如：任务5标记完成。"
    }
    static func scopeQuery(_ c:TaskCommand,input:String,groups:[TaskGroup])throws->TaskCommand {
        guard c.intent=="query_tasks" else{return c}
        let matches=groups.filter{input.localizedCaseInsensitiveContains($0.title)}
        guard matches.count==1 else{return c}
        var result=c
        if let requested=result.text("groupId"),requested != matches[0].rawValue {throw AppFailure.message("模型理解的分组与消息不一致，未执行，请重新说明。")}
        result.patch["groupId"] = .text(matches[0].rawValue)
        return result
    }
    static func refine(_ c:TaskCommand,input:String)->TaskCommand {
        var patch=c.patch;var intent=c.intent
        if ["待测试","待验收","等待测试","待联调"].contains(where:input.contains),["create_task","update_task","complete_task","reopen_task"].contains(intent) {
            patch["status"] = .text("waiting")
            if intent=="complete_task" {intent="update_task"}
        }
        let extracted=["create_task","update_task","complete_task","reopen_task","move_task"].contains(intent) ? DateSuggestion.explicitDateText(in:input) : nil
        return TaskCommand(operationId:c.operationId,intent:intent,taskId:c.taskId,patch:patch,
            dateText:extracted ?? c.dateText,requiresConfirmation:c.requiresConfirmation)
    }
}

struct DateSuggestion {
    static var localCalendar:Calendar {var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone.current;return c}
    static func explicitDateText(in text:String)->String? {
        let pattern=#"(?:(?:20\d{2}[-/.年])?\d{1,2}[./月-]\d{1,2}日?|今天|明天|后天|(?:下周|本周|这周|星期|周)[一二三四五六日天])(?:\s*(?:上午|下午|晚上|中午|早上)?\s*[零一二两三四五六七八九十\d]{1,3}(?:点半|[:：点时][零一二两三四五六七八九十\d]{0,3}分?))?"#
        guard let range=text.range(of:pattern,options:.regularExpression) else{return nil}
        return String(text[range])
    }
    static func date(for text:String,now:Date=Date(),calendar:Calendar=localCalendar)->Date? {
        var day:Date?
        let ns=text as NSString
        func matches(_ pattern:String)->[String]? {
            guard let regex=try? NSRegularExpression(pattern:pattern),let m=regex.firstMatch(in:text,range:NSRange(location:0,length:ns.length)) else{return nil}
            return (0..<m.numberOfRanges).map{m.range(at:$0).location==NSNotFound ? "" : ns.substring(with:m.range(at:$0))}
        }
        if text.contains("后天") {day=calendar.date(byAdding:.day,value:2,to:now)}
        else if text.contains("明天") {day=calendar.date(byAdding:.day,value:1,to:now)}
        else if text.contains("今天") {day=now}
        else if let m=matches(#"(?:(20\d{2})[-/.年])?(\d{1,2})[-/.月](\d{1,2})日?"#),let month=Int(m[2]),let d=Int(m[3]) {
            var year=Int(m[1]) ?? calendar.component(.year,from:now)
            func candidate(_ y:Int)->Date? {
                let c=DateComponents(year:y,month:month,day:d,hour:9,minute:0)
                guard let date=calendar.date(from:c),calendar.component(.month,from:date)==month,calendar.component(.day,from:date)==d else{return nil};return date
            }
            day=candidate(year)
            if m[1].isEmpty,let date=day,calendar.startOfDay(for:date)<calendar.startOfDay(for:now) {year+=1;day=candidate(year)}
        } else if let m=matches(#"(下周|本周|这周|周|星期)([一二三四五六日天])"#) {
            let weekday=["日":1,"天":1,"一":2,"二":3,"三":4,"四":5,"五":6,"六":7][m[2]]!
            let current=calendar.component(.weekday,from:now)
            let mondayOffset=(current+5)%7
            var delta=(weekday+5)%7-mondayOffset
            if m[1]=="下周" {delta+=7} else if delta<0 {delta+=7}
            day=calendar.date(byAdding:.day,value:delta,to:now)
        }
        guard let day else{return nil}
        var hour=9,minute=0
        if let m=matches(#"(\d{1,2})[:：](\d{2})"#) {hour=Int(m[1])!;minute=Int(m[2])!}
        else if let m=matches(#"([零一二两三四五六七八九十\d]{1,3})[点时](半|[零一二两三四五六七八九十\d]{1,3}分?)?"#) {
            func number(_ s:String)->Int? {
                if let n=Int(s){return n}
                let digits:[Character:Int]=["零":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
                if s=="十" {return 10};if s.count==1 {return digits[s.first!]}
                let parts=s.split(separator:"十",omittingEmptySubsequences:false)
                if parts.count==2 {return (parts[0].isEmpty ? 1 : digits[parts[0].first!] ?? -100)*10+(parts[1].isEmpty ? 0 : digits[parts[1].first!] ?? -100)}
                return nil
            }
            guard let h=number(m[1]) else{return nil};hour=h
            if m[2]=="半" {minute=30} else if !m[2].isEmpty {guard let v=number(m[2].replacingOccurrences(of:"分",with:"")) else{return nil};minute=v}
        }
        if text.contains("下午") || text.contains("晚上") || text.contains("傍晚") {if hour<12 {hour+=12}}
        if text.contains("上午"),hour==12 {hour=0}
        guard (0...23).contains(hour),(0...59).contains(minute) else{return nil}
        return calendar.date(bySettingHour:hour,minute:minute,second:0,of:day)
    }
}

struct FeedbackSections {
    let content:String
    let hint:String?
    init(_ text:String) {
        let paragraphs=text.components(separatedBy:"\n\n")
        let markers=["回复「","可说：","可回复：","仅显示前","内容较长，"]
        var content:[String]=[],hints:[String]=[]
        for paragraph in paragraphs {
            if markers.contains(where:paragraph.hasPrefix){hints.append(paragraph)}else{content.append(paragraph)}
        }
        self.content=content.joined(separator:"\n\n");self.hint=hints.isEmpty ? nil : hints.joined(separator:"\n")
    }
}

struct GroupConversation {
    static func command(_ text:String,id:String,groups:[TaskGroup])throws->TaskCommand? {
        func captures(_ pattern:String)->[String]? {
            guard let r=try? NSRegularExpression(pattern:pattern),let m=r.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else{return nil}
            return (1..<m.numberOfRanges).map{(text as NSString).substring(with:m.range(at:$0)).trimmingCharacters(in:CharacterSet(charactersIn:" ‘“”’\"。"))}
        }
        var intent="",old="",new:String?
        if let parts=captures(#"^(?:请)?(?:把|将)?\s*(.+?)\s*分组\s*(?:改名(?:为)?|重命名(?:为)?|改成|改为)\s*[：:]?\s*(.+)$"#) {intent="rename_group";old=parts[0];new=parts[1]}
        else if let parts=captures(#"^(?:请)?(?:重命名|修改)分组\s*(.+?)\s*(?:为|成|叫|改名为)\s*(.+)$"#) {intent="rename_group";old=parts[0];new=parts[1]}
        else if let parts=captures(#"^(?:请)?删除分组\s*[：:]?\s*(.+)$"#) {intent="delete_group";old=parts[0]}
        else if let parts=captures(#"^(?:请)?(?:把|将)?\s*(.+?)\s*分组\s*删除$"#) {intent="delete_group";old=parts[0]}
        else{return nil}
        guard let group=groups.first(where:{$0.rawValue.localizedCaseInsensitiveCompare(old) == .orderedSame || $0.title.localizedCaseInsensitiveCompare(old) == .orderedSame}) else{throw AppFailure.message("没有找到该分组，请先查看分组。")}
        var patch:[String:FieldValue]=["groupId":.text(group.rawValue)]
        if let new {guard let next=TaskGroup.named(new) else{throw AppFailure.message("新分组名无效。")};patch["newGroupId"] = .text(next.rawValue)}
        return TaskCommand(operationId:id,intent:intent,taskId:nil,patch:patch,dateText:nil,requiresConfirmation:true)
    }
}

enum ModelControlRequest:Equatable {case help,query,select(String)}
struct ModelConversation {
    static func compact(_ text:String)->String {text.filter{!$0.isWhitespace}.lowercased()}
    static func request(_ input:String)->ModelControlRequest? {
        let text=input.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"。？！?!")))
            .replacingOccurrences(of:#"^(?:请)?(?:帮我)?\s*"#,with:"",options:.regularExpression)
        let short=compact(text).replacingOccurrences(of:#"[呢呀吗啊]$"#,with:"",options:.regularExpression)
        if ["你能干什么","你还能干什么","你会什么","你还会什么","帮助","使用帮助","怎么用"].contains(short) {return .help}
        let queries=["查看模型","查询模型","模型列表","大模型列表","有哪些模型","有哪些大模型","当前模型","当前大模型","现在是什么模型","现在是什么大模型","你是什么模型","你是什么大模型","当前是什么模型","当前使用什么模型","当前使用的模型是什么","当前使用的大模型是什么","查看当前模型","查看当前大模型","切换模型","切换大模型","更换模型","更换大模型","现在用的什么模型","你用的什么模型"]
        let queryShape=#"^(?:查看|查询|显示|列出|看看|看下)?(?:一下)?(?:你)?(?:现在|目前|当前|正在)?(?:使用|用|调用|运行)?的?(?:ai)?(?:大模型|模型)(?:是|叫)?(?:什么|哪个|啥|什么名字|哪个型号|列表|配置|有哪些)?$"#
        if queries.contains(short) || short.range(of:queryShape,options:.regularExpression) != nil || short.range(of:#"^(?:你)?(?:现在|目前|当前|正在)?(?:用|使用|调用|运行)(?:的|着)?(?:是)?(?:什么|哪个)(?:ai)?(?:大模型|模型)$"#,options:.regularExpression) != nil {return .query}
        let pattern=#"^(?:切换|更换|换|切|使用|用)(?:一下)?(?:当前)?(?:(?:AI)?(?:大模型|模型))?(?:到|为|成)?[：:\s]*(.+)$"#
        let switched=text.replacingOccurrences(of:#"^(?:把|将)(?:当前)?(?:AI)?(?:大模型|模型)(?:切换|更换|换)(?:到|为|成)?"#,with:"切换模型",options:[.regularExpression,.caseInsensitive])
        guard let regex=try? NSRegularExpression(pattern:pattern,options:.caseInsensitive),let match=regex.firstMatch(in:switched,range:NSRange(switched.startIndex...,in:switched)) else{return nil}
        let target=(switched as NSString).substring(with:match.range(at:1)).trimmingCharacters(in:CharacterSet(charactersIn:" ‘“”’\"。？！?!"))
        let hasModel=short.contains("模型") || short.contains("model")
        guard hasModel || ["本地","云端","ollama","qwen"].contains(where:compact(target).hasPrefix) else{return nil}
        return target.isEmpty ? .query : .select(target)
    }
    static func resolve(_ input:String,profiles:[ModelProfile])throws->ModelProfile {
        let token=compact(input)
        let numbered=token.replacingOccurrences(of:#"^(?:大模型|模型)(?=[0-9]+$)"#,with:"",options:.regularExpression)
        if let n=Int(numbered),n>0,n<=profiles.count {return profiles[n-1]}
        let exact=profiles.filter{compact($0.name)==token || compact($0.model)==token}
        let provider:[String:String]=["本地":"local","本地模型":"local","本地大模型":"local","ollama":"local","云端":"cloud","云":"cloud","云模型":"cloud","云端模型":"cloud","云端大模型":"cloud"]
        let matches=exact.isEmpty ? provider[token].map{kind in profiles.filter{$0.provider==kind}} ?? [] : exact
        guard matches.count==1 else{throw AppFailure.message(matches.isEmpty ? "没有匹配的模型配置，请发送“模型列表”后按编号切换。" : "该名称对应多套模型，请发送“模型列表”后按编号切换。")}
        return matches[0]
    }
}

extension ConversationRules {
    static func cleanCreation(_ command:TaskCommand,input:String,groups:[TaskGroup])throws->TaskCommand {
        guard command.intent=="create_task" else{return command}
        func content(_ text:String)->String {
            text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:#"^(?:请)?(?:帮我)?(?:新增|新建|创建|添加)(?:一个|一项)?(?:任务|待办)[：:\s]*"#,with:"",options:.regularExpression)
        }
        func prefix(_ text:String)->(TaskGroup,String)? {
            let value=content(text)
            guard let delimiter=value.firstIndex(where:{$0==":" || $0=="："}) else{return nil}
            let name=String(value[..<delimiter]).trimmingCharacters(in:.whitespacesAndNewlines)
            let matches=groups.filter{ModelConversation.compact($0.title)==ModelConversation.compact(name) || ModelConversation.compact($0.rawValue)==ModelConversation.compact(name)}
            guard matches.count==1 else{return nil}
            return (matches[0],String(value[value.index(after:delimiter)...]).trimmingCharacters(in:.whitespacesAndNewlines))
        }
        guard let (group,body)=prefix(input),!body.isEmpty else{return command}
        var result=command;result.patch["groupId"] = .text(group.rawValue)
        if let title=command.text("title"),let (titleGroup,clean)=prefix(title),titleGroup==group {
            guard !clean.isEmpty else{throw AppFailure.message("任务标题不能为空，请补充分组后的任务内容。")}
            result.patch["title"] = .text(clean)
        }
        return result
    }
}
