import SwiftUI
import AppKit

/// The Drop Shelf: slides down from the notch when you start dragging a file, rest the pointer on the
/// notch, or press ⌃⌥Space. Drop on a pinned folder to file it there, or park it in Holding and drag it
/// out again later from another app. Macs without a notch get the same shelf under the menu bar icon.
@MainActor
final class DropShelfController: NSObject {
    static let shared = DropShelfController()
    enum Trigger { case drag, notch, hotkey }

    private var panel: MenuPanel?
    private var timer: Timer?
    private var clickMonitor: Any?
    private var trigger: Trigger = .hotkey
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var notchSince: Date?
    private var outsideTicks = 0
    /// Height of the notch on the screen the shelf is showing on (0 = no notch: it hangs under the menu bar).
    private(set) var notchHeight: CGFloat = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    func sync() {
        if Preferences.shared.shelfEnabled { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        dragBaseline = NSPasteboard(name: .drag).changeCount
        // Polling is the dependable way to see a drag that started in another app: the drag pasteboard
        // changes when one begins, and global mouse-dragged events stop arriving once it has.
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { DropShelfController.shared.tick() }
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        hide()
    }

    func toggle() { isVisible ? hide() : show(.hotkey) }

    private func tick() {
        let prefs = Preferences.shared
        let held = NSEvent.pressedMouseButtons & 1 != 0
        let at = NSEvent.mouseLocation
        let pb = NSPasteboard(name: .drag)

        if !held {
            dragBaseline = pb.changeCount
        } else if prefs.shelfOnDrag, !isVisible, pb.changeCount != dragBaseline {
            dragBaseline = pb.changeCount
            if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { show(.drag) }
        }

        if prefs.shelfOnNotch, !isVisible, !held, let notch = Self.notchRect(on: Self.screen(at: at)), notch.insetBy(dx: 0, dy: -2).contains(at) {
            if let since = notchSince {
                if Date().timeIntervalSince(since) > 0.35 { show(.notch) }
            } else {
                notchSince = Date()
            }
        } else {
            notchSince = nil
        }

        // Tucks itself away once you're done: the drag ended or the pointer left it.
        guard isVisible, let p = panel, trigger != .hotkey else { return }
        let near = p.frame.insetBy(dx: -24, dy: -24).contains(at)
        if held && trigger == .drag { outsideTicks = 0; return }
        outsideTicks = near ? 0 : outsideTicks + 1
        if outsideTicks > 4 { hide() }
    }

    func show(_ how: Trigger) {
        if MenuBarController.shared.isOpen { MenuBarController.shared.close() }
        MenuBarController.shared.hideDrop()
        trigger = how
        outsideTicks = 0
        let screen = Self.screen(at: NSEvent.mouseLocation)
        let notch = Self.notchRect(on: screen)
        notchHeight = notch?.height ?? 0
        panel?.orderOut(nil)
        let p = makePanel()
        panel = p
        let size = p.frame.size
        let top: CGFloat
        let midX: CGFloat
        if let notch {
            top = screen.frame.maxY
            midX = notch.midX
        } else if let bw = MenuBarController.shared.statusButton?.window, bw.screen == screen {
            top = bw.frame.minY - 4
            midX = bw.frame.midX
        } else {
            top = screen.visibleFrame.maxY - 4
            midX = screen.frame.midX
        }
        let vf = screen.frame
        let x = min(max(midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
        p.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        p.orderFrontRegardless()
        if how == .hotkey { watchClicks(true) }
    }

    func hide() {
        watchClicks(false)
        panel?.orderOut(nil)
    }

    /// Opened with the shortcut: a click anywhere else puts it away.
    private func watchClicks(_ on: Bool) {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        guard on else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { DropShelfController.shared.hide() }
        }
    }

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.allowsKey = false
        p.isFloatingPanel = true
        // Above the menu bar, so on a notched Mac it reads as the notch growing downwards.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = notchHeight == 0
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        let host = FirstMouseHostingView(rootView: DropShelfView(notch: notchHeight)
            .environment(AppState.shared)
            .focusEffectDisabled()
            .fixedSize())
        p.contentView = host
        p.setContentSize(host.fittingSize)
        return p
    }

    // MARK: Holding

    func hold(_ urls: [URL]) {
        let prefs = Preferences.shared
        var list = prefs.shelfHolding.filter { FileManager.default.fileExists(atPath: $0) }
        for u in urls where !list.contains(u.path) { list.insert(u.path, at: 0) }
        prefs.shelfHolding = Array(list.prefix(12))
    }

    func release(_ path: String) { Preferences.shared.shelfHolding.removeAll { $0 == path } }
    func releaseAll() { Preferences.shared.shelfHolding = [] }

    func put(_ urls: [URL], in folder: URL) {
        let done = FileDrop.put(urls, in: folder, copy: FileDrop.optionHeld)
        // Anything filed from Holding leaves Holding.
        for m in done.moves where !done.copied { release(m.from.path) }
        hide()
        guard done.count > 0 else { return }
        MenuBarController.shared.showToast(done.message) {
            let n = FileDrop.undo(done)
            MenuBarController.shared.showToast("Put back \(Fmt.plural(n, "file"))")
        }
    }

    // MARK: Screens

    static func screen(at point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The notch, in screen coordinates (nil on screens without one).
    static func notchRect(on screen: NSScreen) -> NSRect? {
        let top = screen.safeAreaInsets.top
        guard top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return NSRect(x: left.maxX, y: screen.frame.maxY - top, width: right.minX - left.maxX, height: top)
    }
}

// MARK: - The shelf

struct DropShelfView: View {
    let notch: CGFloat
    @Environment(AppState.self) private var state
    @State private var overHolding = false
    @State private var overFolder: URL?

    private var held: [URL] {
        state.prefs.shelfHolding.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        let onNotch = notch > 0
        VStack(alignment: .leading, spacing: 10) {
            if onNotch { Color.clear.frame(height: notch) }
            HStack(alignment: .top, spacing: 14) {
                holding
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 92)
                folders
            }
            HStack {
                Text("Drop on a folder to move it there  ·  hold ⌥ to copy").font(DS.caption).foregroundStyle(.secondary)
                Spacer()
                Kbd(state.prefs.shelfHotKey.display)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 14).padding(.top, onNotch ? 4 : 14)
        .background {
            if onNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous).fill(Color.black)
            }
        }
        .modifier(ShelfChrome(onNotch: onNotch))
        .environment(\.colorScheme, onNotch ? .dark : (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
    }

    private var holding: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                Text(held.isEmpty ? "Holding" : "Holding · \(held.count)")
                Spacer()
                if !held.isEmpty {
                    Button { DropShelfController.shared.releaseAll() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear Holding").handCursor()
                }
            }
            .font(DS.bodySM).foregroundStyle(.primary)
            if held.isEmpty {
                Text("Drop here to keep it for a moment, then drag it out in another app")
                    .font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    ForEach(held.prefix(4), id: \.self) { url in HeldFile(url: url) }
                }
            }
        }
        .padding(10)
        .frame(width: 176, height: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(overHolding ? 0.14 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(overHolding ? Color.accentColor : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: overHolding ? 2 : 1, dash: held.isEmpty ? [5, 4] : [])))
        .onDrop(of: [.fileURL], isTargeted: $overHolding) { providers in
            Task { @MainActor in DropShelfController.shared.hold(await FileDrop.urls(from: providers)) }
            return true
        }
    }

    private var folders: some View {
        HStack(spacing: 10) {
            ForEach(FileDrop.targets.prefix(4), id: \.self) { folder in
                let pv = state.pinnedPreviews[folder.path]
                let kind = pv?.items.first?.category ?? .documents
                GlassFolder(title: FileManager.default.displayName(atPath: folder.path),
                            meta: pv.map { "\(Fmt.count($0.count)) items" } ?? "",
                            palette: .of(kind), style: .of(kind), items: pv?.items ?? [], width: 104)
                    .scaleEffect(overFolder == folder ? 1.06 : 1)
                    .animation(.spring(duration: 0.2), value: overFolder)
                    .onDrop(of: [.fileURL], isTargeted: Binding(get: { overFolder == folder }, set: { overFolder = $0 ? folder : (overFolder == folder ? nil : overFolder) })) { providers in
                        Task { @MainActor in DropShelfController.shared.put(await FileDrop.urls(from: providers), in: folder) }
                        return true
                    }
            }
        }
    }
}

private struct ShelfChrome: ViewModifier {
    let onNotch: Bool
    func body(content: Content) -> some View {
        if onNotch { content } else { content.modifier(MenuChrome(radius: 22)) }
    }
}

/// A file in Holding: drag it out into any app.
private struct HeldFile: View {
    let url: URL
    @State private var hovering = false
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable().scaledToFit()
            .frame(width: 34, height: 34)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.14 : 0)))
            .onHover { hovering = $0 }
            .help(url.lastPathComponent)
            .onDrag { NSItemProvider(object: url as NSURL) }
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Remove from Holding") { DropShelfController.shared.release(url.path) }
            }
            .modifier(GrabCursor(pressed: false, hovering: hovering))
    }
}
