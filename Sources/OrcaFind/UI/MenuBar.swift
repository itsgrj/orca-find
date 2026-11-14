import SwiftUI
import AppKit

// MARK: - Look

/// The menu bar dropdown's look. On macOS 26 it's Liquid Glass (Apple's supported `glassEffect`, in our own
/// panel), with text in the system's adaptive label styles so it stays readable over whatever is behind it.
/// Older systems get the standard menu material. (`defaults write app.orcafind.mac menuGlass -bool NO`
/// shows the material look on 26, for comparing.)
enum MenuLook {
    static var glass: Bool {
        if #available(macOS 26, *) { return UserDefaults.standard.object(forKey: "menuGlass") as? Bool ?? true }
        return false
    }
    static var text: AnyShapeStyle { AnyShapeStyle(.primary) }
    static var text2: AnyShapeStyle { AnyShapeStyle(.secondary) }
    static var hover: AnyShapeStyle { AnyShapeStyle(.primary.opacity(0.09)) }
    static var divider: AnyShapeStyle { AnyShapeStyle(.primary.opacity(0.12)) }
    static var chip: AnyShapeStyle { AnyShapeStyle(.primary.opacity(0.07)) }
}

struct MenuChrome: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        if #available(macOS 26, *), MenuLook.glass {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(VisualEffectBackground(material: .menu))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

// MARK: - Status item and panels

/// What the menu bar's SwiftUI views react to.
@MainActor
@Observable
final class MenuUI {
    static let shared = MenuUI()
    /// Bumped each time the dropdown opens (focuses the search box, resets the tab).
    var openToken = 0
    var tab: MenuKind = .all
    var toast: MenuToastInfo?
}

struct MenuToastInfo: Identifiable {
    let id = UUID()
    let message: String
    var undo: (() -> Void)?
}

