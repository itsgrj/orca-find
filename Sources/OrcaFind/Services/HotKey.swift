import AppKit
import Carbon

/// System-wide shortcut (default ⇧⌘Space) that opens Quick Search from any app.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var ref: EventHotKeyRef?
    private var installed = false
    private var current: HotKeyCombo?
    var handler: (() -> Void)?

    func register(_ combo: HotKeyCombo) {
        unregister()
        current = combo
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKeyCenter.shared.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = EventHotKeyID(signature: OSType(0x4F52_4341), id: 1) // 'ORCA'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("OrcaFind: could not register hot key \(combo.display) (\(status))") }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Temporarily releases the shortcut (while the user records a new one).
    func pause() { unregister() }
    func resume() { if let current { register(current) } }
}
