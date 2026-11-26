import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

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
    /// Where the shelf hangs from: its top edge, the x it centres on, and the screen it must stay on.
    private var anchor: (top: CGFloat, midX: CGFloat, screen: NSRect)?
    private var resizeWatch: NSObjectProtocol?

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
        anchor = (top, midX, screen.frame)
        p.setFrame(frame(for: size), display: false)
        p.orderFrontRegardless()
        if how == .hotkey { watchClicks(true) }
    }

    private func frame(for size: NSSize) -> NSRect {
        guard let a = anchor else { return NSRect(origin: .zero, size: size) }
        let x = min(max(a.midX - size.width / 2, a.screen.minX + 8), a.screen.maxX - size.width - 8)
        return NSRect(x: x, y: a.top - size.height, width: size.width, height: size.height)
    }

    /// The shelf's content changed size (a stack opened or closed, files came or went): resize it so it keeps
    /// hanging from the notch and grows downwards.
    func fit() {
        guard let p = panel, let host = p.contentView else { return }
        let f = frame(for: host.fittingSize)
        if f != p.frame { p.setFrame(f, display: true) }
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
        let host = FirstMouseHostingView(rootView: DropShelfView(notch: notchHeight, openedByDrag: trigger == .drag)
            .environment(AppState.shared)
            .focusEffectDisabled()
            .fixedSize())
        p.contentView = host
        p.setContentSize(host.fittingSize)
        // When the content grows (a stack opens) the hosting view resizes the panel from its bottom edge, which
        // would push it up into the menu bar: keep it hanging from the notch instead.
        if let r = resizeWatch { NotificationCenter.default.removeObserver(r) }
        resizeWatch = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { DropShelfController.shared.fit() }
        }
        return p
    }

    // MARK: Holding

    /// The stacks, minus files that have gone (moved or deleted elsewhere) and stacks left empty.
    static func alive(_ stacks: [[String]]) -> [[String]] {
        let fm = FileManager.default
        return stacks.map { $0.filter { fm.fileExists(atPath: $0) } }.filter { !$0.isEmpty }
    }

    /// One drop becomes one stack, newest first. A file is only ever in one stack: dropping it again moves it
    /// into the new one. There's no cap: Holding keeps everything until it's cleared.
    func hold(_ urls: [URL]) {
        var drop: [String] = []
        for u in urls where !drop.contains(u.path) { drop.append(u.path) }
        guard !drop.isEmpty else { return }
        let prefs = Preferences.shared
        let taken = Set(drop)
        var stacks = Self.alive(prefs.shelfStacks).map { $0.filter { !taken.contains($0) } }.filter { !$0.isEmpty }
        stacks.insert(drop, at: 0)
        prefs.shelfStacks = stacks
    }

    func release(_ paths: [String]) {
        let gone = Set(paths)
        Preferences.shared.shelfStacks = Self.alive(Preferences.shared.shelfStacks).map { $0.filter { !gone.contains($0) } }.filter { !$0.isEmpty }
    }
    func releaseAll() { Preferences.shared.shelfStacks = [] }

    /// After a drag out of Holding: anything another app moved away leaves Holding.
    func pruneHolding() {
        let prefs = Preferences.shared
        let a = Self.alive(prefs.shelfStacks)
        if a != prefs.shelfStacks { prefs.shelfStacks = a }
    }

    /// A drag out of Holding began: stay out while the button is down (so a shelf folder can take it too), then
    /// tuck away as usual, instead of hiding mid-drag and popping back up because the drag pasteboard changed.
    func draggingOut() {
        trigger = .drag
        outsideTicks = 0
        dragBaseline = NSPasteboard(name: .drag).changeCount
    }

    func put(_ urls: [URL], in folder: URL) {
        let done = FileDrop.put(urls, in: folder, copy: FileDrop.optionHeld)
        // Anything filed from Holding leaves Holding.
        if !done.copied { release(done.moves.map(\.from.path)) }
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
    /// Opened because a file drag started, so the hint is about where to drop.
    var openedByDrag = false
    /// For design snapshots: show this stack open with these files selected.
    var initialOpen: [String] = []
    var initialSelected: Set<String> = []

    @Environment(AppState.self) private var state
    @State private var overHolding = false
    @State private var overFolder: URL?
    /// The stack shown open, remembered by its files: it's whichever stack still holds any of them.
    @State private var openMembers: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var lastClicked: String?

    static let cell: CGFloat = 48
    static let columns = 7
    /// Holding when no stack is open; the pinned folders are drawn exactly this tall so the two line up.
    static let closedHeight: CGFloat = 114

    private var stacks: [[String]] { DropShelfController.alive(state.prefs.shelfStacks) }
    private var openStack: [String]? {
        guard !openMembers.isEmpty else { return nil }
        return stacks.first { !openMembers.isDisjoint(with: $0) }
    }

    var body: some View {
        let onNotch = notch > 0
        let open = openStack
        let size = holdingSize(open)
        let hint = hint(open)
        VStack(alignment: .leading, spacing: 10) {
            if onNotch { Color.clear.frame(height: notch) }
            HStack(alignment: .top, spacing: 14) {
                holding(open, size: size)
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: size.height)
                folders
            }
            HStack {
                Text(hint).font(DS.caption).foregroundStyle(.secondary)
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
        .onChange(of: "\(size.width)x\(size.height)|\(hint)") {
            // Let SwiftUI lay out the new size first, then grow or shrink the panel to it.
            DispatchQueue.main.async { DropShelfController.shared.fit() }
        }
        .onAppear {
            if !initialOpen.isEmpty { openMembers = Set(initialOpen); selected = initialSelected }
        }
    }

    private func holdingSize(_ open: [String]?) -> CGSize {
        if let open {
            let rows = (open.count + Self.columns - 1) / Self.columns
            // Up to three rows show at once; more scroll. The extra 6 leaves room for the selection checks.
            let grid = CGFloat(min(rows, 3)) * (Self.cell + 10) - 10 + 6
            return CGSize(width: 412, height: max(Self.closedHeight, 10 + 16 + 8 + grid + 10))
        }
        let n = CGFloat(max(stacks.count, 1))
        return CGSize(width: min(max(20 + n * 62 + (n - 1) * 8, 176), 372), height: Self.closedHeight)
    }

    private func hint(_ open: [String]?) -> String {
        if let open {
            let n = open.filter(selected.contains).count
            switch n {
            case 0: return "Click to select  ·  drag to take one"
            case 1: return "1 selected  ·  drag it out"
            default: return "\(n) selected  ·  drag any of them to take all \(n)"
            }
        }
        if !openedByDrag, stacks.contains(where: { $0.count > 1 }) { return "Drag a stack to take all of it  ·  click to open" }
        return "Drop on a folder to move it there  ·  hold ⌥ to copy"
    }

    /// "20 pictures", "3 videos", "12 files"
    static func title(_ paths: [String]) -> String {
        let types = paths.map { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        let noun = types.allSatisfy({ $0?.conforms(to: .image) == true }) ? "picture"
            : types.allSatisfy({ $0?.conforms(to: .movie) == true }) ? "video" : "file"
        return Fmt.plural(paths.count, noun)
    }

    private func openUp(_ stack: [String]) { openMembers = Set(stack); selected = []; lastClicked = nil }
    private func close() { openMembers = []; selected = []; lastClicked = nil }

    /// Click toggles one; shift-click selects the run from the last one clicked.
    private func click(_ path: String, in stack: [String], _ mods: NSEvent.ModifierFlags) {
        if mods.contains(.shift), let last = lastClicked, let a = stack.firstIndex(of: last), let b = stack.firstIndex(of: path) {
            selected.formUnion(stack[min(a, b)...max(a, b)])
        } else if selected.contains(path) {
            selected.remove(path)
        } else {
            selected.insert(path)
        }
        lastClicked = path
    }

    /// Dragging a selected file takes every selected one; dragging any other takes just that file.
    private func taking(_ path: String, in stack: [String]) -> [String] {
        selected.contains(path) ? stack.filter(selected.contains) : [path]
    }

    private func holding(_ open: [String]?, size: CGSize) -> some View {
        let total = stacks.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let open {
                    Button { close() } label: {
                        HStack(spacing: 5) { Image(systemName: "chevron.left"); Text(Self.title(open)) }
                    }
                    .buttonStyle(.plainHand).help("Back to Holding").handCursor()
                    Spacer()
                    let all = open.allSatisfy(selected.contains)
                    Button(all ? "Select none" : "Select all") { selected = all ? [] : Set(open) }
                        .buttonStyle(.plainHand).foregroundStyle(Color.accentColor).handCursor()
                } else {
                    Image(systemName: "tray")
                    Text(total == 0 ? "Holding" : "Holding · \(total)")
                    Spacer()
                    if total > 0 {
                        Button { DropShelfController.shared.releaseAll() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plainHand).foregroundStyle(.secondary).help("Clear Holding").handCursor()
                    }
                }
            }
            .font(DS.bodySM).foregroundStyle(.primary)
            if let open {
                openGrid(open)
            } else if stacks.isEmpty {
                Text("Drop here to keep it for a moment, then drag it out in another app")
                    .font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(stacks, id: \.first) { stack in
                            if stack.count == 1 { HeldSingle(path: stack[0]) } else { HeldStack(paths: stack) { openUp(stack) } }
                        }
                    }
                    // The scroll view clips at its edges: leave room for the count badges that sit above each pile.
                    .padding(.top, 5)
                }
            }
        }
        .padding(10)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(overHolding ? 0.14 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(overHolding ? Color.accentColor : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: overHolding ? 2 : 1, dash: stacks.isEmpty ? [5, 4] : [])))
        .onDrop(of: [.fileURL], isTargeted: $overHolding) { providers in
            Task { @MainActor in DropShelfController.shared.hold(await FileDrop.urls(from: providers)) }
            return true
        }
    }

    private func openGrid(_ open: [String]) -> some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: 8), count: Self.columns), alignment: .leading, spacing: 10) {
                ForEach(open, id: \.self) { path in
                    HeldPick(path: path, selected: selected.contains(path),
                             click: { click(path, in: open, $0) },
                             taking: { taking(path, in: open) })
                }
            }
            .padding(.top, 6).padding(.trailing, 6)
        }
    }

    private var folders: some View {
        HStack(spacing: 10) {
            ForEach(FileDrop.targets.prefix(4), id: \.self) { folder in
                let pv = state.pinnedPreviews[folder.path]
                let kind = pv?.items.first?.category ?? .documents
                GlassFolder(title: FileManager.default.displayName(atPath: folder.path),
                            meta: pv.map { "\(Fmt.count($0.count)) items" } ?? "",
                            palette: .of(kind), style: .of(kind), items: pv?.items ?? [], width: Self.closedHeight * 200 / 168)
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

@MainActor private func fileMenu(_ paths: [String]) -> [(String, () -> Void)] {
    [("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }),
     ("Remove from Holding", { MainActor.assumeIsolated { DropShelfController.shared.release(paths) } })]
}

/// Several files dropped together: a little pile with a count. Drag it to take them all; click it to see them.
private struct HeldStack: View {
    let paths: [String]
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        let top = Array(Array(paths.prefix(3).enumerated()).reversed())
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    ForEach(top, id: \.offset) { i, path in
                        HeldThumb(path: path, size: 40)
                            .rotationEffect(.degrees([0, -9, 11][i]))
                            .offset(x: [0, 6, -6][i], y: [0, -3, 1][i])
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    }
                }
                .frame(width: 58, height: 50)
                Text(Fmt.count(paths.count))
                    .font(DS.caption).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1.5))
                    .offset(x: 4, y: -3)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.14 : 0)))
            .overlay(FileDragSource(urls: { paths.map { URL(fileURLWithPath: $0) } }, onClick: { _ in open() },
                                    onHover: { hovering = $0 }, tip: "Drag to take all \(paths.count)  ·  click to see them",
                                    menu: fileMenu(paths)))
            Text(DropShelfView.title(paths)).font(DS.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 62)
        }
    }
}

