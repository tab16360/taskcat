import AppKit
import SwiftUI
import Combine
import Carbon

@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate {
    var statusItem:NSStatusItem!
    var popover:NSPopover!
    var window:NSWindow?
    var service:TaskService!
    var appearanceObserver:AnyCancellable?
    func applicationDidFinishLaunching(_ notification:Notification) {
        service=TaskService()
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        if let button=statusItem.button {
            let image=NSImage(size:NSSize(width:24,height:24),flipped:false){rect in
                NSColor(calibratedRed:0.06,green:0.09,blue:0.16,alpha:1).setFill();NSBezierPath(ovalIn:rect.insetBy(dx:1,dy:1)).fill()
                NSColor.systemBlue.withAlphaComponent(0.8).setStroke();let rim=NSBezierPath(ovalIn:rect.insetBy(dx:1,dy:1));rim.lineWidth=1;rim.stroke()
                let label=NSAttributedString(string:"AI",attributes:[.font:NSFont.systemFont(ofSize:10,weight:.semibold),.foregroundColor:NSColor.white]);let size=label.size();label.draw(at:NSPoint(x:(24-size.width)/2,y:(24-size.height)/2));return true
            }
            let mark=Bundle.main.url(forResource:"TaskCatMark",withExtension:"png").flatMap{NSImage(contentsOf:$0)} ?? image
            mark.size=NSSize(width:24,height:24);mark.accessibilityDescription="记事喵";mark.isTemplate=false;button.image=mark;button.toolTip="记事喵 · 查看任务或一句话安排"
            button.target=self;button.action=#selector(statusItemActivated)
            button.sendAction(on:[.leftMouseUp,.rightMouseUp])
        }
        popover=NSPopover();popover.behavior = .transient;popover.contentSize=NSSize(width:520,height:620)
        popover.appearance=NSAppearance(named:AppearanceStore.shared.selected == .liquidGlass ? .aqua : .darkAqua)
        popover.contentViewController=NSHostingController(rootView:HousekeeperView(service:service,isPopover:true,openWindow:{[weak self] in self?.openMainWindow()}))
        let menu=NSMenu();let appMenu=NSMenuItem();menu.addItem(appMenu)
        let submenu=NSMenu()
        let showPanel=submenu.addItem(withTitle:"显示菜单栏面板",action:#selector(togglePopover),keyEquivalent:"");showPanel.target=self
        submenu.addItem(.separator())
        submenu.addItem(withTitle:"退出记事喵",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appMenu.submenu=submenu
        let editItem=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"");let edit=NSMenu(title:"编辑")
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z")
        edit.addItem(.separator())
        edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        editItem.submenu=edit;menu.addItem(editItem)
        NSApp.mainMenu=menu
        appearanceObserver=AppearanceStore.shared.$selected.sink{[weak self] theme in
            let appearance=NSAppearance(named:theme == .liquidGlass ? .aqua : .darkAqua)
            self?.popover?.appearance=appearance;self?.window?.appearance=appearance
        }
        let loginLaunch=NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword:keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !CommandLine.arguments.contains("--background") && !loginLaunch { openMainWindow() }
        UpdateService.shared.isBusy={[weak self] in self?.service.busy == true || self?.service.restorePending == true}
        UpdateService.shared.start()
    }
    @objc func statusItemActivated() {
        let event=NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control)==true {
            showStatusMenu()
        } else {togglePopover()}
    }
    private func showStatusMenu() {
        guard let button=statusItem.button else{return}
        popover.performClose(nil)
        let menu=NSMenu()
        let show=menu.addItem(withTitle:"打开待办面板",action:#selector(openPopover),keyEquivalent:"");show.target=self
        let settings=menu.addItem(withTitle:"设置…",action:#selector(openSettings),keyEquivalent:"");settings.target=self
        let update=menu.addItem(withTitle:"检查更新…",action:#selector(checkForUpdates),keyEquivalent:"");update.target=self
        menu.addItem(.separator())
        let quit=menu.addItem(withTitle:"退出记事喵",action:#selector(quitTaskCat),keyEquivalent:"q");quit.target=self
        // Let the status item anchor the menu below the icon; a manual popUp point landed
        // above the menu bar, so macOS showed a scroll arrow before the full menu.
        statusItem.menu=menu;button.performClick(nil);statusItem.menu=nil
    }
    @objc func openPopover() {
        guard !popover.isShown,let button=statusItem.button else{return}
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        NSApp.activate(ignoringOtherApps:true)
    }
    @objc func openSettings() {
        DispatchQueue.main.async { [weak self] in
            guard let self else{return}
            self.openMainWindow();self.service.settingsPresented=true
        }
    }
    @objc func checkForUpdates() {UpdateService.shared.checkInteractively()}
    @objc func quitTaskCat() {NSApp.terminate(nil)}
    @objc func togglePopover() {
        if popover.isShown {popover.performClose(nil)}
        else {openPopover()}
    }
    func openMainWindow() {
        popover?.performClose(nil)
        if window==nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:660),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            w.title="记事喵";w.isReleasedWhenClosed=false;w.minSize=NSSize(width:520,height:500)
            w.appearance=NSAppearance(named:AppearanceStore.shared.selected == .liquidGlass ? .aqua : .darkAqua);w.titlebarAppearsTransparent=true;w.titleVisibility = .hidden
            w.isOpaque=false;w.backgroundColor = .clear;w.hasShadow=true
            w.contentView=NSHostingView(rootView:HousekeeperView(service:service,openWindow:{}));w.center();window=w
        }
        window!.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        if !flag {openMainWindow()};return true
    }
    func applicationWillTerminate(_ notification:Notification) { service?.stopWeChat(preserveAutoConnect:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
}

@main
struct TaskCatMain {
    @MainActor static func main() {
        let app=NSApplication.shared
        let delegate=AppDelegate()
        app.delegate=delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