/// OrcaFind's menu bar icon. It's our own status item and panel (not MenuBarExtra) so that files can be
/// dropped on the icon, and so the dropdown uses only public API for its glass.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()
    let search = QuickSearchModel()

    private var item: NSStatusItem?
    private var dropdown: MenuPanel?
    private var dropPanel: MenuPanel?
    private var toastPanel: MenuPanel?
    private var monitors: [Any] = []
    private var dropTimer: Timer?
    private var outsideTicks = 0
    private var toastTask: Task<Void, Never>?

    var isOpen: Bool { dropdown?.isVisible ?? false }
    var statusButton: NSStatusBarButton? { item?.button }

    /// Adds or removes the icon to match Settings › Menu Bar.
    func sync() {
        let want = Preferences.shared.showMenuBar
        if want, item == nil { install() }
        if !want, let it = item { close(); hideDrop(); NSStatusBar.system.removeStatusItem(it); item = nil }
    }

    private func install() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = it
        guard let b = it.button else { return }
        b.target = self
        b.action = #selector(clicked)
        b.setAccessibilityLabel("OrcaFind")
        let overlay = StatusOverlay(frame: b.bounds)
        overlay.autoresizingMask = [.width, .height]
        b.addSubview(overlay)
        trackIcon()
    }

    /// The orca, with a blue dot while an update is waiting.
    private func trackIcon() {
        withObservationTracking {
            let dot = Updater.shared.hasUpdate
            item?.button?.image = dot ? MenuBarGlyph.withDot : MenuBarGlyph.image
            item?.button?.setAccessibilityLabel(dot ? "OrcaFind, update ready" : "OrcaFind")
        } onChange: {
            Task { @MainActor in MenuBarController.shared.trackIcon() }
        }
    }

    @objc private func clicked() { toggle() }

    func toggle() { isOpen ? close() : open() }

    func open() {
        hideDrop()
        if dropdown == nil {
            dropdown = makePanel(MenuBarView(), key: true)
        }
        guard let p = dropdown else { return }
        search.query = ""
        MenuUI.shared.tab = .all
        MenuUI.shared.openToken += 1
        place(p)
        p.makeKeyAndOrderFront(nil)
        item?.button?.highlight(true)
        installMonitors()
    }

    func close() {
        guard let p = dropdown, p.isVisible else { return }
        p.orderOut(nil)
        item?.button?.highlight(false)
        if VoiceSearch.shared.owner == "menu" { VoiceSearch.shared.stop() }
        removeMonitors()
    }

    /// Hides the dropdown first so it isn't in the picture.
    func startCapture() {
        close()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            CaptureController.shared.start()
        }
    }

    func openApp(_ then: (() -> Void)? = nil) {
        close()
        AppState.shared.openMainWindow()
        then?()
    }

    // MARK: Drops on the icon

    func dragEntered() {
        close()
        if dropPanel == nil { dropPanel = makePanel(MenuDropPanel(), key: false) }
        guard let p = dropPanel else { return }
        item?.button?.highlight(true)
        if !p.isVisible {
            place(p)
            p.orderFrontRegardless()
        }
        outsideTicks = 0
        dropTimer?.invalidate()
        dropTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarController.shared.watchDrag() }
        }
    }

    /// Keeps the drop panel up while the drag is over it or the icon; hides it once the drag ends or leaves.
    private func watchDrag() {
        guard let p = dropPanel, p.isVisible else { dropTimer?.invalidate(); return }
        let held = NSEvent.pressedMouseButtons & 1 != 0
        let at = NSEvent.mouseLocation
        let icon = item?.button?.window?.frame.insetBy(dx: -8, dy: -8) ?? .zero
        let near = p.frame.insetBy(dx: -28, dy: -28).contains(at) || icon.contains(at)
        if !held { hideDrop(); return }
        outsideTicks = near ? 0 : outsideTicks + 1
        if outsideTicks > 3 { hideDrop() }
    }

    func hideDrop() {
        dropTimer?.invalidate(); dropTimer = nil
        guard let p = dropPanel, p.isVisible else { return }
        p.orderOut(nil)
        if !isOpen { item?.button?.highlight(false) }
    }

    /// Dropped on a folder in the drop panel (or the shelf): move it there, with Undo.
    func put(_ urls: [URL], in folder: URL) {
        hideDrop()
        let done = FileDrop.put(urls, in: folder, copy: FileDrop.optionHeld)
        guard done.count > 0 else { return }
        showToast(done.message) {
            let n = FileDrop.undo(done)
            MenuBarController.shared.showToast("Put back \(Fmt.plural(n, "file"))")
        }
    }

    func saveAsCapture(_ urls: [URL]) {
        hideDrop()
        guard let url = urls.first else { return }
        CaptureController.shared.startShared(SharedItem(kind: .file, title: url.lastPathComponent, path: url.path))
    }

    /// Move to Trash from the dropdown's right-click menu.
    func trash(_ file: FileItem) {
        let r = Trash.move([file], reason: nil, from: "Menu bar")
        guard r.count > 0 else { return }
        let paths = Set(r.moved.map { $0.original.path })
        AppState.shared.tidy.remove(paths: paths)
        AppState.shared.dupes.removeTrashed(paths)
        showToast("Moved \(file.name) to the Trash") {
            let n = Trash.restore(r)
            MenuBarController.shared.showToast(n > 0 ? "Put back \(file.name)" : "Couldn’t put it back")
        }
    }

    // MARK: Toast under the icon

    func showToast(_ message: String, undo: (() -> Void)? = nil) {
        MenuUI.shared.toast = MenuToastInfo(message: message, undo: undo)
        if toastPanel == nil { toastPanel = makePanel(MenuToastView(), key: false) }
        guard let p = toastPanel else { return }
        place(p)
        p.orderFrontRegardless()
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: undo == nil ? 2_600_000_000 : 6_000_000_000)
            guard !Task.isCancelled else { return }
            MenuBarController.shared.hideToast()
        }
    }

    func hideToast() {
        toastTask?.cancel()
        toastPanel?.orderOut(nil)
        MenuUI.shared.toast = nil
    }

    // MARK: Panels

    private func makePanel<V: View>(_ root: V, key: Bool) -> MenuPanel {
        let p = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.allowsKey = key
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.delegate = self
        let sized = root
            .environment(AppState.shared)
            .environment(CaptureLibrary.shared)
            .focusEffectDisabled()
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak p] size in
                guard let p, size.width > 0, size.height > 0 else { return }
                MainActor.assumeIsolated { MenuBarController.shared.resize(p, to: size) }
            }
        let host = FirstMouseHostingView(rootView: sized)
        p.contentView = host
        let fit = host.fittingSize
        if fit.width > 0 && fit.height > 0 { p.setContentSize(fit) }
        return p
    }

    private func resize(_ p: MenuPanel, to size: CGSize) {
        guard abs(p.frame.width - size.width) > 0.5 || abs(p.frame.height - size.height) > 0.5 else { return }
        let top = p.frame.maxY
        p.setContentSize(size)
        if p.isVisible { place(p, top: top) }
    }

    /// Just under the icon, centred on it, kept on screen.
    private func place(_ p: NSWindow, top: CGFloat? = nil) {
        // No icon (hidden in Settings): the top middle of the screen, under the menu bar.
        guard let bw = item?.button?.window else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: vf.midX - p.frame.width / 2, y: top ?? (vf.maxY - 8)))
            return
        }
        let a = bw.frame
        let vf = (bw.screen ?? NSScreen.main)?.visibleFrame ?? a
        let w = p.frame.width
        let x = min(max(a.midX - w / 2, vf.minX + 8), vf.maxX - w - 8)
        p.setFrameTopLeftPoint(NSPoint(x: x, y: top ?? (a.minY - 4)))
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let w = notification.object as? NSWindow, w === dropdown else { return }
            // Voice search keeps it open while you talk.
            if !(VoiceSearch.shared.isListening && VoiceSearch.shared.owner == "menu") { close() }
        }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { MenuBarController.shared.close() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { e in
            // keyCode only exists on key events: asking a mouse event for it throws, and AppKit drops the click.
            let type = e.type, code = type == .keyDown ? Int(e.keyCode) : -1, window = e.window
            let keep = MainActor.assumeIsolated { MenuBarController.shared.local(type: type, keyCode: code, window: window) }
            return keep ? e : nil
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Returns false to swallow the event.
    private func local(type: NSEvent.EventType, keyCode: Int, window: NSWindow?) -> Bool {
        guard let p = dropdown, p.isVisible else { return true }
        if type == .keyDown {
            guard window === p else { return true }
            switch keyCode {
            case 53:                                             // esc: clear the search, then close
                if !search.query.isEmpty { search.query = "" } else { close() }
                return false
            case 36, 76:                                         // return opens the top match
                if let first = search.results.first, !search.query.isEmpty { close(); FileActions.open([first]); return false }
                return true
            default: return true
            }
        }
        // A click in one of our other windows (not the icon, which toggles by itself). Context and pop-up
        // menus sit at menu level or above; clicks there keep the dropdown open.
        if let w = window, w !== p, w !== item?.button?.window, w.level.rawValue < NSWindow.Level.popUpMenu.rawValue { close() }
        return true
    }
}

final class MenuPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a panel that isn't key (the toast's Undo, the drop targets) work on the first click.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Sits over the status item's button: clicks toggle the dropdown, and dragging a file over it opens the drop panel.
private final class StatusOverlay: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { MainActor.assumeIsolated { MenuBarController.shared.toggle() } }
    override func rightMouseDown(with event: NSEvent) { MainActor.assumeIsolated { MenuBarController.shared.toggle() } }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { MenuBarController.shared.dragEntered() }
        return .generic
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .generic }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
}