/// A file dropped on its own: drag it out into any app.
private struct HeldSingle: View {
    let path: String
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 3) {
            HeldThumb(path: path, size: 40)
                .frame(width: 58, height: 50)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.14 : 0)))
                .overlay(FileDragSource(urls: { [URL(fileURLWithPath: path)] }, onHover: { hovering = $0 },
                                        tip: (path as NSString).lastPathComponent, menu: fileMenu([path])))
            Text((path as NSString).lastPathComponent).font(DS.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: 62)
        }
    }
}

/// A file inside an open stack: click to select it, drag to take it (and everything else selected).
private struct HeldPick: View {
    let path: String
    let selected: Bool
    let click: (NSEvent.ModifierFlags) -> Void
    let taking: () -> [String]
    @State private var hovering = false
    var body: some View {
        HeldThumb(path: path, size: DropShelfView.cell)
            .brightness(hovering && !selected ? 0.08 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: DropShelfView.cell * 0.17, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 15, weight: .semibold))
                        .background(Circle().fill(Color.black).padding(-1.5))
                        .offset(x: 5, y: -5)
                }
            }
            .overlay(FileDragSource(urls: { taking().map { URL(fileURLWithPath: $0) } }, onClick: click,
                                    onHover: { hovering = $0 }, tip: (path as NSString).lastPathComponent,
                                    menu: fileMenu(selected ? taking() : [path])))
    }
}

