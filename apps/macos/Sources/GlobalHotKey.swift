import Carbon
import AppKit

/// System-wide ⌥⌘T for quick capture. Carbon hot keys need no accessibility permission.
final class GlobalHotKey {
    static let display="⌥⌘T"
    private var ref:EventHotKeyRef?
    private var handler:EventHandlerRef?
    private let action:()->Void
    init(action:@escaping()->Void) {self.action=action}
    var isRegistered:Bool {ref != nil}

    func register() {
        guard ref == nil else{return}
        var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let context=Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),{_,_,context in
            guard let context else{return noErr}
            let hotKey=Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {hotKey.action()}
            return noErr
        },1,&spec,context,&handler)
        let id=EventHotKeyID(signature:OSType(0x54434154),id:1) // "TCAT"
        RegisterEventHotKey(UInt32(kVK_ANSI_T),UInt32(cmdKey|optionKey),id,GetApplicationEventTarget(),0,&ref)
    }
    func unregister() {
        if let ref {UnregisterEventHotKey(ref)};ref=nil
        if let handler {RemoveEventHandler(handler)};handler=nil
    }
    deinit {unregister()}
}