// MARK: - Kinds of download (the tabs)

enum MenuKind: String, CaseIterable, Identifiable {
    case all, images, videos, docs, zips, notes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .images: return "Images"
        case .videos: return "Videos"
        case .docs: return "Docs"
        case .zips: return "Zips"
        case .notes: return "Notes"
        }
    }

    static let noteExts: Set<String> = ["md", "markdown", "txt", "text"]
    static let zipExts: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst"]

    func matches(_ i: FileItem) -> Bool {
        let ext = i.ext.lowercased()
        switch self {
        case .all: return true
        case .images: return i.category == .images
        case .videos: return i.category == .videos
        case .notes: return Self.noteExts.contains(ext)
        case .docs: return i.category == .documents && !Self.noteExts.contains(ext)
        case .zips: return Self.zipExts.contains(ext)
        }
    }

    /// The kinds with at least one file, in tab order, with counts.
    static func present(in items: [FileItem]) -> [(kind: MenuKind, count: Int)] {
        allCases.dropFirst().compactMap { k in
            let n = items.reduce(0) { $0 + (k.matches($1) ? 1 : 0) }
            return n > 0 ? (k, n) : nil
        }
    }
}

/// Which stretch of time a download falls in. The dropdown's heading names the newest one; the rest get a small
/// label where they start, so scrolling down reads as going back in time.
enum MenuDay: Int, Comparable {
    case today, yesterday, week, month, older

