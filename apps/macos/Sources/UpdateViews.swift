import SwiftUI

struct UpdateSettingsSection:View {
    @ObservedObject var service:TaskService
    @ObservedObject private var updates=UpdateService.shared
    @ObservedObject private var appearance=AppearanceStore.shared
    private var palette:ThemePalette {ThemePalette(theme:appearance.selected)}
    var body:some View {
        VStack(alignment:.leading,spacing:13) {
            HStack {
                Label("软件更新",systemImage:"arrow.down.circle").font(.system(size:13,weight:.semibold)).foregroundStyle(palette.accent)
                Spacer()
                Text("当前 \(updates.currentVersion)（\(updates.currentBuild)）").font(.system(size:10,design:.monospaced)).foregroundStyle(palette.muted)
            }
            status
            if let c=updates.candidate {
                let notes=UpdateRules.summary(c.notes)
                if !notes.isEmpty {
                    Text(notes).font(.system(size:11)).lineSpacing(3).foregroundStyle(palette.muted).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading).padding(11)
                        .background(palette.field,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(palette.contentEdge))
                }
                if let page=c.page {Link("查看完整版本说明 ↗",destination:page).font(.system(size:11))}
            }
            HStack {actions;Spacer()}
            Toggle("每天自动检查一次",isOn:$updates.autoCheck).toggleStyle(.switch)
            Text("只向 GitHub Releases 查询版本信息，不发送任务内容。发现新版本会弹窗询问，确认后才安装；安装前校验 SHA-256、代码签名与应用标识，旧版本保留在本机应用数据目录。").font(.system(size:10)).foregroundStyle(palette.muted)
        }.padding(18).consoleCard()
    }
    @ViewBuilder private var status:some View {
        switch updates.phase {
        case .idle:
            Text(updates.lastCheck.map{"上次检查：\($0.formatted(date:.abbreviated,time:.shortened))"} ?? "尚未检查更新").font(.system(size:12)).foregroundStyle(palette.muted)
        case .checking:
            HStack(spacing:8){ProgressView().controlSize(.small);Text("正在检查…")}.font(.system(size:12))
        case .upToDate(let date):
            Label("已是最新版本 · \(date.formatted(date:.omitted,time:.shortened)) 检查",systemImage:"checkmark.circle").font(.system(size:12)).foregroundStyle(palette.success)
        case .available(let c):
            Label("发现新版本 \(c.version.description)",systemImage:"sparkles").font(.system(size:12,weight:.semibold)).foregroundStyle(palette.accent)
        case .downloading(let c):
            HStack(spacing:8){ProgressView().controlSize(.small);Text("正在下载并校验 \(c.version.description)…")}.font(.system(size:12))
        case .ready(let c):
            Label("\(c.version.description) 已下载并通过校验，重启即可完成更新",systemImage:"checkmark.seal").font(.system(size:12,weight:.medium)).foregroundStyle(palette.success)
        case .installing:
            HStack(spacing:8){ProgressView().controlSize(.small);Text("正在重启并安装…")}.font(.system(size:12))
        case .failed(let message):
            Label(message,systemImage:"exclamationmark.triangle").font(.system(size:11)).foregroundStyle(palette.warning).textSelection(.enabled)
        }
    }
    @ViewBuilder private var actions:some View {
        switch updates.phase {
        case .available(let c),.ready(let c):
            Button("安装 \(c.version.description)…"){openUpdateDialog()}.buttonStyle(ConsoleButton(prominent:true))
        case .checking,.downloading,.installing:
            Button("检查更新"){}.buttonStyle(ConsoleButton()).disabled(true)
        default:
            Button("检查更新"){openUpdateDialog()}.buttonStyle(ConsoleButton())
        }
    }
    // The dialog takes over from here; closing this sheet first keeps quit-and-relaunch unblocked.
    private func openUpdateDialog() {
        service.settingsPresented=false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4){updates.checkInteractively()}
    }
}