/// The file's own picture (a photo, a PDF's first page, a frame of a video), else its icon.
private struct HeldThumb: View {
    let path: String
    let size: CGFloat
    @State private var preview: HeldPreviews.Preview?

    init(path: String, size: CGFloat) {
        self.path = path
        self.size = size
        _preview = State(initialValue: HeldPreviews.shared.cached(path))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
        ZStack {
            if let p = preview {
                if p.isIcon {
                    Image(nsImage: p.image).resizable().scaledToFit()
                } else {
                    Image(nsImage: p.image).resizable().scaledToFill()
                        .frame(width: size, height: size).clipShape(shape)
                        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                }
            } else {
                shape.fill(Color.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .task(id: path) { if preview == nil { preview = await HeldPreviews.shared.preview(path) } }
    }
}

final class HeldPreviews: @unchecked Sendable {
    static let shared = HeldPreviews()
    struct Preview { let image: NSImage; let isIcon: Bool }
    private final class Box { let preview: Preview; init(_ p: Preview) { preview = p } }
    private let cache = NSCache<NSString, Box>()

    private func key(_ path: String) -> NSString {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(modified)" as NSString
    }

    func cached(_ path: String) -> Preview? { cache.object(forKey: key(path))?.preview }

    func preview(_ path: String) async -> Preview {
        let k = key(path)
        if let b = cache.object(forKey: k) { return b.preview }
        let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 96, height: 96),
                                               scale: 2, representationTypes: .all)
        let p: Preview
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            p = Preview(image: rep.nsImage, isIcon: rep.type == .icon)
        } else {
            p = Preview(image: NSWorkspace.shared.icon(forFile: path), isIcon: true)
        }
        cache.setObject(Box(p), forKey: k)
        return p
    }
}