    static func < (a: MenuDay, b: MenuDay) -> Bool { a.rawValue < b.rawValue }

    static func of(_ date: Date, now: Date = Date()) -> MenuDay {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        if date >= start { return .today }
        if date >= start.addingTimeInterval(-86_400) { return .yesterday }
        if date >= start.addingTimeInterval(-6 * 86_400) { return .week }
        if date >= start.addingTimeInterval(-29 * 86_400) { return .month }
        return .older
    }

    /// The label where this stretch starts in the list.
    var label: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Earlier this week"
        case .month: return "Earlier this month"
        case .older: return "Older"
        }
    }

    /// The dropdown's heading when this is the newest stretch.
    var heading: String {
        switch self {
        case .today: return "Downloaded today"
        case .yesterday: return "Downloaded yesterday"
        case .week: return "Downloaded this week"
        case .month: return "Downloaded this month"
        case .older: return "Latest downloads"
        }
    }

    /// Newest-first items, cut where the stretch of time changes.
    static func groups(_ items: [FileItem]) -> [(day: MenuDay, items: [FileItem])] {
        var out: [(day: MenuDay, items: [FileItem])] = []
        for i in items {
            let d = of(i.added ?? i.activityDate)
            if out.last?.day == d { out[out.count - 1].items.append(i) } else { out.append((d, [i])) }
        }
        return out
    }
}

