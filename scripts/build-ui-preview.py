"""Build an isolated, read-only visual fixture using the real SwiftUI views.

Not a production or EventKit test. This bundle never initializes application
storage, IPC, EventKit authorization, credentials, networking or schedulers.
All view hit testing is disabled. Arguments choose synthetic display states.
"""
from pathlib import Path
import subprocess,plistlib,platform
root=Path(__file__).resolve().parents[1]
work=root/'.build/reference-preview';work.mkdir(parents=True,exist_ok=True)
service=(root/'apps/macos/Sources/TaskService.swift').read_text()
a=service.index('    init() {');b=service.index('    var visibleTasks:',a)
fixture=r'''    init() {
        let args=CommandLine.arguments
        preferences.migrateProfiles();preferences.activateProfile("legacy-local")
        isConnected=true;wechatState="connected";composerCollapsed=args.contains("--collapsed")
        groups=[.inbox,TaskGroup(rawValue:"示例项目")!,TaskGroup(rawValue:"用于检查超长名称的合成测试分组")!]
        let f=ISO8601DateFormatter();let date=f.date(from:"2026-10-25T12:00:00Z")!
        func item(_ id:String,_ title:String,_ status:String,_ progress:Int?=nil,_ deleted:Bool=false,_ archived:Bool=false)->ManagedTask {
            ManagedTask(id:id,title:title,notes:"仅供视觉检查，不是用户任务",group:groups[1],status:status,progress:progress,dueAt:date.addingTimeInterval(Double(Int(id.split(separator:"-").last!)!)*3600),completed:status=="done",softDeleted:deleted,archived:archived,conflicted:false)
        }
        tasks=[item("fixture-1","整理产品方案","doing",50),item("fixture-2","联调通知流程","waiting"),item("fixture-3","准备本周工作回顾与演示材料，检查超长中文标题在窄窗口中是否完整换行","todo"),item("fixture-4","核对发布清单","todo"),item("fixture-5","补充使用说明","todo"),item("fixture-6","已完成的合成任务","done",100),item("fixture-7","回收站中的合成任务","todo",nil,true),item("fixture-8","隐藏的归档合成任务","todo",nil,false,true)]
        taskNumbers.assign(tasks)
        feedback=[FeedbackItem(input:"合成查询：本周任务",output:"共 1 项\n\n1、整理产品方案\n   进行中 · 示例项目\n\n回复「任务编号 + 操作」，如：任务5标记完成。",isError:false)]
        if args.contains("--feedback") {selectedTab="feedback"}
        if args.contains("--trash") {showTrash=true}
        if args.contains("--completed") {taskLens = .completed}
        if args.contains("--group") {selectedGroup=groups[2].rawValue}
        if args.contains("--thinking") {busy=true;processingStage="正在思考 · 分析任务、分组与日期";processingInput="合成视觉状态：不调用任何模型"}
        if args.contains("--confirmation") {
            var record=RequestRecord(id:"fixture-confirmation",source:"fixture",text:"合成操作：进度100%",createdAt:"")
            record.phase="awaiting_confirmation";record.confirmationNumber=1
            record.command=TaskCommand(operationId:record.id,intent:"update_task",taskId:tasks[0].id,patch:["progress":.number(100),"status":.text("done")],dateText:nil,requiresConfirmation:true)
            pending=record;selectedTab="pending"
        }
    }
'''
(work/'TaskService.swift').write_text(service[:a]+fixture+service[b:])
(work/'PreviewMain.swift').write_text(r'''import SwiftUI
import AppKit
@MainActor final class PreviewDelegate:NSObject,NSApplicationDelegate {
 var window:NSWindow!
 func applicationDidFinishLaunching(_ note:Notification) {
  AppearanceStore.shared.selected=CommandLine.arguments.contains("--dark") ? .midnight : .liquidGlass
  let service=TaskService();let compact=CommandLine.arguments.contains("--compact")
  let w=NSWindow(contentRect:NSRect(x:0,y:0,width:compact ? 520 : 540,height:660),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
  w.title="TaskCat UI Preview · 合成数据 · 只读";w.titlebarAppearsTransparent=true
  w.appearance=NSAppearance(named:CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
  w.isOpaque=false;w.backgroundColor = .clear;w.isReleasedWhenClosed=false
  w.contentView=NSHostingView(rootView:HousekeeperView(service:service,isPopover:compact,openWindow:{}).allowsHitTesting(false))
  w.center();window=w;w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
  let menu=NSMenu();let item=NSMenuItem();let sub=NSMenu();sub.addItem(withTitle:"退出视觉预览",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=sub;menu.addItem(item);NSApp.mainMenu=menu
 }
}
@main struct PreviewMain {
 @MainActor static func main(){let app=NSApplication.shared;let delegate=PreviewDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()}
}
''')
app=root/'dist/TaskCatUIPreview.app';(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.taskcat.visual-preview','CFBundleName':'TaskCatUIPreview','CFBundleDisplayName':'TaskCat UI Preview','CFBundleExecutable':'UIPreview','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}))
sources=[p for p in sorted((root/'apps/macos/Sources').glob('*.swift')) if p.name not in ['AppMain.swift','TaskService.swift']]
subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-target',platform.machine()+'-apple-macosx14.0',str(root/'poc/metadata-journal/OperationJournal.swift'),*[str(p) for p in sources],str(work/'TaskService.swift'),str(work/'PreviewMain.swift'),'-o',str(app/'Contents/MacOS/UIPreview')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print('Read-only synthetic UI preview built; no production state or permission paths initialized')
