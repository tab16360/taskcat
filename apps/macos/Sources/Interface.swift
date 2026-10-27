import SwiftUI

struct HousekeeperView:View {
    @ObservedObject var service:TaskService
    @ObservedObject private var appearance=AppearanceStore.shared
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    @ObservedObject private var motion=ConsoleMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused:Bool
    @Namespace private var lensSpace
    @ObservedObject private var updates=UpdateService.shared
    var isPopover=false
    var openWindow:()->Void
    private var canSend:Bool {!service.busy && !service.restorePending && service.isConnected && !service.inputText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    var body:some View {
        GlassFamily { VStack(spacing:0) {
            header
            conversation
                .frame(height:service.composerCollapsed ? 0 : nil,alignment:.top)
                .clipped().opacity(service.composerCollapsed ? 0 : 1)
                .allowsHitTesting(!service.composerCollapsed).accessibilityHidden(service.composerCollapsed)
                .padding(.horizontal,22).padding(.bottom,service.composerCollapsed ? 0 : 12)
                .transaction{$0.animation=nil;$0.disablesAnimations=true}
            navigation.padding(.horizontal,22).padding(.bottom,8)
            utilityBar.padding(.horizontal,22).padding(.bottom,10)
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if service.selectedTab == "feedback" {feedbackPanel}
                    else if service.selectedTab == "pending" {
                        if let pending=service.pending {confirmation(pending)}
                        else {Text("没有待确认的操作").font(.system(size:13)).foregroundStyle(palette.muted).frame(maxWidth:.infinity).padding(28).consoleCard()}
                    }
                    else {
                        if let pending=service.pending {confirmation(pending)}
                        if service.isConnected {taskSection} else {onboarding}
                    }
                }.padding(.horizontal,22).padding(.bottom,10)
            }.scrollIndicators(.hidden)
            if service.selectedTab == "tasks",service.isConnected,service.visibleTasks.count>TaskBoard.collapsedLimit {allTasksButton.padding(.horizontal,22).padding(.bottom,10)}
        }.padding(.bottom,8)}.frame(minWidth:500,minHeight:440)
            .onChange(of:taskScope){_ in service.tasksExpanded=false}
            .background(SurfaceVisibility(motion:motion).frame(width:0,height:0))
            .themeScope(appearance.selected).environment(\.timeZone,TimeZone.current)
            .sheet(isPresented:$service.settingsPresented){SettingsView(service:service)}
            .sheet(isPresented:$service.editorPresented){TaskEditorView(service:service)}
            .sheet(isPresented:$service.groupsPresented){GroupManagementView(service:service)}
            .alert(service.destructiveAction?.title ?? "确认操作",isPresented:Binding(get:{if case .deleteGroup=service.destructiveAction{return false};return service.destructiveAction != nil},set:{if !$0{service.destructiveAction=nil}})) {
                Button("取消",role:.cancel){service.destructiveAction=nil}
                Button("确认",role:.destructive){if let action=service.destructiveAction {Task{await service.runDestructiveAction(action)}}}
            } message:{Text(service.destructiveAction?.detail ?? "")}

    }
    private func choose(_ lens:TaskLens) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration:0.18)) {
            service.taskLens=lens;service.showTrash=false;service.showCompleted=false;service.selectedTab="tasks"
        }
    }
    private var taskScope:String {"\(service.taskLens.rawValue)|\(service.selectedGroup)|\(service.showTrash)|\(service.showCompleted)"}
    private var displayedTasks:[ManagedTask] {TaskBoard.page(service.visibleTasks,expanded:service.tasksExpanded)}
    private var allTasksButton:some View {
        Button {
            service.tasksExpanded.toggle()
        } label:{
            HStack {Text(service.tasksExpanded ? "收起任务 · 仅显示前 10 项" : "查看全部任务（\(service.visibleTasks.count)）");Spacer();Image(systemName:service.tasksExpanded ? "chevron.up" : "chevron.down").font(.system(size:12,weight:.medium))}
                .font(.system(size:13,weight:.medium)).foregroundStyle(palette.text).padding(.horizontal,20).padding(.vertical,16).contentShape(Rectangle()).consoleCard(radius:18)
        }.buttonStyle(.plain).help("在当前列表展开或折叠，保留状态和分组筛选")
    }
    // Plain stack without animation: selectable Text is AppKit-backed, and morphing it from a
    // neighbouring card during insertion rendered overlapping or flipped glyphs.
    private var feedbackPanel:some View {
        VStack(alignment:.leading,spacing:12) {
            if service.feedback.isEmpty {
                VStack(spacing:8){Image(systemName:"text.bubble").font(.system(size:22,weight:.light));Text("查询结果与处理反馈会显示在这里").font(.system(size:11))}.foregroundStyle(palette.muted).frame(maxWidth:.infinity).padding(.vertical,24)
            }
            ForEach(service.feedback){item in
                VStack(alignment:.leading,spacing:9) {
                    HStack{Text(item.input).lineLimit(2);Spacer();Text(item.date,style:.time).font(.system(size:9))}.font(.system(size:11)).foregroundStyle(palette.muted)
                    Text(item.sections.content).font(.system(size:12)).lineSpacing(5).foregroundStyle(item.isError ? palette.warning : palette.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    if let hint=item.sections.hint {
                        Divider().overlay(palette.edge)
                        Label(hint,systemImage:"info.circle").font(.system(size:10)).foregroundStyle(palette.muted).lineSpacing(3).textSelection(.enabled)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(13).consoleCard(radius:12)
            }
        }.transaction{$0.animation=nil}
    }
    private var header:some View {
        HStack(spacing:10) {
            AssistantMark(size:36).accessibilityLabel("记事喵 · TaskCat")
            ViewThatFits(in:.horizontal) {
                Text("记事喵 · TaskCat")
                Text("记事喵")
            }.font(.system(size:18,weight:.semibold)).lineLimit(1)
            connectionStatus
            Spacer(minLength:6)
            Button{service.settingsPresented=true}label:{
                Image(systemName:"gearshape").font(.system(size:19,weight:.regular)).frame(width:34,height:34).themeGlass(radius:13,interactive:true)
                    .overlay(alignment:.topTrailing) {
                        if updates.candidate != nil {Circle().fill(palette.accent).frame(width:9,height:9).overlay(Circle().strokeBorder(.white,lineWidth:1.5)).offset(x:2,y:-2)}
                    }
            }.help(updates.candidate.map{"设置 · 新版本 \($0.version.description) 可安装"} ?? "设置 · 主题、模型、微信与通知")
                .accessibilityLabel(updates.candidate == nil ? "设置" : "设置，有新版本可安装")
            Button(action:openWindow){Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:16)).frame(width:34,height:34).themeGlass(radius:13,interactive:true)}.help("打开独立窗口").accessibilityLabel("打开独立窗口")
        }.buttonStyle(.plain).foregroundStyle(palette.text)
            .padding(.horizontal,24).padding(.top,22).padding(.bottom,20)
    }
    // Reminders and WeChat links replace the old bottom status bar; a click opens settings.
    private var connectionStatus:some View {
        let wechat:(label:String,tone:Color)? = {
            switch service.wechatState {
            case "stopped":return nil
            case "connected":return ("微信",palette.success)
            case "starting","waiting_for_app":return ("微信连接中",palette.accent)
            case "waiting_for_scan":return ("微信待扫码",palette.accent)
            case "network_error":return ("微信重试中",palette.warning)
            case "session_expired":return ("微信需扫码",palette.danger)
            default:return ("微信已断开",palette.danger)
            }
        }()
        // When disconnected the onboarding card explains it; the dot colour is enough here.
        return Button{service.settingsPresented=true}label:{
            HStack(spacing:7) {
                statusDot("提醒事项",tone:service.isConnected ? palette.success : palette.warning)
                if let wechat {
                    Rectangle().fill(palette.contentEdge).frame(width:1,height:10)
                    statusDot(wechat.label,tone:wechat.tone)
                }
            }.font(.system(size:11,weight:.medium)).foregroundStyle(palette.muted).lineLimit(1)
                .padding(.horizontal,9).padding(.vertical,5)
                .background(palette.text.opacity(palette.isLiquid ? 0.04 : 0.06),in:Capsule()).overlay(Capsule().strokeBorder(palette.contentEdge))
                .contentShape(Capsule())
        }.buttonStyle(.plain).fixedSize()
            .help("提醒事项：\(service.isConnected ? "已连接" : "等待连接")"+(wechat == nil ? "" : " · 微信：\(service.wechatLabel)"))
            .accessibilityElement(children:.combine)
    }
    private func statusDot(_ label:String,tone:Color)->some View {
        HStack(spacing:5){Circle().fill(tone).frame(width:6,height:6);Text(label)}
    }
    private var conversation:some View {
        Group {
            if service.conversationProcessing {thinkingComposer}
            else {idleComposer}
        // This surface must participate in the ordinary view clipping/opacity tree.
        // Native glassEffect in GlassEffectContainer can leave a detached plate visible
        // when the persistent composer is clipped to zero height on macOS.
        }.frame(maxWidth:.infinity,alignment:.topLeading).consoleCard(radius:22)
            .background(alignment:.bottom) {
                ZStack {
                    Ellipse().fill(Color.cyan.opacity(palette.isLiquid ? 0.14 : 0.18)).frame(width:220,height:38).offset(x:-110,y:18)
                    Ellipse().fill(Color.purple.opacity(palette.isLiquid ? 0.12 : 0.20)).frame(width:220,height:38).offset(x:80,y:18)
                    Ellipse().fill(Color.pink.opacity(0.10)).frame(width:120,height:28).offset(x:200,y:14)
                }.blur(radius:23).allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius:22))
            .overlay {
                RoundedRectangle(cornerRadius:22).strokeBorder(
                    LinearGradient(colors:[Color.cyan.opacity(inputFocused ? 0.65 : 0.32),Color.blue.opacity(0.12),Color.purple.opacity(0.35),Color.pink.opacity(inputFocused ? 0.5 : 0.22)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:1)
                    .allowsHitTesting(false)
            }
            .shadow(color:palette.shadow,radius:16,y:6)
    }
    private var idleComposer:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.center,spacing:13) {
                Image(systemName:"waveform").font(.system(size:23,weight:.medium))
                    .foregroundStyle(LinearGradient(colors:[.cyan,.blue,.purple,.pink],startPoint:.topLeading,endPoint:.bottomTrailing))
                    .frame(width:44,height:44).background(palette.accent.opacity(0.06),in:RoundedRectangle(cornerRadius:14)).accessibilityHidden(true)
                TextField("告诉我需要做什么…",text:$service.inputText,prompt:Text("告诉我需要做什么…").foregroundStyle(palette.muted),axis:.vertical)
                    .font(.system(size:15,weight:.regular)).foregroundStyle(palette.text).lineLimit(1...3).textFieldStyle(.plain)
                    .focused($inputFocused).onSubmit{send()}.accessibilityLabel("与记事喵对话")
                Button(action:send){
                    Image(systemName:"arrow.up").font(.system(size:23,weight:.semibold))
                        .foregroundStyle(canSend ? Color.white : (palette.isLiquid ? Color(red:0.32,green:0.38,blue:0.48) : Color(red:0.73,green:0.78,blue:0.86)))
                        .frame(width:44,height:44)
                        .background(LinearGradient(colors:canSend ? [Color.blue.opacity(0.85),Color(red:0.49,green:0.34,blue:0.94)] : (palette.isLiquid ? [Color(red:0.88,green:0.91,blue:0.96),Color(red:0.85,green:0.88,blue:0.94)] : [Color(red:0.20,green:0.24,blue:0.31),Color(red:0.17,green:0.20,blue:0.27)]),startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:14))
                        .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(canSend ? Color.white.opacity(0.15) : palette.text.opacity(0.16)))
                }.buttonStyle(SendActionButtonStyle()).disabled(!canSend).accessibilityLabel("发送").keyboardShortcut(.return,modifiers:.command).help("分析并处理 ⌘↩︎")
            }
            HStack(spacing:8) {
                Menu {
                    ForEach(service.preferences.profiles ?? []){profile in
                        Button {service.selectModel(profile.id)} label:{Label(profile.name+" · "+profile.model,systemImage:profile.id==service.preferences.selectedProfileID ? "checkmark.circle.fill" : "circle")}
                    }
                    Divider();Button("管理模型配置"){service.settingsPresented=true}
                } label:{Label(service.preferences.activeName,systemImage:service.preferences.provider=="local" ? "desktopcomputer" : "cloud").font(.system(size:10)).foregroundStyle(palette.muted)}
                    .menuStyle(.borderlessButton).fixedSize().help("切换模型")
                Spacer()
                Button("手动添加"){Task{await service.manualAdd()}}.buttonStyle(.plain).font(.system(size:10)).foregroundStyle(palette.muted).disabled(!canSend)
            }.padding(.leading,3)
            if let error=service.errorMessage {
                HStack(alignment:.top,spacing:6){Image(systemName:"exclamationmark.circle");Text(error).font(.system(size:11)).textSelection(.enabled);Spacer();Button{service.errorMessage=nil}label:{Image(systemName:"xmark").font(.system(size:9))}.buttonStyle(.plain)}.foregroundStyle(palette.warning)
            }
        }.padding(15)
    }
    private var thinkingComposer:some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:8) {
                Text(service.processingStage.contains("思考") ? "正在思考" : "正在处理").font(.system(size:13,weight:.semibold))
                Spacer()
                Text(service.preferences.activeName).font(.system(size:10)).foregroundStyle(palette.muted)
            }
            if !service.processingInput.isEmpty {
                Text(service.processingInput).font(.system(size:11)).foregroundStyle(palette.muted).lineLimit(1)
            }
            ThoughtActivityView(animated:motion.visible && !reduceMotion,dark:!palette.isLiquid).frame(height:48)
            HStack(spacing:6) {
                Circle().fill(Color.cyan).frame(width:4,height:4)
                Text(service.processingStage.isEmpty ? "连接任务服务" : service.processingStage.replacingOccurrences(of:"正在思考 · ",with:""))
                    .font(.system(size:10)).foregroundStyle(palette.text).lineLimit(1)
                Spacer()
                Text("AI").font(.system(size:9,weight:.bold,design:.rounded)).foregroundStyle(palette.muted)
            }
        }.foregroundStyle(palette.text).padding(.horizontal,16).padding(.vertical,13)
            .accessibilityElement(children:.combine)
    }
    private var groupMenu:some View {
        Menu {
            Button("全部分组"){service.selectedTab="tasks";service.selectedGroup="all"}
            Divider()
            ForEach(service.groups){group in
                Button {service.selectedTab="tasks";service.selectedGroup=group.rawValue} label:{
                    Label(group.title,systemImage:service.selectedGroup==group.rawValue ? "checkmark" : "folder")
                }
            }
            Divider()
            Button("管理分组"){service.groupsNotice="";service.groupsPresented=true}
        } label:{
            Text(service.selectedGroup == "all" ? "全部分组" : (service.groups.first{$0.rawValue == service.selectedGroup}?.title ?? "分组")).font(.system(size:11)).foregroundStyle(palette.muted)
                .padding(.horizontal,9).padding(.vertical,8).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).fixedSize().help("查看全部分组").accessibilityLabel("切换分组")
    }
    private var navigation:some View {
        HStack(spacing:2) {
            ForEach(TaskLens.allCases,id:\.rawValue){lens in
                let selected=service.selectedTab == "tasks" && !service.showTrash && !service.showCompleted && service.taskLens == lens
                let count=TaskBoard.select(service.tasks,group:service.selectedGroup,lens:lens).count
                let tone=lens == .doing ? palette.success : lens == .waiting ? palette.warning : lens == .active ? palette.accent : palette.muted
                Button{choose(lens)}label:{
                    HStack(spacing:6) {
                        Text(lens.title).font(.system(size:13,weight:selected ? .semibold : .medium))
                        Text("\(count)").font(.system(size:11,weight:.semibold)).monospacedDigit()
                            .foregroundStyle(tone).padding(.horizontal,6).padding(.vertical,1.5)
                            .background(tone.opacity(selected ? 0.16 : 0.09),in:Capsule())
                    }.foregroundStyle(selected ? palette.text : palette.muted)
                        .frame(maxWidth:.infinity).frame(height:32)
                        .selectionGlass(selected,id:"lens",in:lensSpace).contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(4).themeGlass(radius:20)
    }
    private var usesTimeline:Bool {!service.showTrash && !service.showCompleted && service.taskLens != .completed}
    private func timelineHeader(_ bucket:DueBucket,count:Int)->some View {
        let tone=bucket == .overdue ? palette.danger : bucket == .today ? palette.warning : bucket == .tomorrow ? palette.accent : palette.muted
        return HStack(spacing:6) {
            Image(systemName:bucket.symbol).font(.system(size:10,weight:.semibold))
            Text(bucket.title).font(.system(size:11,weight:.semibold))
            Text("\(count)").font(.system(size:10,weight:.medium)).monospacedDigit().foregroundStyle(palette.muted)
            Rectangle().fill(LinearGradient(colors:[tone.opacity(0.35),.clear],startPoint:.leading,endPoint:.trailing)).frame(height:1)
        }.foregroundStyle(tone).padding(.horizontal,4).padding(.top,6).accessibilityElement(children:.combine)
    }
    private var utilityBar:some View {
        HStack(spacing:8) {
            Button{service.selectedTab="feedback"}label:{Label("反馈 \(service.feedback.count)",systemImage:"text.bubble").font(.system(size:11)).padding(.horizontal,9).frame(height:28).background(service.selectedTab == "feedback" ? palette.selection : .clear,in:Capsule()).contentShape(Rectangle())}.buttonStyle(.plain)
            if service.pending != nil {
                Button{service.selectedTab="pending"}label:{Label("待确认 1",systemImage:"exclamationmark.circle").font(.system(size:11)).foregroundStyle(palette.warning).padding(.horizontal,6).frame(height:28).contentShape(Rectangle())}.buttonStyle(.plain)
            }
            groupMenu
            Spacer(minLength:0)
            Menu {
                Button("管理分组"){service.groupsNotice="";service.groupsPresented=true}
                Button("刷新任务"){Task{await service.refresh()}}
                Button("全部任务（含已完成与已取消）"){service.showCompleted=true;service.showTrash=false;service.selectedTab="tasks"}
                Button("回收站"){service.showTrash=true;service.selectedTab="tasks"}
                Divider()
                Button("退出记事喵"){NSApp.terminate(nil)}
            } label:{Image(systemName:"ellipsis").frame(width:28,height:28).contentShape(Rectangle())}.menuStyle(.borderlessButton).fixedSize().help("全部任务、分组与回收站")
            Button{
                inputFocused=false
                var transaction=Transaction();transaction.disablesAnimations=true
                withTransaction(transaction){service.composerCollapsed.toggle()}
            }label:{
                Group {if service.composerCollapsed {Image(systemName:"waveform").foregroundStyle(palette.spectrum)}else{Image(systemName:"chevron.up")}}.frame(width:28,height:28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(service.composerCollapsed ? "展开 AI 对话" : "收起 AI 对话")
        }.foregroundStyle(palette.muted)
    }
    private var taskSection:some View {
        VStack(alignment:.leading,spacing:13) {
            if service.showCompleted || service.showTrash {
                HStack(spacing:6) {
                    Image(systemName:service.showTrash ? "trash" : "checkmark.circle")
                    Text(service.showTrash ? "正在查看回收站" : "全部任务 · 含已完成与已取消")
                    if service.showTrash {Button("清空回收站"){service.destructiveAction = .emptyTrash(service.tasks.filter{$0.softDeleted})}.foregroundStyle(palette.warning).disabled(service.tasks.filter{$0.softDeleted}.isEmpty || service.busy)}
                    Spacer()
                    Button("返回待办"){service.showCompleted=false;service.showTrash=false;service.taskLens = .active}.buttonStyle(.plain).foregroundStyle(palette.accent)
                }.font(.system(size:10)).foregroundStyle(palette.muted)
            }
            // Ticks each minute so due buckets and relative labels move on time (e.g. today → overdue).
            TimelineView(.everyMinute){context in LazyVStack(alignment:.leading,spacing:8) {
                if service.visibleTasks.isEmpty {
                    VStack(spacing:10) {
                        Image(systemName:service.showTrash ? "trash" : "checkmark.seal").font(.system(size:28,weight:.ultraLight)).foregroundStyle(palette.accent)
                        Text(service.showTrash ? "回收站是空的" : "此刻，井然有序").font(.system(size:13,weight:.medium))
                        Text("在上方说一句话，开始安排下一件事。").font(.system(size:10)).foregroundStyle(palette.muted)
                    }.frame(maxWidth:.infinity).padding(.vertical,30).consoleCard(radius:20)
                }
                let now=context.date
                if usesTimeline {
                    ForEach(TaskBoard.timeline(displayedTasks,now:now),id:\.bucket){section in
                        timelineHeader(section.bucket,count:section.tasks.count)
                        ForEach(section.tasks){task in TaskRow(task:task,service:service,now:now)}
                    }
                } else {
                    ForEach(displayedTasks){task in TaskRow(task:task,service:service,now:now)}
                }
            }.animation(reduceMotion ? nil : .spring(response:0.32,dampingFraction:0.88),value:service.visibleTasks.map(\.id))}
        }
    }
    private var onboarding:some View {
        VStack(spacing:13) {
            Image(systemName:"tray.and.arrow.down").font(.system(size:27,weight:.light)).foregroundStyle(palette.accent)
            Text("连接你的提醒事项").font(.system(size:16,weight:.semibold))
            Text("在菜单栏安排好每一件事。").font(.system(size:12)).foregroundStyle(palette.muted)
            Button("授权并连接"){Task{await service.connect()}}.buttonStyle(ConsoleButton(prominent:true)).disabled(service.busy)
        }.frame(maxWidth:.infinity).padding(.vertical,28).consoleCard()
    }
    private func confirmation(_ pending:RequestRecord)->some View {
        VStack(alignment:.leading,spacing:10) {
            Label("待确认 \(pending.confirmationNumber.map(String.init) ?? String(pending.id.prefix(8)))",systemImage:"hand.raised").font(.system(size:12,weight:.semibold)).foregroundStyle(palette.accent)
            Text(pending.command?.description ?? "任务变更").font(.system(size:13,weight:.medium))
            if let title=pending.beforeTask?.title {Text(title).font(.system(size:12)).foregroundStyle(palette.muted)}
            if let command=pending.command {
                if case .number(100)=command.patch["progress"] {Text("进度 100% · 是否将此任务标记完成？").font(.system(size:12,weight:.medium))}
                Text(patchText(command)).font(.system(size:11)).foregroundStyle(palette.muted)
                if let dateText=command.dateText {
                    Text("日期：\(dateText) · 请核对本机时区时间").font(.system(size:11))
                    DatePicker("截止时间",selection:Binding(get:{service.pendingDate},set:{service.pendingDate=$0;service.pendingDateChecked=true})).labelsHidden()
                }
            }
            HStack{Button("取消"){service.cancelPending()};Spacer();Button("确认处理"){Task{await service.confirmPending()}}.buttonStyle(ConsoleButton(prominent:true))}.buttonStyle(ConsoleButton()).disabled(service.busy)
        }.padding(16).consoleCard().overlay(RoundedRectangle(cornerRadius:16).strokeBorder(palette.accent.opacity(0.25)))
    }
    private func send() {
        let text=service.inputText.trimmingCharacters(in:.whitespacesAndNewlines);guard !text.isEmpty,!service.busy else{return}
        service.inputText="";Task{let result=await service.submit(text);if !result.ok && service.inputText.isEmpty {service.inputText=text}}
    }
    private func patchText(_ command:TaskCommand)->String {
        command.patch.keys.sorted().compactMap {field in
            guard let value=command.patch[field] else{return nil}
            let label=["title":"标题","notes":"备注","status":"状态","progress":"进度","groupId":"分组"][field] ?? field
            switch value {
            case .text(let s):return "\(label)：\(["todo":"待办","doing":"进行中","waiting":"等待","cancelled":"已取消","done":"已完成","inbox":"收件箱","work":"工作","personal":"个人"][s] ?? s)"
            case .number(let n):return "\(label)：\(n)%"
            case .null:return "\(label)：未设置"
            case .flag(let b):return "\(label)：\(b ? "是" : "否")"
            }
        }.joined(separator:" · ")
    }
}

final class RowInteraction:ObservableObject {@Published var hovered=false}
// Row controls stay enabled while background sync holds busy (every 12 s); the service
// actions wait for it to finish instead of dimming and swallowing the click.
struct TaskRow:View {
    let task:ManagedTask
    @ObservedObject var service:TaskService
    var now=Date()
    @ObservedObject private var appearance=AppearanceStore.shared
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    // StateObject keeps hover across parent refreshes; plain swiftc builds lack the @State macro plugin.
    @StateObject private var interaction=RowInteraction()
    private var hovered:Bool {interaction.hovered}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var bucket:DueBucket {task.completed ? .none : TaskBoard.bucket(task.dueAt,now:now)}
    private var statusTone:Color {task.status == "doing" ? palette.accent : task.status == "waiting" ? palette.warning : palette.muted}
    private var rail:Color? {
        if task.softDeleted || task.completed {return nil}
        if bucket == .overdue {return palette.danger}
        return task.status == "doing" ? palette.accent : task.status == "waiting" ? palette.warning : nil
    }
    var body:some View {
        HStack(alignment:.center,spacing:12) {
            if task.softDeleted {
                Button("恢复"){Task{await service.restore(task)}}.font(.system(size:11)).disabled(task.conflicted)
            } else {
                Button{Task{await service.complete(task)}}label:{
                    CheckRing(progress:task.progress,completed:task.completed,tone:statusTone,hovered:hovered,palette:palette).frame(width:30,height:30).contentShape(Circle())
                }.buttonStyle(.plain).disabled(task.conflicted).help(task.completed ? "任务已完成" : "完成任务").accessibilityLabel("完成任务：\(task.title)")
            }
            Button{service.beginEdit(task)}label:{
                VStack(alignment:.leading,spacing:7) {
                    Text(task.title).font(.system(size:14.5,weight:.semibold)).lineSpacing(3).strikethrough(task.completed).foregroundStyle(task.completed ? palette.muted : palette.text).fixedSize(horizontal:false,vertical:true)
                    ViewThatFits(in:.horizontal) {
                        HStack(spacing:8){taskMetadata}
                        VStack(alignment:.leading,spacing:5){taskMetadata}
                    }.font(.system(size:11)).foregroundStyle(palette.muted)
                    if task.conflicted {Label("待核对",systemImage:"exclamationmark.triangle").font(.system(size:10)).foregroundStyle(palette.warning)}
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(task.conflicted || task.softDeleted).help("编辑任务").accessibilityLabel("\(service.number(for:task))、\(task.title)")
            HStack(spacing:4) {
                if task.softDeleted || task.status == "doing" || task.status == "waiting" || task.status == "cancelled" {statusPill}
                Menu {
                    if task.softDeleted {
                        Button("恢复"){Task{await service.restore(task)}}
                        Button("彻底删除",role:.destructive){service.destructiveAction = .purgeTask(task)}
                    } else {
                        Button("编辑任务"){service.beginEdit(task)}
                        Button("移入回收站",role:.destructive){service.destructiveAction = .deleteTask(task)}
                    }
                } label:{Image(systemName:"ellipsis").frame(width:26,height:28).contentShape(Rectangle())}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hovered ? 1 : 0.45).disabled(task.conflicted).help("任务操作")
            }.fixedSize(horizontal:true,vertical:false)
        }.padding(.leading,14).padding(.trailing,10).padding(.vertical,12)
            .overlay(alignment:.leading) {
                if let rail {Capsule().fill(rail).frame(width:3).padding(.vertical,14).padding(.leading,4).accessibilityHidden(true)}
            }
            .liquidTile(hovered:hovered)
            .onHover{interaction.hovered=$0}
            .animation(reduceMotion ? nil : .spring(response:0.28,dampingFraction:0.8),value:hovered)
    }
    private var statusPill:some View {
        let tone=task.softDeleted ? palette.muted : statusTone
        return HStack(spacing:5) {
            if let progress=task.progress,!task.completed,!task.softDeleted {
                ProgressHourglass(progress:progress,animated:!reduceMotion && task.status=="doing",color:tone).frame(width:9,height:13)
                    .accessibilityLabel("任务进度 \(progress)%").help("已记录进度 \(progress)%")
            }
            Text(task.softDeleted ? "已删除" : task.statusLabel)
            if let progress=task.progress,!task.completed,!task.softDeleted {Text("\(progress)%").monospacedDigit().opacity(0.8)}
        }.font(.system(size:11,weight:.semibold)).foregroundStyle(tone)
            .padding(.horizontal,9).padding(.vertical,5)
            .background(tone.opacity(0.11),in:Capsule()).overlay(Capsule().strokeBorder(tone.opacity(0.18)))
    }
    @ViewBuilder private var taskMetadata:some View {
        if let date=task.dueAt {
            let urgent=bucket == .overdue || bucket == .today
            let tone=bucket == .overdue ? palette.danger : bucket == .today ? palette.warning : palette.muted
            Label(task.completed ? TaskBoard.dueLabel(date,now:.distantPast) : TaskBoard.dueLabel(date,now:now),systemImage:bucket == .overdue ? "exclamationmark.circle.fill" : "clock")
                .font(.system(size:11,weight:urgent ? .semibold : .regular)).foregroundStyle(tone).lineLimit(1)
                .padding(.horizontal,urgent ? 7 : 0).padding(.vertical,urgent ? 2 : 0)
                .background(urgent ? tone.opacity(0.10) : .clear,in:Capsule())
                .help(date.formatted(.dateTime.year().month().day().hour().minute()))
        }
        HStack(spacing:5) {
            Circle().fill(palette.tag(task.group.rawValue)).frame(width:6,height:6)
            Text(task.group.title).lineLimit(1)
        }
        Text("#\(service.number(for:task))").font(.system(size:10,design:.monospaced)).foregroundStyle(palette.muted.opacity(0.8))
    }
}

// Completion target and progress in one control: the ring fills with recorded progress.
struct CheckRing:View {
    let progress:Int?
    let completed:Bool
    let tone:Color
    let hovered:Bool
    let palette:ThemePalette
    var body:some View {
        ZStack {
            Circle().strokeBorder(palette.muted.opacity(0.42),lineWidth:1.4).padding(3)
            if completed {
                Circle().fill(palette.accent).padding(3)
                Image(systemName:"checkmark").font(.system(size:11,weight:.bold)).foregroundStyle(.white)
            } else {
                if let progress,progress>0 {
                    Circle().inset(by:3.7).trim(from:0,to:CGFloat(min(progress,100))/100)
                        .stroke(tone,style:StrokeStyle(lineWidth:2.6,lineCap:.round)).rotationEffect(.degrees(-90))
                }
                Image(systemName:"checkmark").font(.system(size:10,weight:.bold)).foregroundStyle(palette.muted).opacity(hovered ? 0.75 : 0)
            }
        }.accessibilityHidden(true)
    }
}

struct SettingsView:View {
    @ObservedObject var service:TaskService
    @ObservedObject private var appearance=AppearanceStore.shared
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        GlassFamily { VStack(spacing:0) {
            HStack {
                VStack(alignment:.leading,spacing:5){Text("控制中心").font(.system(size:21,weight:.semibold));Text("模型、任务与微信，在这里连接。").font(.system(size:11)).foregroundStyle(palette.muted)}
                Spacer();Button("保存并完成"){save()}.buttonStyle(ConsoleButton(prominent:true)).keyboardShortcut(.defaultAction)
            }.padding(22)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    VStack(alignment:.leading,spacing:13) {
                        sectionTitle("外观主题",symbol:"paintpalette")
                        HStack(spacing:12) {
                            ForEach(AppTheme.allCases){choice in ThemeOption(choice:choice,appearance:appearance)}
                        }
                        Text("点击立即切换，自动记住你的选择。").font(.system(size:11)).foregroundStyle(palette.muted)
                    }.padding(18).consoleCard()
                    VStack(alignment:.leading,spacing:14) {
                        sectionTitle("AI 大脑 · 多模型配置",symbol:"cpu")
                        Picker("已保存配置",selection:Binding(get:{service.preferences.selectedProfileID ?? ""},set:{service.selectModel($0)})) {
                            ForEach(service.preferences.profiles ?? []){profile in Text(profile.name).tag(profile.id)}
                        }
                        HStack {
                            Button("新增配置"){service.addProfile()}
                            Button("移除配置"){service.removeProfile()}.disabled((service.preferences.profiles?.count ?? 0)<=1)
                            Spacer()
                            Button("保存此模型"){do{try service.saveProfile()}catch{service.settingsNotice=error.localizedDescription}}
                        }.buttonStyle(ConsoleButton()).disabled(service.busy)
                        field("配置名称",text:$service.profileNameDraft)
                        Picker("模型来源",selection:$service.preferences.provider){Text("云端 · OpenAI 兼容").tag("cloud");Text("本地 · Ollama / 兼容服务").tag("local")}
                        if service.preferences.provider == "cloud" {
                            field("服务地址",text:$service.preferences.cloudURL)
                            field("模型名称",text:$service.preferences.cloudModel)
                        } else {
                            field("服务地址",text:$service.preferences.localURL)
                            field("模型名称",text:$service.preferences.localModel)
                        }
                        VStack(alignment:.leading,spacing:6){Text("API KEY").font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(palette.muted);SecureField("留空保留已有 Key",text:$service.keyDraft).textFieldStyle(.plain).padding(11).background(palette.field,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.contentEdge))}
                        Toggle("所有 AI 修改先确认",isOn:$service.preferences.confirmAll).toggleStyle(.switch).controlSize(.small)
                        Text("本地模型默认先确认每次修改。Key 以明文保存在本机应用配置目录，仅当前用户可读写，不随任务备份导出。使用云模型时，会将输入、近期操作和最多100项相关任务的标题、状态及分组发送给所选服务；不发送任务备注。无需配置模型也可手动管理任务。").font(.system(size:10)).foregroundStyle(palette.muted)
                    }.padding(18).consoleCard()
                    VStack(alignment:.leading,spacing:13) {
                        sectionTitle("运行与通知",symbol:"bell.badge")
                        Toggle("开机自启动",isOn:Binding(get:{service.loginEnabled},set:{service.setLogin($0)})).toggleStyle(.switch)
                        if !service.loginNotice.isEmpty {Text(service.loginNotice).font(.system(size:10)).foregroundStyle(palette.muted)}
                        Text("到期任务使用系统提醒事项通知，Mac 关闭后仍可由已同步的 iPhone 提醒；请允许系统提醒事项通知。").font(.system(size:11)).foregroundStyle(palette.muted)
                        Toggle("Bark 额外推送",isOn:$service.barkPreferences.enabled).toggleStyle(.switch)
                        field("Bark 服务地址",text:$service.barkPreferences.baseURL)
                        SecureField("Device Key（留空保留已有配置）",text:$service.barkKeyDraft).textFieldStyle(.roundedBorder)
                        Text("Bark 为可选附加通道，可能与系统通知同时到达。仅在 App 运行且 Mac 唤醒时检查；API 接受不代表手机送达。").font(.system(size:10)).foregroundStyle(palette.muted)
                        Button("发送 Bark 测试通知"){Task{await service.testBark()}}.buttonStyle(ConsoleButton())
                        Text(service.barkNotice).font(.system(size:10)).foregroundStyle(palette.muted)
                    }.padding(18).consoleCard()
                    VStack(alignment:.leading,spacing:13) {
                        sectionTitle("任务同步",symbol:"arrow.triangle.2.circlepath")
                        if !service.sourceChoices.isEmpty {
                            Picker("提醒事项账户",selection:Binding(get:{service.preferences.sourceIdentifier ?? ""},set:{service.preferences.sourceIdentifier=$0})) {
                                ForEach(service.sourceChoices,id:\.id){choice in Text(choice.title).tag(choice.id)}
                            }
                            Button("重新连接所选账户"){Task{await service.connect()}}.buttonStyle(ConsoleButton())
                        }
                        Text(service.syncNote).font(.system(size:11)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
                        if !service.metadataSyncEnabled {
                            HStack {
                                Button("以此机初始化双机同步"){Task{await service.configureMetadataSync(create:true)}}
                                Button("加入已有双机同步"){Task{await service.configureMetadataSync(create:false)}}
                            }.buttonStyle(ConsoleButton()).disabled(service.busy || !service.isConnected)
                        }
                        Text("扩展日志、编号与回收快照存入自己的 iCloud Drive；Key 不参与同步。新设备先在主设备初始化，再加入。离线新增使用不同编号段；真正冲突仍暂停修改。云端历史快照如同旧备份，彻底删除任务不会擦除既有历史文件。").font(.system(size:10)).foregroundStyle(palette.muted)
                    }.padding(18).consoleCard()
                    VStack(alignment:.leading,spacing:13) {
                        sectionTitle("数据与恢复",symbol:"externaldrive")
                        HStack {
                            Button("导出备份"){Task{await service.exportBackup()}}
                            Button("恢复备份"){service.chooseBackup()}
                        }.buttonStyle(ConsoleButton()).disabled(service.busy || !service.isConnected || service.restorePending)
                        if service.restorePending {Button("继续未完成的恢复"){Task{await service.continueBackupRestore()}}.buttonStyle(ConsoleButton(prominent:true)).disabled(service.busy)}
                        HStack {
                            Button("同步历史回收站"){Task{await service.repairLegacyTrash()}}
                            Button("补齐系统提醒"){Task{await service.repairFutureAlarms()}}
                        }.buttonStyle(ConsoleButton()).disabled(service.busy || !service.isConnected || service.restorePending)
                        Text("历史回收站修复会先保存恢复快照，再移除系统中的对应提醒。补齐提醒只处理未来到期且没有闹钟的未完成任务。备份含私密任务内容，不含 Key 或微信会话；扩展数据目前保存在本机，换机前请导出。").font(.system(size:10)).foregroundStyle(palette.muted)
                        Text(service.dataNotice).font(.system(size:11)).foregroundStyle(palette.accent).textSelection(.enabled)
                    }.padding(18).consoleCard()
                    UpdateSettingsSection(service:service)
                    VStack(alignment:.leading,spacing:13) {
                        HStack{sectionTitle("微信入口（可选）",symbol:"bubble.left.and.bubble.right");Spacer();Text(service.wechatLabel).font(.system(size:10)).foregroundStyle(palette.accent)}
                        Text("菜单栏任务管理无需常开 Mac。微信机器人仅在本 App 与执行器运行时可用。").font(.system(size:10)).foregroundStyle(palette.muted)
                        Toggle("已停止其他设备上的微信执行器",isOn:$service.oldOwnerStopped).font(.system(size:11)).toggleStyle(.checkbox)
                        HStack {
                            Button("连接微信"){service.startWeChat()}.disabled(!service.oldOwnerStopped || service.wechatProcess?.isRunning == true)
                            Button("停止连接"){service.stopWeChat()}
                        }.buttonStyle(ConsoleButton())
                        if let image=service.wechatQRCode {
                            Image(nsImage:image).interpolation(.none).resizable().scaledToFit().frame(width:180,height:180).padding(12).background(.white,in:RoundedRectangle(cornerRadius:12)).frame(maxWidth:.infinity)
                            Text("用微信扫码，确认连接此设备。").font(.system(size:11)).foregroundStyle(palette.muted).frame(maxWidth:.infinity)
                        }
                    }.padding(18).consoleCard()
                    if !service.settingsNotice.isEmpty {Text(service.settingsNotice).font(.system(size:11)).foregroundStyle(palette.warning).textSelection(.enabled)}
                }.padding(.horizontal,22).padding(.bottom,22)
            }.scrollIndicators(.hidden)
        }}.frame(width:510,height:610).themeScope(appearance.selected)
        .alert("恢复备份？",isPresented:$service.backupRestorePresented) {
            Button("取消",role:.cancel){service.proposedBackup=nil}
            Button("恢复"){Task{await service.confirmBackupRestore()}}
        } message: {
            Text("将合并 \(service.proposedBackup?.snapshots.count ?? 0) 项任务及 \(service.proposedBackup?.trash.count ?? 0) 项回收记录；已有系统任务内容保留。会先保存本机安全副本，恢复期间暂停任务修改。")
        }
    }
    private func sectionTitle(_ title:String,symbol:String)->some View {Label(title,systemImage:symbol).font(.system(size:13,weight:.semibold)).foregroundStyle(palette.accent)}
    private func field(_ title:String,text:Binding<String>)->some View {
        VStack(alignment:.leading,spacing:6){Text(title).font(.system(size:10)).foregroundStyle(palette.muted);TextField(title,text:text).textFieldStyle(.plain).font(.system(size:12,design:.monospaced)).padding(11).background(palette.field,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.contentEdge))}
    }
    private func save() {
        do {
            if service.preferences.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {try service.savePreferences()}
            else {try service.saveProfile()}
            dismiss()
        } catch {service.settingsNotice=error.localizedDescription}
    }
}

struct TaskEditorView:View {
    @ObservedObject var service:TaskService
    @ObservedObject private var appearance=AppearanceStore.shared
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    var body:some View {
        GlassFamily { VStack(alignment:.leading,spacing:16) {
            HStack {Text("编辑任务").font(.system(size:17,weight:.semibold));Spacer();Button("取消"){service.editorPresented=false}.buttonStyle(ConsoleButton());Button("保存"){Task{await service.saveEdit()}}.buttonStyle(ConsoleButton(prominent:true)).disabled(service.busy)}
            ScrollView {
                VStack(alignment:.leading,spacing:15) {
                    TextField("任务标题",text:$service.editTitle,axis:.vertical).font(.system(size:15)).lineLimit(1...3).textFieldStyle(.plain).padding(12).consoleCard(radius:10)
                    TextField("备注 / 阶段说明",text:$service.editNotes,axis:.vertical).lineLimit(2...4).textFieldStyle(.plain).padding(12).consoleCard(radius:10)
                    Picker("分组",selection:$service.editGroup){ForEach(service.groups){group in Text(group.title).tag(group.rawValue)}}
                    Picker("状态",selection:$service.editStatus){Text("待办").tag("todo");Text("进行中").tag("doing");Text("等待").tag("waiting");Text("已完成").tag("done");Text("已取消").tag("cancelled")}
                    Toggle("设置进度",isOn:$service.editHasProgress)
                    if service.editHasProgress {HStack{Slider(value:$service.editProgress,in:10...100,step:10);Text("\(Int(service.editProgress))%").monospacedDigit().frame(width:40)}}
                    Toggle("设置截止时间",isOn:$service.editHasDue)
                    if service.editHasDue {DatePicker("截止时间",selection:$service.editDue)}
                    if let error=service.errorMessage {Text(error).font(.system(size:11)).foregroundStyle(palette.warning)}
                }.font(.system(size:12)).padding(2)
            }
        }.padding(20)}
        .alert("进度已达 100%",isPresented:$service.progressCompletionPresented) {
            Button("返回编辑",role:.cancel){}
            Button("标记完成并保存"){Task{await service.saveEdit(markComplete:true)}}
        } message:{Text("是否将此任务标记为已完成？")}
        .frame(width:470,height:470).themeScope(appearance.selected).environment(\.timeZone,TimeZone.current)
    }
}

struct GroupManagementView:View {
    @ObservedObject var service:TaskService
    @ObservedObject private var appearance=AppearanceStore.shared
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    var body:some View {
        GlassFamily { VStack(alignment:.leading,spacing:15) {
            HStack{Text("分组管理").font(.system(size:17,weight:.semibold));Spacer();Button("完成"){service.groupsPresented=false}.buttonStyle(ConsoleButton(prominent:true))}
            Text("按项目或主题自动分类。删除分组会保留任务，并移至收件箱。").font(.system(size:11)).foregroundStyle(palette.muted)
            HStack{TextField("新分组名称",text:$service.groupDraft).textFieldStyle(.roundedBorder).onSubmit{Task{await service.createGroup()}};Button("创建"){Task{await service.createGroup()}}.buttonStyle(ConsoleButton()).disabled(service.busy || service.groupDraft.trimmingCharacters(in:.whitespaces).isEmpty)}
            ScrollView {
                VStack(alignment:.leading,spacing:9) {
                    ForEach(service.groups){group in
                        HStack(spacing:8) {
                            Image(systemName:"folder")
                            if service.groupEditingID==group.rawValue {
                                TextField("新名称",text:$service.groupRenameDraft).textFieldStyle(.roundedBorder).onSubmit{Task{await service.renameGroup(group)}}
                                Button("保存"){Task{await service.renameGroup(group)}}.buttonStyle(ConsoleButton())
                                Button("取消"){service.groupEditingID=""}.buttonStyle(.plain)
                            } else {
                                Text(group.title);Spacer()
                                Text("\(service.tasks.filter{!$0.softDeleted && !$0.completed && $0.group==group}.count)").foregroundStyle(palette.muted)
                                if group != .inbox {
                                    Button("改名"){service.groupEditingID=group.rawValue;service.groupRenameDraft=group.title}.buttonStyle(.plain)
                                    Button("删除",role:.destructive){service.destructiveAction = .deleteGroup(group)}.buttonStyle(.plain)
                                }
                            }
                        }.font(.system(size:12)).padding(10).consoleCard(radius:10).disabled(service.busy)
                    }
                }
            }
            if !service.groupsNotice.isEmpty {Text(service.groupsNotice).font(.system(size:11)).foregroundStyle(palette.muted)}
        }.padding(20)}.frame(width:510,height:380)
            .alert(service.destructiveAction?.title ?? "确认",isPresented:Binding(get:{if case .deleteGroup=service.destructiveAction{return true};return false},set:{if !$0{service.destructiveAction=nil}})) {
                Button("取消",role:.cancel){service.destructiveAction=nil}
                Button("删除分组",role:.destructive){if let action=service.destructiveAction {Task{await service.runDestructiveAction(action)}}}
            } message:{Text(service.destructiveAction?.detail ?? "")}
            .themeScope(appearance.selected).environment(\.timeZone,TimeZone.current)
    }
}

struct ThemeOption:View {
    let choice:AppTheme
    @ObservedObject var appearance:AppearanceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    private var selected:Bool {choice == appearance.selected}
    var body:some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration:0.25)){appearance.selected=choice}
        } label:{
            VStack(alignment:.leading,spacing:10) {
                ThemeThumbnail(theme:choice).frame(height:66).clipShape(RoundedRectangle(cornerRadius:11))
                HStack(spacing:4) {
                    Text(choice.title).font(.system(size:12,weight:.semibold)).lineLimit(1)
                    Spacer(minLength:0)
                    Image(systemName:selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? palette.accent : palette.muted)
                }
                Text(choice.subtitle).font(.system(size:10)).foregroundStyle(palette.muted)
            }.padding(12).foregroundStyle(palette.text).frame(maxWidth:.infinity)
                .themeGlass(radius:17,interactive:true,prominent:selected)
                .overlay(RoundedRectangle(cornerRadius:17).strokeBorder(selected ? palette.accent.opacity(0.4) : .clear))
        }.buttonStyle(.plain).accessibilityLabel(choice.title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ThemeThumbnail:View {
    let theme:AppTheme
    var body:some View {
        let p=ThemePalette(theme:theme)
        ZStack(alignment:.topLeading) {
            LinearGradient(colors:theme == .liquidGlass ? [Color(red:0.80,green:0.94,blue:0.95),Color(red:0.93,green:0.92,blue:0.98)] : [Color(white:0.20),Color(white:0.08)],startPoint:.topLeading,endPoint:.bottomTrailing)
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:3){Circle().fill(p.accent).frame(width:5,height:5);Capsule().fill(p.muted).frame(width:35,height:3);Spacer()}
                RoundedRectangle(cornerRadius:7).fill(p.card).overlay(RoundedRectangle(cornerRadius:7).strokeBorder(p.edge)).frame(height:18)
                HStack(spacing:4){Capsule().fill(p.accent.opacity(0.4)).frame(width:23,height:5);Capsule().fill(p.muted.opacity(0.35)).frame(width:30,height:5);Spacer()}
            }.padding(10)
        }.accessibilityHidden(true)
    }
}