// MARK: - The dropdown

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Bindable private var search = MenuBarController.shared.search
    private var ui = MenuUI.shared
    @FocusState private var searchFocused: Bool
    /// The download list's full height, so a short list doesn't sit in a tall empty box.
    @State private var listHeight: CGFloat = 0

    private var query: String { search.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let p = state.prefs
        VStack(alignment: .leading, spacing: 0) {
            if p.menuShowSearch { searchBox }
            UpdateMenuRow()
            if p.menuShowSearch && !query.isEmpty { results } else { downloads }
            player
            Rectangle().fill(MenuLook.divider).frame(height: 1).padding(.top, 6)
            footer
        }
        .frame(width: 420)
        .modifier(MenuChrome())
        .onChange(of: ui.openToken) { _, _ in DispatchQueue.main.async { searchFocused = true } }
        .onAppear { searchFocused = true }
    }

    // MARK: Search

    private var searchBox: some View {
        let listening = state.voice.isListening && state.voice.owner == "menu"
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(MenuLook.text2)
            TextField("", text: $search.query, prompt: Text("Search downloads and files…"))
                .textFieldStyle(.plain).font(DS.body).foregroundStyle(MenuLook.text)
                .focused($searchFocused)
            if listening { VoiceLevelView(level: state.voice.level) }
            if !search.query.isEmpty {
                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(MenuLook.text2).handCursor()
            }
            if state.prefs.voiceEnabled {
                Button {
                    state.voice.toggle(owner: "menu", onUpdate: { search.query = $0 }, onFinish: { _ in })
                } label: {
                    Image(systemName: listening ? "stop.fill" : "mic").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(listening ? AnyShapeStyle(DS.critical) : MenuLook.text2)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor()
            }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MenuLook.chip))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(searchFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : MenuLook.divider, lineWidth: searchFocused ? 1.5 : 1))
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }

    @ViewBuilder private var results: some View {
        let found = search.results
        header(found.isEmpty ? "Searching" : "Best matches", trailing: nil)
        if found.isEmpty {
            Text(search.understanding ? "Reading your sentence…" : "No files match. Try saying it differently.")
                .font(DS.bodySM).foregroundStyle(MenuLook.text2).frame(maxWidth: .infinity).padding(.vertical, 22)
        } else {
            rows(Array(found.prefix(8)), reasons: true)
            Rectangle().fill(MenuLook.divider).frame(height: 1).padding(.top, 6)
            Button {
                let q = search.query
                MenuBarController.shared.openApp { AppState.shared.beginSearch(q) }
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(found.count >= 40 ? "Show all results in OrcaFind" : "Show all \(found.count) in OrcaFind")
                    Spacer()
                }
                .font(DS.bodySM).foregroundStyle(DS.link)
                .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
        }
    }

    // MARK: Downloads

    @ViewBuilder private var downloads: some View {
        let stats = state.homeStats
        let all = stats.recentDownloads
        let kinds = MenuKind.present(in: all)
        let showTabs = state.prefs.menuShowTabs && kinds.count >= 2
        let tab = showTabs && kinds.contains(where: { $0.kind == ui.tab }) ? ui.tab : .all
        let items = tab == .all ? all : all.filter { tab.matches($0) }
        header(stats.recentDownloadsTitle, trailing: all.isEmpty ? nil : "See all")
        if showTabs {
            HStack(spacing: 4) {
                tabChip(.all, all.count, on: tab == .all)
                ForEach(kinds, id: \.kind) { k in tabChip(k.kind, k.count, on: tab == k.kind) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
        if items.isEmpty {
            Text(state.index.isReady ? "Nothing downloaded yet" : "Getting ready…")
                .font(DS.bodySM).foregroundStyle(MenuLook.text2).frame(maxWidth: .infinity).padding(24)
        } else {
            downloadList(items, tab: tab, headed: all.first.map { MenuDay.of($0.added ?? $0.activityDate) })
        }
    }

    /// Every download from the past month in one list. It opens on the newest; scrolling goes back in time,
    /// with a small label where each stretch (yesterday, earlier this week…) starts.
    private func downloadList(_ items: [FileItem], tab: MenuKind, headed: MenuDay?) -> some View {
        let groups = MenuDay.groups(items)
        // Tall enough for the rows chosen in Settings, never taller than the screen leaves room for.
        let screen = (MenuBarController.shared.statusButton?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let limit = min(CGFloat(state.prefs.menuDownloadCount) * 41 + 4, max(240, screen - 230))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    Color.clear.frame(height: 0).id("menu-top")
                    ForEach(Array(groups.enumerated()), id: \.offset) { n, g in
                        // The heading above already names the first stretch.
                        if !(n == 0 && g.day == headed) { dayLabel(g.day.label, first: n == 0) }
                        if tab == .images {
                            imageGrid(g.items)
                        } else {
                            ForEach(g.items) { MenuDownloadRow(item: $0) }
                        }
                    }
                    listEnd(count: items.count)
                }
                .padding(.horizontal, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(listHeight, 41), limit))
            .onChange(of: ui.openToken) { _, _ in proxy.scrollTo("menu-top", anchor: .top) }
            .onChange(of: tab) { _, _ in proxy.scrollTo("menu-top", anchor: .top) }
        }
    }

    private func dayLabel(_ text: String, first: Bool) -> some View {
        PixelLabel(text, color: .secondary)
            .padding(.horizontal, 8).padding(.top, first ? 2 : 12).padding(.bottom, 4)
    }

    /// The bottom of the list: how far back it goes, and the way to everything else.
    private func listEnd(count: Int) -> some View {
        HStack(spacing: 6) {
            Text(count >= 150 ? "Your 150 newest downloads" : "That’s everything from the past month")
                .foregroundStyle(MenuLook.text2)
            Button("See all downloads") { MenuBarController.shared.openApp { AppState.shared.navigate(.downloadedFrom(nil)) } }
                .buttonStyle(.plain).foregroundStyle(DS.link).handCursor()
            Spacer(minLength: 0)
        }
        .font(DS.caption)
        .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 8)
    }

    private func header(_ title: String, trailing: String?) -> some View {
        HStack {
            PixelLabel(title, color: .secondary)
            Spacer()
            if let trailing {
                Button(trailing) { MenuBarController.shared.openApp { AppState.shared.navigate(.downloadedFrom(nil)) } }
                    .buttonStyle(.plain).font(DS.bodySM).foregroundStyle(DS.link).handCursor()
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
    }

    private func tabChip(_ k: MenuKind, _ n: Int, on: Bool) -> some View {
        Button { ui.tab = k } label: {
            HStack(spacing: 4) {
                Text(k.title).font(DS.bodySM)
                Text("\(n)").font(DS.caption).opacity(on ? 0.7 : 0.55)
            }
            // Solid colours for the chosen tab: on glass, .primary turns see-through and the label washes out.
            .foregroundStyle(on ? AnyShapeStyle(DS.onBrand) : MenuLook.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? AnyShapeStyle(DS.brand) : MenuLook.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }

    @ViewBuilder private func rows(_ items: [FileItem], reasons: Bool) -> some View {
        let list = VStack(spacing: 1) {
            ForEach(items) { i in
                MenuDownloadRow(item: i, reason: reasons ? SearchEngine.reason(for: i, search.parsed) : nil)
            }
        }
        .padding(.horizontal, 6)
        list
    }

    private func imageGrid(_ items: [FileItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(items) { MenuImageCell(item: $0) }
        }
        .padding(.horizontal, 4).padding(.bottom, 4)
    }

    // MARK: Music and footer

    @ViewBuilder private var player: some View {
        if let cur = state.player.current {
            Rectangle().fill(MenuLook.divider).frame(height: 1).padding(.top, 6)
            HStack(spacing: 10) {
                Thumb(item: cur, size: 60).frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.player.title).font(DS.bodySM).foregroundStyle(MenuLook.text).lineLimit(1)
                    Text("\(Fmt.duration(state.player.position)) / \(Fmt.duration(state.player.duration))").font(DS.caption).foregroundStyle(MenuLook.text2)
                }
                Spacer()
                Button { state.player.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain).handCursor()
                Button { state.player.toggle() } label: { Image(systemName: state.player.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain).handCursor()
                Button { state.player.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain).handCursor()
            }
            .font(.system(size: 12)).foregroundStyle(MenuLook.text)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { MenuBarController.shared.openApp() } label: {
                HStack(spacing: 5) {
                    Image(nsImage: MenuBarGlyph.image).resizable().renderingMode(.template).scaledToFit().frame(width: 15, height: 15)
                    Text("Open OrcaFind")
                }
            }
            .buttonStyle(.plain).font(DS.bodySM).foregroundStyle(DS.link).handCursor()
            Spacer()
            if state.prefs.menuShowCapture && state.prefs.capturesEnabled { MenuCaptureButton() }
            MenuGearButton()
        }
        .foregroundStyle(MenuLook.text2)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Capture, in the same quiet grey as Settings. Resting the pointer on it says what it's for.
private struct MenuCaptureButton: View {
    @State private var tip = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        Button { MenuBarController.shared.startCapture() } label: {
            HStack(spacing: 5) {
                Image(systemName: "camera.viewfinder")
                Text("Capture")
            }
            .font(DS.bodySM).contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { h in
            task?.cancel()
            if h {
                task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 550_000_000)
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { tip = true } }
                }
            } else {
                tip = false
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if tip {
                MenuTipCard(title: "Save a piece of your screen",
                            detail: "Drag over anything, say why you’re keeping it, and find it later in OrcaFind.")
                    .offset(x: 6, y: -26)
                    .allowsHitTesting(false).transition(.opacity)
            }
        }
    }
}

/// The gear: Settings, and Quit (which moved here from the bottom bar).
private struct MenuGearButton: View {
    var up = Updater.shared
    var body: some View {
        Menu {
            Button("Settings…") { MenuBarController.shared.close(); AppState.shared.openSettingsWindow() }
            Divider()
            Button(up.isReady ? "Quit and Update" : "Quit OrcaFind") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .tint(.secondary).foregroundStyle(.secondary)
        .overlay(alignment: .topTrailing) {
            if up.isReady { Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 3, y: -2) }
        }
        .handCursor()
    }
}

/// Everyday actions on any file in the dropdown. Move to Trash sits apart, in red.
private struct MenuFileMenu: ViewModifier {
    let item: FileItem
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open") { MenuBarController.shared.close(); FileActions.open([item]) }
            Button("Quick Look") {
                MenuBarController.shared.close()
                NSApp.activate(ignoringOtherApps: true)
                QuickLookCoordinator.shared.toggle(items: [item], index: 0)
            }
            Button("Show in OrcaFind") { MenuBarController.shared.openApp { AppState.shared.revealInApp(item) } }
            Button("Show in Finder") { MenuBarController.shared.close(); FileActions.revealInFinder([item]) }
            Divider()
            Button("Copy") { FileActions.copy([item]) }
            Button("Copy as Path") { FileActions.copyPath([item]) }
            Divider()
            Button("Move to Trash", role: .destructive) { MenuBarController.shared.trash(item) }
        }
    }
}

