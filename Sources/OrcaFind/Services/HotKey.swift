import AppKit
import Carbon

/// System-wide shortcuts: ⇧⌘Space opens Quick Search, ⌥⇧Space starts a capture. Both work from any app.
final class HotKeyCenter {
    enum Slot: UInt32 { case quickSearch = 1, capture = 2, shelf = 3 }

    static let shared = HotKeyCenter()
    private var refs: [Slot: EventHotKeyRef] = [:]
    private var combos: [Slot: HotKeyCombo] = [:]
    private var handlers: [Slot: () -> Void] = [:]
    private var installed = false

    /// Quick Search handler (kept for existing callers).
    var handler: (() -> Void)? {
        get { handlers[.quickSearch] }
        set { handlers[.quickSearch] = newValue }
    }

    func setHandler(_ slot: Slot, _ action: @escaping () -> Void) { handlers[slot] = action }

    func register(_ combo: HotKeyCombo, slot: Slot = .quickSearch) {
        unregister(slot)
        combos[slot] = combo
        installIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4F52_4341), id: slot.rawValue) // 'ORCA'
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[slot] = ref }
        else { NSLog("OrcaFind: could not register hot key \(combo.display) (\(status))") }
    }

    func unregister(_ slot: Slot) {
        if let ref = refs[slot] { UnregisterEventHotKey(ref) }
        refs[slot] = nil
    }

    func unregister() { unregister(.quickSearch) }

    private func installIfNeeded() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let slot = (err == noErr ? Slot(rawValue: hk.id) : nil) ?? .quickSearch
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[slot]?() }
            return noErr
        }, 1, &spec, nil, nil)
        installed = true
    }

    /// Temporarily releases every shortcut (while the user records a new one).
    func pause() { for slot in Array(refs.keys) { unregister(slot) } }
    func resume() { for (slot, combo) in combos { register(combo, slot: slot) } }
}
