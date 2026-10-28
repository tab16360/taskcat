import SwiftUI
import AppKit

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
    private var canSend:Bool {!service.uiBusy && !service.restorePending && service.isConnected && !service.inputText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    var body:some View {
        GlassFamily { VStack(spacing:0) {
            header
            conversation
                .frame(height:service.composerCollapsed ? 0 : nil,alignment:.top)
                .clipped().opacity(service.composerCollapsed ? 0 : 1)
                .allowsHitTesting(!service.composerCollapsed).accessibilityHidden(service.composerCollapsed)
                .padding(.horizontal,22).padding(.bottom,service.composerCollapsed ? 0 : 12)
                .transaction{$0.animation=nil;$0.disablesAnimations=true}
            if !service.composerCollapsed,service.selectedTab != "feedback",service.briefingInProgress || service.latestReply != nil {
                replyCard.padding(.horizontal,22).padding(.bottom,12)
            }
            navigation.padding(.horizontal,22).padding(.bottom,8)
            utilityBar.padding(.horizontal,22).padding(.bottom,10)
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if service.selectedTab == "feedback" {conversationHistory}
                    else if service.selectedTab == "pending" {
                        if let pending=service.pending {confirmation(pending)}
                        else {Text("没有待确认的操作").font(.system(size:13)).foregroundStyle(palette.muted).frame(maxWidth:.infinity).padding(28).consoleCard()}
                    }
                    else {
                        if let pending=service.pending {confirmation(pending)}
                        if service.isConnected {taskSection} else {onboarding}
                    }
                }.padding(.horizontal,22).padding(.bottom,10)
            }.scrollIndicators(.never)
            if service.selectedTab == "tasks",service.isConnected,service.visibleTasks.count>TaskBoard.collapsedLimit {allTasksButton.padding(.horizontal,22).padding(.bottom,10)}
        }.padding(.bottom,8)}.frame(minWidth:500,minHeight:440)
            .overlay(alignment:.bottom){if let notice=service.undoNotice {undoToast(notice).padding(.bottom,18)}}
            .animation(reduceMotion ? nil : .spring(response:0.3,dampingFraction:0.85),value:service.undoNotice)
            .onChange(of:taskScope){_ in service.tasksExpanded=false}
            .onChange(of:service.focusRequest){_ in if service.activeSurface == surface {inputFocused=true}}
            .background(SurfaceVisibility(motion:motion).frame(width:0,height:0))
            .background(KeySurfaceTracker{[surface] in if service.activeSurface != surface {service.activeSurface=surface}}.frame(width:0,height:0))
            .themeScope(appearance.selected).environment(\.timeZone,TimeZone.current)
            .sheet(isPresented:onSurface(\.settingsPresented)){SettingsView(service:service)}
            .sheet(isPresented:onSurface(\.editorPresented)){TaskEditorView(service:service)}
            .sheet(isPresented:onSurface(\.groupsPresented)){GroupManagementView(service:service)}
            .alert(service.destructiveAction?.title ?? "确认操作",isPresented:Binding(get:{if case .deleteGroup=service.destructiveAction{return false};return service.destructiveAction != nil && service.activeSurface == surface},set:{if !$0{service.destructiveAction=nil}})) {
                Button("取消",role:.cancel){service.destructiveAction=nil}
                Button("确认",role:.destructive){if let action=service.destructiveAction {Task{await service.runDestructiveAction(action)}}}
            } message:{Text(service.destructiveAction?.detail ?? "")}

    }
    // Popover and window both host this view and share the service's presentation flags.
    // Only the surface the user last used presents them; otherwise the hidden copy attaches
    // the same sheet to its own invisible window, which also makes macOS refuse to quit.
    private var surface:String {isPopover ? "popover" : "window"}
    private func onSurface(_ flag:ReferenceWritableKeyPath<TaskService,Bool>)->Binding<Bool> {
        Binding(get:{service[keyPath:flag] && service.activeSurface == surface},set:{service[keyPath:flag]=$0})
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
    private var conversationHistory:some View {
        VStack(alignment:.leading,spacing:12) {
            if service.feedback.isEmpty {
                VStack(spacing:8){Image(systemName:"bubble.left.and.text.bubble.right").font(.system(size:22,weight:.light));Text("和记事喵的对话、查询结果与每日提醒会显示在这里").font(.system(size:12))}.foregroundStyle(palette.muted).frame(maxWidth:.infinity).padding(.vertical,24)
            }
            ForEach(service.feedback){item in
                VStack(alignment:.leading,spacing:9) {
                    HStack(spacing:6){originLabel(item);Text(item.input).lineLimit(2);Spacer();Text(item.date,style:.time).font(.system(size:10))}.font(.system(size:12)).foregroundStyle(palette.muted)
                    replyText(item)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(13).consoleCard(radius:12)
            }
        }.transaction{$0.animation=nil}
    }
    @ViewBuilder private func originLabel(_ item:FeedbackItem)->some View {
        let label=item.origin.hasPrefix("briefing") ? "今日提醒" : item.origin == "wechat" ? "微信" : nil
        if let label {
            Text(label).font(.system(size:10,weight:.semibold)).foregroundStyle(palette.accent)
                .padding(.horizontal,6).padding(.vertical,2).background(palette.accent.opacity(0.10),in:Capsule())
        }
    }
    @ViewBuilder private func replyText(_ item:FeedbackItem,lines:Int?=nil)->some View {
        Text(item.sections.content).font(.system(size:13)).lineSpacing(5).lineLimit(lines).foregroundStyle(item.isError ? palette.warning : palette.text).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
        if lines == nil,let hint=item.sections.hint {
            Divider().overlay(palette.edge)
            Label(hint,systemImage:"info.circle").font(.system(size:11)).foregroundStyle(palette.muted).lineSpacing(3).textSelection(.enabled)
        }
    }
    /// The latest reply or today's briefing, right under the input instead of switching tabs.
    private var replyCard:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:6) {
                Image(systemName:"sparkles").foregroundStyle(palette.spectrum)
                if service.briefingInProgress && service.latestReply?.origin.hasPrefix("briefing") != true {
                    Text("正在整理今日待办…").foregroundStyle(palette.muted)
                } else if let item=service.latestReply {
                    Text(item.origin.hasPrefix("briefing") ? "今日提醒" : item.origin == "wechat" ? "来自微信 · \(item.input)" : item.input).lineLimit(1).foregroundStyle(palette.muted)
                    if item.origin == "briefing" {Text("AI 整理 · \(service.preferences.activeName)").foregroundStyle(palette.muted.opacity(0.8))}
                }
                Spacer()
                if service.latestReply?.origin.hasPrefix("briefing") == true {
                    Button{Task{await service.runBriefing()}}label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.plain).foregroundStyle(palette.muted).help("重新整理").disabled(service.briefingInProgress)
                }
                Button{service.selectedTab="feedback"}label:{Text("对话记录")}.buttonStyle(.plain).foregroundStyle(palette.accent).help("查看全部对话")
                Button{service.latestReply=nil}label:{Image(systemName:"xmark")}.buttonStyle(.plain).foregroundStyle(palette.muted).help("收起")
            }.font(.system(size:11,weight:.medium))
            if service.briefingInProgress && service.latestReply?.origin.hasPrefix("briefing") != true {
                ThoughtActivityView(animated:motion.visible && !reduceMotion,dark:!palette.isLiquid).frame(height:28)
            } else if let item=service.latestReply {
                replyText(item,lines:6)
            }
        }.padding(.horizontal,14).padding(.vertical,11).consoleCard(radius:16)
            .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(palette.accent.opacity(0.18)))
    }
    private func undoToast(_ notice:UndoNotice)->some View {
        HStack(spacing:10) {
            Image(systemName:"checkmark.circle.fill").foregroundStyle(palette.success)
            Text("已完成「\(notice.title)」").lineLimit(1)
            Button("撤销"){Task{await service.undoCompletion()}}.buttonStyle(.plain).foregroundStyle(palette.accent).fontWeight(.semibold)
        }.font(.system(size:12)).padding(.horizontal,14).padding(.vertical,9)
            .themeGlass(radius:18).shadow(color:palette.shadow,radius:10,y:4)
            .transition(.move(edge:.bottom).combined(with:.opacity))
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
            Button{service.openSettings(updates.candidate == nil ? "general" : "update")}label:{
                Image(systemName:"gearshape").font(.system(size:19,weight:.regular)).frame(width:34,height:34).themeGlass(radius:13,interactive:true)
                    .overlay(alignment:.topTrailing) {
                        if updates.candidate != nil {Circle().fill(palette.accent).frame(width:9,height:9).overlay(Circle().strokeBorder(.white,lineWidth:1.5)).offset(x:2,y:-2)}
                    }
            }.help(updates.candidate.map{"设置 · 新版本 \($0.version.description) 可安装"} ?? "设置 · 主题、模型、微信与通知")
                .accessibilityLabel(updates.candidate == nil ? "设置" : "设置，有新版本可安装")
            if isPopover {
                Button(action:openWindow){Image(systemName:"arrow.up.left.and.arrow.down.right").font(.system(size:16)).frame(width:34,height:34).themeGlass(radius:13,interactive:true)}.help("打开独立窗口").accessibilityLabel("打开独立窗口")
            }
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
            case "waiting_for_scan","scanned","need_verifycode":return ("微信待扫码",palette.accent)
            case "network_error":return ("微信重试中",palette.warning)
            case "session_expired","login_expired":return ("微信需扫码",palette.danger)
            default:return ("微信已断开",palette.danger)
            }
        }()
        // When disconnected the onboarding card explains it; the dot colour is enough here.
        // Each half opens the settings section that can fix it.
        return HStack(spacing:7) {
            Button{service.openSettings("sync")}label:{statusDot("提醒事项",tone:service.isConnected ? palette.success : palette.warning)}
                .help("提醒事项：\(service.isConnected ? "已连接" : "等待连接") · 点击查看同步设置")
            if let wechat {
                Rectangle().fill(palette.contentEdge).frame(width:1,height:10)
                Button{service.openSettings("wechat")}label:{statusDot(wechat.label,tone:wechat.tone)}.help("微信：\(service.wechatLabel) · 点击查看微信设置")
            }
        }.buttonStyle(.plain).font(.system(size:11,weight:.medium)).foregroundStyle(palette.muted).lineLimit(1)
            .padding(.horizontal,9).padding(.vertical,5)
            .background(palette.text.opacity(palette.isLiquid ? 0.04 : 0.06),in:Capsule()).overlay(Capsule().strokeBorder(palette.contentEdge))
            .fixedSize()
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
                    // ⇧↩ adds the text as a task title as-is, without asking the model.
                    .onKeyPress(.return,phases:.down){press in
                        guard press.modifiers.contains(.shift),canSend else{return .ignored}
                        Task{await service.manualAdd()};return .handled
                    }
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
                    Divider();Button("管理模型配置"){service.openSettings("ai")}
                } label:{Label(service.preferences.activeName,systemImage:service.preferences.provider=="local" ? "desktopcomputer" : "cloud").font(.system(size:11)).foregroundStyle(palette.muted)}
                    .menuStyle(.borderlessButton).fixedSize().help("切换模型")
                Spacer()
                Button{Task{await service.manualAdd()}}label:{Label("直接添加 ⇧↩",systemImage:"plus")}.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(palette.muted).disabled(!canSend)
                    .help("不经过 AI，把输入的文字直接作为任务标题添加（⇧↩）")
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
        let filtered=service.selectedGroup != "all"
        let name=filtered ? (service.groups.first{$0.rawValue == service.selectedGroup}?.title ?? "分组") : "全部分组"
        return HStack(spacing:2) {
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
                Text(filtered ? "分组：\(name)" : name).font(.system(size:12,weight:filtered ? .semibold : .regular)).foregroundStyle(filtered ? palette.accent : palette.muted)
                    .padding(.leading,9).padding(.trailing,filtered ? 2 : 9).padding(.vertical,6).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).fixedSize().help("按分组筛选").accessibilityLabel("切换分组")
            // A visible way out: the filter also narrows every tab count.
            if filtered {
                Button{service.selectedGroup="all"}label:{Image(systemName:"xmark.circle.fill").font(.system(size:12))}
                    .buttonStyle(.plain).foregroundStyle(palette.accent.opacity(0.7)).padding(.trailing,7).help("清除分组筛选").accessibilityLabel("清除分组筛选")
            }
        }.background(filtered ? palette.accent.opacity(0.10) : .clear,in:Capsule())
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
            Image(systemName:bucket.symbol).font(.system(size:11,weight:.semibold))
            Text(bucket.title).font(.system(size:12,weight:.semibold))
            Text("\(count)").font(.system(size:11,weight:.medium)).monospacedDigit().foregroundStyle(palette.muted)
            Rectangle().fill(LinearGradient(colors:[tone.opacity(0.35),.clear],startPoint:.leading,endPoint:.trailing)).frame(height:1)
        }.foregroundStyle(tone).padding(.horizontal,4).padding(.top,6).accessibilityElement(children:.combine)
    }
    private var trashCount:Int {service.tasks.filter(\.softDeleted).count}
    private var utilityBar:some View {
        VStack(spacing:8) {
            HStack(spacing:6) {
                Button{service.selectedTab=service.selectedTab == "feedback" ? "tasks" : "feedback"}label:{
                    Label("对话 \(service.feedback.count)",systemImage:"bubble.left.and.text.bubble.right").font(.system(size:12)).padding(.horizontal,9).frame(height:28)
                        .background(service.selectedTab == "feedback" ? palette.selection : .clear,in:Capsule()).contentShape(Rectangle())
                }.buttonStyle(.plain).help("和记事喵的对话记录与每日提醒")
                if service.pending != nil {
                    Button{service.selectedTab="pending"}label:{Label("待确认 1",systemImage:"exclamationmark.circle").font(.system(size:12)).foregroundStyle(palette.warning).padding(.horizontal,6).frame(height:28).contentShape(Rectangle())}.buttonStyle(.plain)
                }
                groupMenu
                Spacer(minLength:0)
                Button{
                    service.searchVisible.toggle();if !service.searchVisible {service.searchText=""}
                    if service.searchVisible {service.selectedTab="tasks"}
                }label:{Image(systemName:"magnifyingglass").frame(width:28,height:28).contentShape(Rectangle())}
                    .buttonStyle(.plain).foregroundStyle(service.searchVisible ? palette.accent : palette.muted).help("搜索任务")
                Button{service.showTrash.toggle();service.showCompleted=false;service.selectedTab="tasks"}label:{
                    HStack(spacing:3){Image(systemName:"trash");if trashCount>0 {Text("\(trashCount)").font(.system(size:11)).monospacedDigit()}}.frame(minWidth:28).frame(height:28).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(service.showTrash ? palette.accent : palette.muted).help(service.showTrash ? "返回任务列表" : "回收站")
                Menu {
                    Button(service.showCompleted ? "返回列表" : "全部任务（含已完成与已取消）"){service.showCompleted.toggle();service.showTrash=false;service.selectedTab="tasks"}
                    Divider()
                    Button("退出记事喵"){NSApp.terminate(nil)}
                } label:{Image(systemName:"ellipsis").frame(width:28,height:28).contentShape(Rectangle())}.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多")
                Button{
                    inputFocused=false
                    var transaction=Transaction();transaction.disablesAnimations=true
                    withTransaction(transaction){service.composerCollapsed.toggle()}
                }label:{
                    Group {if service.composerCollapsed {Image(systemName:"waveform").foregroundStyle(palette.spectrum)}else{Image(systemName:"chevron.up")}}.frame(width:28,height:28).contentShape(Rectangle())
                }.buttonStyle(.plain).help(service.composerCollapsed ? "展开对话区" : "收起对话区，留出更多空间看任务").accessibilityLabel(service.composerCollapsed ? "展开 AI 对话" : "收起 AI 对话")
            }.foregroundStyle(palette.muted)
            if service.searchVisible {
                HStack(spacing:6) {
                    Image(systemName:"magnifyingglass").foregroundStyle(palette.muted)
                    TextField("搜索标题、备注或分组",text:$service.searchText).textFieldStyle(.plain).font(.system(size:13))
                    if !service.searchText.isEmpty {Button{service.searchText=""}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(palette.muted)}
                }.padding(.horizontal,11).padding(.vertical,7).consoleCard(radius:12)
            }
        }
    }
    private var taskSection:some View {
        VStack(alignment:.leading,spacing:13) {
            if service.showCompleted || service.showTrash {
                HStack(spacing:6) {
                    Image(systemName:service.showTrash ? "trash" : "checkmark.circle")
                    Text(service.showTrash ? "正在查看回收站" : "全部任务 · 含已完成与已取消")
                    if service.showTrash {Button("清空回收站"){service.destructiveAction = .emptyTrash(service.tasks.filter{$0.softDeleted})}.foregroundStyle(palette.warning).disabled(service.tasks.filter{$0.softDeleted}.isEmpty || service.uiBusy)}
                    Spacer()
                    Button("返回列表"){service.showCompleted=false;service.showTrash=false;service.taskLens = .active}.buttonStyle(.plain).foregroundStyle(palette.accent)
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
            Button("授权并连接"){Task{await service.connect()}}.buttonStyle(ConsoleButton(prominent:true)).disabled(service.uiBusy)
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
            HStack{Button("取消"){service.cancelPending()};Spacer();Button("确认处理"){Task{await service.confirmPending()}}.buttonStyle(ConsoleButton(prominent:true))}.buttonStyle(ConsoleButton()).disabled(service.uiBusy)
        }.padding(16).consoleCard().overlay(RoundedRectangle(cornerRadius:16).strokeBorder(palette.accent.opacity(0.25)))
    }
    private func send() {
        let text=service.inputText.trimmingCharacters(in:.whitespacesAndNewlines);guard !text.isEmpty,!service.uiBusy else{return}
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

/// Reports when the hosting window becomes key, i.e. the user starts using that surface.
struct KeySurfaceTracker:NSViewRepresentable {
    let onKey:()->Void
    func makeNSView(context:Context)->TrackerView {TrackerView(onKey:onKey)}
    func updateNSView(_ view:TrackerView,context:Context) {view.onKey=onKey}
    final class TrackerView:NSView {
        var onKey:()->Void
        private var observer:NSObjectProtocol?
        init(onKey:@escaping()->Void) {self.onKey=onKey;super.init(frame:.zero)}
        required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {NotificationCenter.default.removeObserver(observer)};observer=nil
            guard let window else{return}
            observer=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:window,queue:.main){[weak self] _ in self?.onKey()}
            if window.isKeyWindow {DispatchQueue.main.async{[weak self] in self?.onKey()}}
        }
        deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
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
                    }.font(.system(size:12)).foregroundStyle(palette.muted)
                    if task.conflicted {Label("待核对",systemImage:"exclamationmark.triangle").font(.system(size:11)).foregroundStyle(palette.warning)}
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(task.conflicted || task.softDeleted).help("编辑任务").accessibilityLabel("\(service.number(for:task))、\(task.title)")
            HStack(spacing:4) {
                if task.softDeleted || task.status == "doing" || task.status == "waiting" || task.status == "cancelled" {statusPill}
                Menu {
                    if task.softDeleted {
                        Button("恢复"){Task{await service.restore(task)}}
                        Button("彻底删除",role:.destructive){service.destructiveAction = .purgeTask(task)}
                    } else if !task.completed {
                        // The common fixes for an overdue or stalled task, without opening the editor.
                        Button("推迟到明天"){Task{await service.postpone(task)}}
                        Button("推迟到下周一"){Task{await service.postpone(task,toNextMonday:true)}}
                        Menu("状态") {
                            ForEach([("todo","待办"),("doing","进行中"),("waiting","等待")],id:\.0){status,title in
                                Button {Task{await service.setStatus(task,status)}} label:{Label(title,systemImage:task.status == status ? "checkmark" : "circle")}.disabled(task.status == status)
                            }
                        }
                        Menu("移到分组") {
                            ForEach(service.groups.filter{$0 != task.group}){group in Button(group.title){Task{await service.move(task,to:group)}}}
                        }
                        Divider()
                        Button("编辑任务…"){service.beginEdit(task)}
                        Button("移入回收站",role:.destructive){service.destructiveAction = .deleteTask(task)}
                    } else {
                        Button("编辑任务…"){service.beginEdit(task)}
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
            // Just changed (by click, menu, AI or WeChat): a short accent ring shows which row.
            .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(palette.accent.opacity(service.highlightedTaskID == task.id ? 0.75 : 0),lineWidth:2))
            .animation(reduceMotion ? nil : .easeOut(duration:0.35),value:service.highlightedTaskID == task.id)
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
                .font(.system(size:12,weight:urgent ? .semibold : .regular)).foregroundStyle(tone).lineLimit(1)
                .padding(.horizontal,urgent ? 7 : 0).padding(.vertical,urgent ? 2 : 0)
                .background(urgent ? tone.opacity(0.10) : .clear,in:Capsule())
                .help(date.formatted(.dateTime.year().month().day().hour().minute()))
        }
        HStack(spacing:5) {
            Circle().fill(palette.tag(task.group.rawValue)).frame(width:6,height:6)
            Text(task.group.title).lineLimit(1)
        }
        Text("#\(service.number(for:task))").font(.system(size:11,design:.monospaced)).foregroundStyle(palette.muted.opacity(0.8))
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

final class SettingsDisclosure:ObservableObject {@Published var advanced=false}
struct SettingsView:View {
    @ObservedObject var service:TaskService
    @ObservedObject private var appearance=AppearanceStore.shared
    @StateObject private var disclosure=SettingsDisclosure()
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    @Environment(\.dismiss) private var dismiss
    private let tabs:[(id:String,title:String,symbol:String)]=[("general","通用","gearshape"),("ai","AI 模型","cpu"),("sync","同步与备份","arrow.triangle.2.circlepath"),("wechat","微信","bubble.left.and.bubble.right"),("update","更新","arrow.down.circle")]
    var body:some View {
        GlassFamily { VStack(spacing:0) {
            HStack {
                Text("设置").font(.system(size:21,weight:.semibold))
                Spacer();Button("完成"){finish()}.buttonStyle(ConsoleButton(prominent:true)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal,22).padding(.top,20).padding(.bottom,12)
            HStack(spacing:2) {
                ForEach(tabs,id:\.id){tab in
                    let selected=service.settingsTab == tab.id
                    Button{service.settingsTab=tab.id}label:{
                        VStack(spacing:3){Image(systemName:tab.symbol).font(.system(size:14));Text(tab.title).font(.system(size:11,weight:selected ? .semibold : .regular))}
                            .foregroundStyle(selected ? palette.accent : palette.muted).frame(maxWidth:.infinity).padding(.vertical,7)
                            .background(selected ? palette.selection : .clear,in:RoundedRectangle(cornerRadius:10)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(4).themeGlass(radius:14).padding(.horizontal,22).padding(.bottom,14)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    switch service.settingsTab {
                    case "ai":aiTab
                    case "sync":syncTab
                    case "wechat":wechatTab
                    case "update":UpdateSettingsSection(service:service)
                    default:generalTab
                    }
                    if !service.settingsNotice.isEmpty {Text(service.settingsNotice).font(.system(size:12)).foregroundStyle(palette.warning).textSelection(.enabled)}
                }.padding(.horizontal,22).padding(.bottom,22)
            }.scrollIndicators(.never)
        }}.frame(width:510,height:610).themeScope(appearance.selected)
        // Closing by Esc or the window button keeps edits too; toggles already apply instantly.
        .onDisappear{persist()}
        .alert("恢复备份？",isPresented:$service.backupRestorePresented) {
            Button("取消",role:.cancel){service.proposedBackup=nil}
            Button("恢复"){Task{await service.confirmBackupRestore()}}
        } message: {
            Text("将合并 \(service.proposedBackup?.snapshots.count ?? 0) 项任务及 \(service.proposedBackup?.trash.count ?? 0) 项回收记录；已有系统任务内容保留。会先保存本机安全副本，恢复期间暂停任务修改。")
        }
    }
    private var generalTab:some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:13) {
                sectionTitle("外观",symbol:"paintpalette")
                HStack(spacing:12){ForEach(AppTheme.allCases){choice in ThemeOption(choice:choice,appearance:appearance)}}
            }.padding(18).consoleCard()
            VStack(alignment:.leading,spacing:12) {
                sectionTitle("使用习惯",symbol:"hand.tap")
                switchRow("每天首次打开时，AI 整理今日待办",$service.dailyBriefingEnabled)
                note("显示在输入框下方，也会记入对话。使用云端模型时，会把相关任务的标题、截止时间、状态和分组发给所选服务。")
                switchRow("全局快捷键 \(GlobalHotKey.display) 快速记录",$service.hotKeyEnabled)
                note("在任何 App 中按下，打开记事喵并定位到输入框。")
                switchRow("菜单栏显示逾期与今天到期的数量",$service.menuBadgeEnabled)
                switchRow("开机自启动",Binding(get:{service.loginEnabled},set:{service.setLogin($0)}))
                if !service.loginNotice.isEmpty {note(service.loginNotice)}
            }.padding(18).consoleCard()
            VStack(alignment:.leading,spacing:12) {
                sectionTitle("到期通知",symbol:"bell.badge")
                note("到期任务由系统提醒事项通知；已同步到 iPhone 的任务，Mac 关机后也会提醒。")
                switchRow("另外用 Bark 推送到手机",$service.barkPreferences.enabled)
                if service.barkPreferences.enabled {
                    field("Bark 服务地址",text:$service.barkPreferences.baseURL)
                    SecureField("Device Key（留空保留已有配置）",text:$service.barkKeyDraft).textFieldStyle(.roundedBorder)
                    HStack{Button("发送测试通知"){Task{await service.testBark()}}.buttonStyle(ConsoleButton());Text(service.barkNotice).font(.system(size:11)).foregroundStyle(palette.muted)}
                    note("只在记事喵运行且 Mac 唤醒时检查，可能与系统通知同时到达。")
                }
            }.padding(18).consoleCard()
        }
    }
    private var aiTab:some View {
        VStack(alignment:.leading,spacing:14) {
            sectionTitle("模型配置",symbol:"cpu")
            HStack {
                Picker("当前使用",selection:Binding(get:{service.preferences.selectedProfileID ?? ""},set:{service.selectModel($0)})) {
                    ForEach(service.preferences.profiles ?? []){profile in Text(profile.name).tag(profile.id)}
                }
                Button("新增"){service.addProfile()}.buttonStyle(ConsoleButton())
                Button("移除"){service.removeProfile()}.buttonStyle(ConsoleButton()).disabled((service.preferences.profiles?.count ?? 0)<=1)
            }.disabled(service.uiBusy)
            field("配置名称",text:$service.profileNameDraft)
            Picker("模型来源",selection:$service.preferences.provider){Text("云端 · OpenAI 兼容").tag("cloud");Text("本地 · Ollama / 兼容服务").tag("local")}
            if service.preferences.provider == "cloud" {
                field("服务地址",text:$service.preferences.cloudURL)
                field("模型 ID",text:$service.preferences.cloudModel)
            } else {
                field("服务地址",text:$service.preferences.localURL)
                field("模型 ID",text:$service.preferences.localModel)
            }
            VStack(alignment:.leading,spacing:6) {
                HStack{Text("API Key").font(.system(size:11)).foregroundStyle(palette.muted);Spacer();Text(service.savedKeyHint ?? "尚未保存 Key").font(.system(size:11,design:.monospaced)).foregroundStyle(service.savedKeyHint == nil ? palette.warning : palette.success)}
                SecureField(service.savedKeyHint == nil ? "填写 Key" : "留空保留已保存的 Key",text:$service.keyDraft).textFieldStyle(.plain).padding(11).background(palette.field,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.contentEdge))
            }
            HStack {
                Button("保存此配置"){do{try service.saveProfile()}catch{service.settingsNotice=error.localizedDescription}}.buttonStyle(ConsoleButton(prominent:true))
                Button("测试连接"){Task{await service.testModel()}}.buttonStyle(ConsoleButton())
                Text(service.modelTestNotice).font(.system(size:11)).foregroundStyle(service.modelTestNotice.hasPrefix("连接成功") ? palette.success : palette.muted).lineLimit(2)
            }.disabled(service.uiBusy)
            switchRow("每次修改任务都先让我确认",$service.preferences.confirmAll)
            note("默认只在拿不准时确认：没说清是哪件任务、日期说得含糊，或要改动分组。")
            note("Key 只保存在这台 Mac 的应用配置目录，不进入备份或同步。使用云端模型时，会发送你的输入、近期操作和最多 100 项相关任务的标题、状态与分组；不发送备注。不配置模型也可以手动管理任务。")
        }.padding(18).consoleCard()
    }
    private var syncTab:some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:12) {
                sectionTitle("提醒事项账户",symbol:"checklist")
                if !service.sourceChoices.isEmpty {
                    Picker("账户",selection:Binding(get:{service.preferences.sourceIdentifier ?? ""},set:{service.preferences.sourceIdentifier=$0})) {
                        ForEach(service.sourceChoices,id:\.id){choice in Text(choice.title).tag(choice.id)}
                    }
                    Button("重新连接所选账户"){Task{await service.connect()}}.buttonStyle(ConsoleButton())
                } else {
                    Button("授权并连接"){Task{await service.connect()}}.buttonStyle(ConsoleButton(prominent:true))
                }
                note("选 iCloud 账户后，任务会同步到 iPhone 的提醒事项。")
            }.padding(18).consoleCard()
            VStack(alignment:.leading,spacing:12) {
                sectionTitle("两台 Mac 同步",symbol:"macbook.and.iphone")
                Text(service.syncNote).font(.system(size:12)).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)
                if !service.metadataSyncEnabled {
                    HStack {
                        Button("在这台 Mac 上开启"){Task{await service.configureMetadataSync(create:true)}}
                        Button("加入另一台 Mac"){Task{await service.configureMetadataSync(create:false)}}
                    }.buttonStyle(ConsoleButton()).disabled(service.uiBusy || !service.isConnected)
                    note("在常用的那台先点「开启」，另一台再点「加入」。任务状态、进度、编号和回收站经你自己的 iCloud Drive 同步，Key 不同步。")
                }
            }.padding(18).consoleCard()
            VStack(alignment:.leading,spacing:12) {
                sectionTitle("备份与恢复",symbol:"externaldrive")
                HStack {
                    Button("导出备份"){Task{await service.exportBackup()}}
                    Button("从备份恢复"){service.chooseBackup()}
                }.buttonStyle(ConsoleButton()).disabled(service.uiBusy || !service.isConnected || service.restorePending)
                if service.restorePending {Button("继续未完成的恢复"){Task{await service.continueBackupRestore()}}.buttonStyle(ConsoleButton(prominent:true)).disabled(service.uiBusy)}
                note("备份包含全部任务与本机记录，不含 Key 或微信会话；请妥善保存。")
                if !service.dataNotice.isEmpty {Text(service.dataNotice).font(.system(size:12)).foregroundStyle(palette.accent).textSelection(.enabled)}
                DisclosureGroup("高级修复",isExpanded:$disclosure.advanced) {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {
                            Button("同步旧版回收站"){Task{await service.repairLegacyTrash()}}
                            Button("补齐到期提醒"){Task{await service.repairFutureAlarms()}}
                        }.buttonStyle(ConsoleButton()).disabled(service.uiBusy || !service.isConnected || service.restorePending)
                        note("仅在遇到问题时使用。前者先保存恢复快照，再移除系统中对应的旧提醒；后者只为未来到期、尚无闹钟的未完成任务补上提醒。")
                    }.padding(.top,8)
                }.font(.system(size:12)).foregroundStyle(palette.muted)
            }.padding(18).consoleCard()
        }
    }
    private var wechatTab:some View {
        VStack(alignment:.leading,spacing:13) {
            HStack{sectionTitle("微信随手记",symbol:"bubble.left.and.bubble.right");Spacer();Text(service.wechatLabel).font(.system(size:11)).foregroundStyle(service.wechatState == "connected" ? palette.success : palette.accent)}
            note("连接后，在微信里给记事喵发一句话就能记下待办，也能查询、改时间、标完成；语音消息同样可以。带时间的指令会先让你核对。需要这台 Mac 上的记事喵保持运行。")
            switchRow("其他设备上的微信连接已停止",$service.oldOwnerStopped)
            note("同一个微信只能连接一台 Mac。")
            HStack {
                Button(service.wechatState == "stopped" ? "连接微信" : "重新连接"){
                    let relogin=service.wechatState != "stopped" && service.wechatState != "connected"
                    service.stopWeChat(preserveAutoConnect:true);service.startWeChat(forceLogin:relogin)
                }.buttonStyle(ConsoleButton(prominent:true)).disabled(!service.oldOwnerStopped || service.wechatState == "connected")
                Button("断开"){service.stopWeChat()}.buttonStyle(ConsoleButton()).disabled(service.wechatState == "stopped")
            }
            if let image=service.wechatQRCode {
                Image(nsImage:image).interpolation(.none).resizable().scaledToFit().frame(width:180,height:180).padding(12).background(.white,in:RoundedRectangle(cornerRadius:12)).frame(maxWidth:.infinity)
                Text(service.wechatState == "scanned" ? "已扫码，请在手机上确认。" : "用手机微信扫码，连接这台 Mac。").font(.system(size:12)).foregroundStyle(palette.muted).frame(maxWidth:.infinity)
            }
            if service.wechatState == "need_verifycode" {
                HStack {
                    TextField("手机微信上显示的数字",text:$service.wechatVerifyCode).textFieldStyle(.roundedBorder).onSubmit{service.submitWeChatVerifyCode()}
                    Button("确认"){service.submitWeChatVerifyCode()}.buttonStyle(ConsoleButton(prominent:true))
                }
            }
        }.padding(18).consoleCard()
    }
    private func sectionTitle(_ title:String,symbol:String)->some View {Label(title,systemImage:symbol).font(.system(size:14,weight:.semibold)).foregroundStyle(palette.accent)}
    /// Label left, switch right-aligned, so the switches line up in one column.
    private func switchRow(_ title:String,_ isOn:Binding<Bool>)->some View {
        HStack{Text(title).font(.system(size:13));Spacer(minLength:12);Toggle(title,isOn:isOn).labelsHidden().toggleStyle(.switch)}
    }
    private func note(_ text:String)->some View {Text(text).font(.system(size:11)).lineSpacing(2).foregroundStyle(palette.muted).fixedSize(horizontal:false,vertical:true)}
    private func field(_ title:String,text:Binding<String>)->some View {
        VStack(alignment:.leading,spacing:6){Text(title).font(.system(size:11)).foregroundStyle(palette.muted);TextField(title,text:text).textFieldStyle(.plain).font(.system(size:12,design:.monospaced)).padding(11).background(palette.field,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.contentEdge))}
    }
    /// Saves model fields as a profile when complete; otherwise only the general preferences.
    @discardableResult private func persist()->Bool {
        do {
            if service.preferences.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {try service.savePreferences()}
            else {try service.saveProfile()}
            return true
        } catch {service.settingsNotice=error.localizedDescription;return false}
    }
    private func finish() {if persist() {dismiss()}}
}

struct TaskEditorView:View {
    @ObservedObject var service:TaskService
    @ObservedObject private var appearance=AppearanceStore.shared
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    var body:some View {
        GlassFamily { VStack(alignment:.leading,spacing:16) {
            HStack {Text("编辑任务").font(.system(size:17,weight:.semibold));Spacer();Button("取消"){service.editorPresented=false}.buttonStyle(ConsoleButton());Button("保存"){Task{await service.saveEdit()}}.buttonStyle(ConsoleButton(prominent:true)).disabled(service.uiBusy)}
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
            HStack{TextField("新分组名称",text:$service.groupDraft).textFieldStyle(.roundedBorder).onSubmit{Task{await service.createGroup()}};Button("创建"){Task{await service.createGroup()}}.buttonStyle(ConsoleButton()).disabled(service.uiBusy || service.groupDraft.trimmingCharacters(in:.whitespaces).isEmpty)}
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
                        }.font(.system(size:12)).padding(10).consoleCard(radius:10).disabled(service.uiBusy)
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