struct MenuDownloadRow: View {
    let item: FileItem
    var reason: String? = nil
    @State private var hovering = false
    @State private var showTip = false
    @State private var tipTask: Task<Void, Never>?
    @State private var pointer: CGPoint = .zero
    @State private var rowWidth: CGFloat = 408
    @State private var pressed = false
    @State private var mouseMonitor: Any?

    private var thumb: some View {
        Thumb(item: item, size: 60, mode: item.category == .images || item.category == .videos ? .fill : (item.category == .documents ? .page : .fit))
            .frame(width: 30, height: 30).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 7))
    }

    var body: some View {
        HStack(spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(DS.bodySM).foregroundStyle(MenuLook.text).lineLimit(1).truncationMode(.middle)
                Text(reason.map { $0 + " · " + Fmt.relative(item.added ?? item.activityDate) }
                     ?? "\(Fmt.size(item.size)) · \(Fmt.relative(item.added ?? item.activityDate))")
                    .font(DS.caption).foregroundStyle(MenuLook.text2).lineLimit(1)
            }
            Spacer()
            if let s = item.source { Badge(s.name, tone: .info) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? MenuLook.hover : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        // Our own tooltip: it appears after a short rest and sits just below the pointer, following it along the row.
        .background(GeometryReader { g in Color.clear.onAppear { rowWidth = g.size.width }.onChange(of: g.size.width) { _, w in rowWidth = w } })
        .overlay(alignment: .topLeading) {
            if showTip {
                MenuTooltip(text: "Drag into any app", symbol: "hand.draw")
                    .offset(x: min(max(pointer.x - 6, 0), rowWidth - 150), y: pointer.y + 18)
                    .allowsHitTesting(false).transition(.opacity)
            }
        }
        .zIndex(showTip ? 1 : 0)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let at):
                pointer = at
                if pressed && NSEvent.pressedMouseButtons == 0 { pressed = false }   // a drag ended elsewhere
                if !hovering {
                    hovering = true
                    watchPresses(true)
                    tipTask?.cancel()
                    tipTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { showTip = true } }
                    }
                }
            case .ended:
                hovering = false
                pressed = false
                watchPresses(false)
                tipTask?.cancel()
                showTip = false
            }
        }
        .modifier(GrabCursor(pressed: pressed, hovering: hovering))
        .onDisappear { watchPresses(false) }
        .onTapGesture { MenuBarController.shared.close(); FileActions.open([item]) }
        // Drag just the file (thumbnail + name), not the whole row with its source chip.
        .onDrag {
            tipTask?.cancel(); showTip = false
            return NSItemProvider(object: item.url as NSURL)
        } preview: {
            HStack(spacing: 8) {
                thumb
                Text(item.name).font(DS.bodySM).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
            }
        }
        .modifier(MenuFileMenu(item: item))
    }

    /// Mouse-down/up inside the hovered row, for the closed-hand cursor. (A drag gesture would fight `.onDrag`.)
    private func watchPresses(_ on: Bool) {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        guard on else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            pressed = e.type == .leftMouseDown
            if pressed { tipTask?.cancel(); showTip = false }
            return e
        }
    }
}