// MARK: - Dragging files out

/// Clicks and drags for files in Holding. It's AppKit because a SwiftUI drag carries only one file: a click calls
/// `onClick`, and a drag carries every file `urls()` returns, into any app.
private struct FileDragSource: NSViewRepresentable {
    let urls: () -> [URL]
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var tip: String?
    var menu: [(String, () -> Void)] = []

    func makeNSView(context: Context) -> FileDragView { FileDragView() }
    func updateNSView(_ v: FileDragView, context: Context) {
        v.urls = urls
        v.onClick = onClick
        v.onHover = onHover
        v.menuItems = menu
        v.toolTip = tip
    }
}

private final class FileDragView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var menuItems: [(String, () -> Void)] = []
    private var downAt: NSPoint?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true); NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { onHover(false); NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragged = false
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        if downAt != nil, !dragged { onClick(event.modifierFlags) }
        downAt = nil
        NSCursor.openHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, !dragged else { return }
        let at = event.locationInWindow
        guard hypot(at.x - start.x, at.y - start.y) > 3 else { return }
        dragged = true
        let list = urls()
        guard !list.isEmpty else { return }
        let side = min(bounds.width, bounds.height, 56)
        let items = list.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = HeldPreviews.shared.cached(url.path)?.image ?? NSWorkspace.shared.icon(forFile: url.path)
            let o = CGFloat(min(i, 3)) * 4
            item.setDraggingFrame(NSRect(x: bounds.midX - side / 2 + o, y: bounds.midY - side / 2 - o, width: side, height: side), contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        if items.count > 1 { session.draggingFormation = .pile }
        MainActor.assumeIsolated { DropShelfController.shared.draggingOut() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for (title, run) in menuItems { menu.addItem(ClosureMenuItem(title, run)) }
        return menu
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { DropShelfController.shared.pruneHolding() }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
