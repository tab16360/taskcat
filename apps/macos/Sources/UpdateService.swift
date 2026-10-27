import Foundation
import AppKit
import CryptoKit
import Combine

struct UpdateError:LocalizedError {
    let message:String
    init(_ message:String) {self.message=message}
    var errorDescription:String? {message}
}

// Checks GitHub Releases, verifies and stages a build, then hands the swap to a
// helper script that runs after this process exits. Nothing installs without a click.
@MainActor
final class UpdateService:ObservableObject {
    enum Phase:Equatable {case idle,checking,upToDate(Date),available(UpdateCandidate),downloading(UpdateCandidate),ready(UpdateCandidate),installing,failed(String)}
    enum Keys {static let autoCheck="TaskSecretary.update.autoCheck";static let lastCheck="TaskSecretary.update.lastCheck";static let postponed="TaskSecretary.update.postponedTag"}
    static let shared=UpdateService()
    @Published private(set) var phase:Phase = .idle
    @Published var autoCheck:Bool {didSet{defaults.set(autoCheck,forKey:Keys.autoCheck);schedule()}}
    let currentVersion:String
    let currentBuild:String
    private let defaults:UserDefaults
    private var staged:URL?
    private var timer:Timer?
    private var helper:Process?
    private var downloadTask:Task<Void,Never>?
    private var prompting=false
    private var progressPanel:NSPanel?
    private var progressLabel:NSTextField?
    private var cancelButton:NSButton?
    /// Set by the app: a task write in progress; install waits for it to finish.
    var isBusy:()->Bool = {false}
    /// Set by the app: a lasting state that rules out updating, e.g. an unfinished backup restore.
    var blocker:()->String? = {nil}
    init(defaults:UserDefaults = .standard,bundle:Bundle = .main) {
        self.defaults=defaults
        autoCheck=defaults.object(forKey:Keys.autoCheck) as? Bool ?? true
        currentVersion=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0"
        currentBuild=bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "0"
    }
    var candidate:UpdateCandidate? {
        switch phase {case .available(let c),.downloading(let c),.ready(let c):return c;default:return nil}
    }
    var lastCheck:Date? {defaults.object(forKey:Keys.lastCheck) as? Date}
    func start() {
        // A staged build left by a cancelled or interrupted update is never reused.
        let parent=Bundle.main.bundleURL.deletingLastPathComponent()
        for item in (try? FileManager.default.contentsOfDirectory(atPath:parent.path)) ?? [] where item.hasPrefix(".TaskCat-update-") && item.hasSuffix(".app") {
            try? FileManager.default.removeItem(at:parent.appendingPathComponent(item))
        }
        schedule()
    }
    private func schedule() {
        timer?.invalidate();timer=nil
        guard autoCheck else{return}
        timer=Timer.scheduledTimer(withTimeInterval:3600,repeats:true){[weak self] _ in Task{@MainActor in self?.checkIfDue()}}
        DispatchQueue.main.asyncAfter(deadline:.now()+20){[weak self] in self?.checkIfDue()}
    }
    private func checkIfDue() {
        guard autoCheck,UpdateRules.checkDue(lastCheck:lastCheck,now:Date()) else{return}
        Task {
            await check(userInitiated:false)
            // A background find pops up once per version; "稍后" keeps only the settings dot.
            if case .available(let c)=phase,defaults.string(forKey:Keys.postponed) != c.tag {prompt(c)}
        }
    }
    /// Menu, settings and background checks all end in the same native dialogs.
    func checkInteractively() {
        Task {
            if candidate == nil {await check(userInitiated:true)}
            switch phase {
            case .available(let c),.ready(let c):prompt(c)
            case .upToDate:message("已是最新版本","当前版本：\(currentVersion)")
            case .failed(let text):message("无法检查更新",text)
            default:break
            }
        }
    }
    func check(userInitiated:Bool=true) async {
        switch phase {case .checking,.downloading,.ready,.installing:return;default:break}
        let previous=phase;phase = .checking
        do {
            guard let current=AppVersion(currentVersion) else{throw UpdateError("当前版本号无法识别")}
            var request=URLRequest(url:UpdateRules.feed,timeoutInterval:20)
            request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
            request.setValue("TaskCat/\(currentVersion)",forHTTPHeaderField:"User-Agent")
            let (data,response)=try await URLSession(configuration:.ephemeral).data(for:request)
            let status=(response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else{throw UpdateError(status == 403 ? "GitHub 暂时限制了访问频率，请稍后再试" : "GitHub 返回 \(status)")}
            let releases=try JSONDecoder().decode([ReleaseFeedItem].self,from:data)
            defaults.set(Date(),forKey:Keys.lastCheck)
            phase=UpdateRules.pick(releases,current:current,arch:UpdateRules.architecture).map{.available($0)} ?? .upToDate(Date())
        } catch {
            // Background checks fail quietly; a click always reports why.
            phase=userInitiated ? .failed("检查失败：\(error.localizedDescription)") : (previous == .checking ? .idle : previous)
        }
    }
    func download() async {
        guard case .available(let c)=phase else{return}
        phase = .downloading(c)
        do {
            let result=try await Self.prepare(c,target:Bundle.main.bundleURL,currentVersion:currentVersion,currentBuild:currentBuild)
            // Verification and staging run as plain processes and ignore cancellation; honour it here.
            if Task.isCancelled {try? FileManager.default.removeItem(at:result);phase = .available(c);return}
            staged=result;phase = .ready(c)
        } catch {
            phase=Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled ? .available(c) : .failed(error.localizedDescription)
        }
    }
    private func prompt(_ c:UpdateCandidate) {
        guard !prompting,downloadTask == nil else{return}
        prompting=true;defer{prompting=false}
        NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert()
        alert.messageText="记事喵 \(c.version.description) 可更新"
        let notes=String(UpdateRules.summary(c.notes,lines:12).prefix(800))
        alert.informativeText="当前版本：\(currentVersion)\n\n\(notes)\n\n自动下载并校验安装包，替换应用后重新启动。任务和设置都会保留。"
        alert.addButton(withTitle:"安装并重启");alert.addButton(withTitle:"稍后")
        guard alert.runModal() == .alertFirstButtonReturn else {defaults.set(c.tag,forKey:Keys.postponed);return}
        defaults.removeObject(forKey:Keys.postponed)
        if let reason=blocker() {message("暂时不能更新",reason);return}
        if case .ready=phase {install();return}
        showProgress("正在下载并校验 \(c.version.description)…")
        downloadTask=Task {
            await download()
            downloadTask=nil
            switch phase {
            case .ready:progressLabel?.stringValue="正在重新启动…";cancelButton?.isEnabled=false;install()
            case .failed(let text):closeProgress();message("无法完成更新",text)
            default:closeProgress()
            }
        }
    }
    func install(waited:Int=0) {
        guard case .ready(let candidate)=phase,let staged else{return}
        if let reason=blocker() {closeProgress();message("暂时不能更新",reason);return}
        if isBusy() {
            // Let the current task write finish, then quit; give up rather than spin forever.
            guard waited<30 else {closeProgress();message("暂时不能更新","记事喵正在处理任务，请稍后从菜单栏右键选择「检查更新…」重试。");return}
            DispatchQueue.main.asyncAfter(deadline:.now()+1){[weak self] in self?.install(waited:waited+1)};return
        }
        do {
            try AppPaths.prepare()
            guard let bundled=Bundle.main.url(forResource:"update-install",withExtension:"sh") else{throw UpdateError("安装脚本缺失，请重新下载完整安装包")}
            // Run a copy: the original lives inside the bundle that is about to move.
            let script=FileManager.default.temporaryDirectory.appendingPathComponent("taskcat-update-\(UUID().uuidString).sh")
            try FileManager.default.copyItem(at:bundled,to:script)
            let log=AppPaths.root.appendingPathComponent("update.log")
            if !FileManager.default.fileExists(atPath:log.path) {FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])}
            let output=try FileHandle(forWritingTo:log);try output.seekToEnd()
            let backup=AppPaths.root.appendingPathComponent("previous-build-\(UUID().uuidString).app")
            let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/bash")
            process.arguments=[script.path,String(ProcessInfo.processInfo.processIdentifier),Bundle.main.bundleURL.path,staged.path,backup.path]
            process.standardOutput=output;process.standardError=output
            try process.run()
            helper=process;phase = .installing
            // AppKit silently cancels termination while a window has a sheet attached.
            for window in NSApp.windows {if let sheet=window.attachedSheet {window.endSheet(sheet)}}
            DispatchQueue.main.async {NSApp.terminate(nil)}
            DispatchQueue.main.asyncAfter(deadline:.now()+4){[weak self] in self?.terminationStalled(candidate)}
        } catch {closeProgress();phase = .failed("无法开始安装：\(error.localizedDescription)");message("无法完成更新","无法开始安装：\(error.localizedDescription)")}
    }
    // Still running: the helper is only waiting for this process, so stop it and keep the staged build.
    private func terminationStalled(_ candidate:UpdateCandidate) {
        guard phase == .installing else{return}
        helper?.terminate();helper=nil
        phase = .ready(candidate);closeProgress()
        message("记事喵没能退出","可能还有窗口或弹窗未关闭。新版本已下载并校验，关闭后从菜单栏右键选择「检查更新…」即可继续安装。")
    }
    private func showProgress(_ text:String) {
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:420,height:150),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title="更新记事喵";panel.isReleasedWhenClosed=false;panel.level = .floating
        let label=NSTextField(wrappingLabelWithString:text);label.frame=NSRect(x:24,y:92,width:372,height:36)
        let bar=NSProgressIndicator(frame:NSRect(x:24,y:64,width:372,height:16));bar.style = .bar;bar.isIndeterminate=true;bar.startAnimation(nil)
        let cancel=NSButton(title:"取消",target:self,action:#selector(cancelDownload));cancel.bezelStyle = .rounded;cancel.frame=NSRect(x:308,y:16,width:88,height:30)
        [label,bar,cancel].forEach{panel.contentView?.addSubview($0)}
        panel.center();panel.makeKeyAndOrderFront(nil)
        progressPanel=panel;progressLabel=label;cancelButton=cancel
    }
    @objc private func cancelDownload() {downloadTask?.cancel();cancelButton?.isEnabled=false;progressLabel?.stringValue="正在取消…"}
    private func closeProgress() {progressPanel?.close();progressPanel=nil;progressLabel=nil;cancelButton=nil}
    private func message(_ title:String,_ text:String) {
        NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText=title;alert.informativeText=text;alert.addButton(withTitle:"好");alert.runModal()
    }

    // Everything below runs off the main actor: download, checksum, unpack, verify, stage.
    nonisolated private static func prepare(_ c:UpdateCandidate,target:URL,currentVersion:String,currentBuild:String) async throws->URL {
        let fm=FileManager.default,parent=target.deletingLastPathComponent()
        guard target.pathExtension == "app",!target.path.contains("/AppTranslocation/"),fm.isWritableFile(atPath:parent.path) else {
            throw UpdateError("请先把记事喵放进可写的「应用程序」目录后再更新")
        }
        let work=fm.temporaryDirectory.appendingPathComponent("TaskCatUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at:work,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:work)}
        let session=URLSession(configuration:.ephemeral)
        let (sumData,sumResponse)=try await session.data(from:c.checksum)
        guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected=UpdateRules.checksum(String(decoding:sumData,as:UTF8.self),archiveName:c.archiveName) else {throw UpdateError("校验文件无效，已停止更新")}
        let (downloaded,zipResponse)=try await session.download(from:c.archive)
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else{throw UpdateError("下载失败，请稍后重试")}
        let archive=work.appendingPathComponent(c.archiveName)
        try fm.moveItem(at:downloaded,to:archive)
        let actual=SHA256.hash(data:try Data(contentsOf:archive,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
        guard actual == expected else{throw UpdateError("安装包校验值不符，已删除下载内容")}
        let unpacked=work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto",["-x","-k",archive.path,unpacked.path],"解压失败")
        let apps=try fm.contentsOfDirectory(at:unpacked,includingPropertiesForKeys:nil).filter{$0.pathExtension == "app"}
        guard apps.count == 1,let app=apps.first else{throw UpdateError("安装包内容不符合预期")}
        guard let info=NSDictionary(contentsOf:app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {throw UpdateError("安装包不是记事喵，已停止更新")}
        let newVersion=AppVersion(info["CFBundleShortVersionString"] as? String ?? ""),oldVersion=AppVersion(currentVersion)
        let newBuild=Int(info["CFBundleVersion"] as? String ?? "") ?? 0,oldBuild=Int(currentBuild) ?? 0
        guard let newVersion,let oldVersion,newVersion>oldVersion || (newVersion == oldVersion && newBuild>oldBuild) else {
            throw UpdateError("安装包版本不高于当前版本，已停止更新")
        }
        try run("/usr/bin/codesign",["--verify","--strict","--deep",app.path],"安装包签名校验失败")
        // A Developer ID build only accepts updates signed by the same team.
        if let team=teamIdentifier(target),team != teamIdentifier(app) {throw UpdateError("安装包签名身份与当前版本不一致")}
        let staged=parent.appendingPathComponent(".TaskCat-update-\(UUID().uuidString).app")
        try run("/usr/bin/ditto",[app.path,staged.path],"无法暂存新版本")
        do {try run("/usr/bin/codesign",["--verify","--strict","--deep",staged.path],"暂存版本签名校验失败")}
        catch {try? fm.removeItem(at:staged);throw error}
        return staged
    }
    nonisolated private static func run(_ tool:String,_ arguments:[String],_ failure:String) throws {
        let process=Process();process.executableURL=URL(fileURLWithPath:tool);process.arguments=arguments
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        guard process.terminationStatus == 0 else{throw UpdateError(failure)}
    }
    nonisolated private static func teamIdentifier(_ app:URL)->String? {
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/codesign")
        process.arguments=["-dv","--verbose=2",app.path];process.standardError=pipe;process.standardOutput=FileHandle.nullDevice
        guard (try? process.run()) != nil else{return nil}
        let text=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);process.waitUntilExit()
        return text.split(whereSeparator:\.isNewline).first{$0.hasPrefix("TeamIdentifier=")}
            .map{String($0.dropFirst("TeamIdentifier=".count))}.flatMap{$0 == "not set" ? nil : $0}
    }
}