/// Images tab: pictures you recognise at a glance instead of file names.
private struct MenuImageCell: View {
    let item: FileItem
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Thumb(item: item, size: 180, mode: .fill)
                .frame(maxWidth: .infinity).frame(height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.08)))
            Text(item.name).font(DS.caption).foregroundStyle(MenuLook.text2).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(GrabCursor(pressed: false, hovering: hovering))
        .onTapGesture { MenuBarController.shared.close(); FileActions.open([item]) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .modifier(MenuFileMenu(item: item))
    }
}

// MARK: - Drop panel (drag a file onto the icon)

struct MenuDropPanel: View {
    @Environment(AppState.self) private var state
    @State private var overCapture = false
    @State private var overFolder: URL?

    var body: some View {
        let targets = FileDrop.targets
        let pinned = !state.pinnedFolders.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            Text("Drop to put it away").font(DS.headingSM).foregroundStyle(MenuLook.text)
            if state.prefs.capturesEnabled {
                HStack(spacing: 12) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 20)).foregroundStyle(MenuLook.text).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save as a capture").font(DS.body).foregroundStyle(MenuLook.text)
                        Text("Keeps the file with a note you can say out loud, like any capture")
                            .font(DS.caption).foregroundStyle(MenuLook.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(overCapture ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : MenuLook.chip))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(overCapture ? AnyShapeStyle(Color.accentColor) : MenuLook.divider, lineWidth: overCapture ? 2 : 1))
                .onDrop(of: [.fileURL], isTargeted: $overCapture) { providers in
                    Task { @MainActor in MenuBarController.shared.saveAsCapture(await FileDrop.urls(from: providers)) }
                    return true
                }
            }
            PixelLabel(pinned ? "Or move it into a pinned folder" : "Or move it into a folder", color: .secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(106), spacing: 10), count: 3), alignment: .leading, spacing: 10) {
                ForEach(targets.prefix(6), id: \.self) { folder in
                    let pv = state.pinnedPreviews[folder.path]
                    let kind = pv?.items.first?.category ?? .documents
                    GlassFolder(title: FileManager.default.displayName(atPath: folder.path),
                                meta: pv.map { "\(Fmt.count($0.count)) items" } ?? "",
                                palette: .of(kind), style: .of(kind), items: pv?.items ?? [], width: 106)
                        .scaleEffect(overFolder == folder ? 1.06 : 1)
                        .animation(.spring(duration: 0.2), value: overFolder)
                        .onDrop(of: [.fileURL], isTargeted: Binding(get: { overFolder == folder }, set: { overFolder = $0 ? folder : (overFolder == folder ? nil : overFolder) })) { providers in
                            Task { @MainActor in MenuBarController.shared.put(await FileDrop.urls(from: providers), in: folder) }
                            return true
                        }
                }
            }
            Text("Hold ⌥ to copy instead of moving").font(DS.caption).foregroundStyle(MenuLook.text2)
        }
        .padding(12)
        .frame(width: 364)
        .modifier(MenuChrome())
    }
}

// MARK: - Toast under the icon

struct MenuToastView: View {
    private var ui = MenuUI.shared
    var body: some View {
        HStack(spacing: 10) {
            Text(ui.toast?.message ?? "").font(DS.bodySM).foregroundStyle(MenuLook.text).lineLimit(1).truncationMode(.middle)
            if let undo = ui.toast?.undo {
                Button("Undo") { MenuBarController.shared.hideToast(); undo() }
                    .buttonStyle(.plain).font(DS.bodySM).foregroundStyle(DS.link).handCursor()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 380)
        .modifier(MenuChrome(radius: 12))
    }
}

// MARK: - Small pieces

/// Open hand over something you can drag, closed hand while it's held. `.pointerStyle` (macOS 15+) is kept
/// applied by the system; setting NSCursor by hand gets reset to the arrow whenever the view changes.
struct GrabCursor: ViewModifier {
    let pressed: Bool
    let hovering: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(pressed ? .grabActive : .grabIdle)
        } else {
            content
                .onContinuousHover { phase in
                    if case .active = phase { (pressed ? NSCursor.closedHand : NSCursor.openHand).set() } else { NSCursor.arrow.set() }
                }
                .onChange(of: pressed) { _, p in if hovering { (p ? NSCursor.closedHand : NSCursor.openHand).set() } }
        }
    }
}

/// A small tooltip in the style of the system's, for places where `.help` isn't shown.
struct MenuTooltip: View {
    let text: String
    var symbol: String?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(DS.caption)
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .fixedSize()
    }
}

/// A two-line tooltip: what it is, then what it does.
struct MenuTipCard: View {
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(DS.bodySM.weight(.semibold))
            Text(detail).font(DS.caption).opacity(0.8).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .frame(width: 236, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }
}
