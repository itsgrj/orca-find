import SwiftUI
import AppKit

final class QuickSearchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class QuickSearchModel {
    var query = "" { didSet { if query != oldValue { schedule() } } }
    var results: [FileItem] = []
    var parsed = ParsedQuery()
    var selected = 0
    var focusToken = 0
    var understanding = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var shown: [FileItem] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? Array(AppState.shared.homeStats.latestDownloads.prefix(8)) : results
    }

    func schedule() {
        task?.cancel()
        let text = query
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var q = QueryParser.parse(text)
            if let r = SentenceUnderstanding.cache[key] { q = QueryParser.merge(q, r, dismissed: []) }
            await self.show(q)
            // Same sentence understanding as the main window, once typing pauses.
            guard SentenceUnderstanding.cache[key] == nil, Preferences.shared.smartSentences,
                  SentenceUnderstanding.worthRefining(text), SentenceUnderstanding.status == .available else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self.understanding = true
            let r = await SentenceUnderstanding.refine(text)
            self.understanding = false
            guard !Task.isCancelled, let r else { return }
            SentenceUnderstanding.cache[key] = r
            await self.show(QueryParser.merge(QueryParser.parse(text), r, dismissed: []))
        }
    }

    private func show(_ q: ParsedQuery) async {
        let items = FileIndex.shared.items
        let found = await Task.detached(priority: .userInitiated) { SearchEngine.run(q, in: items, limit: 40) }.value
        guard !Task.isCancelled else { return }
        parsed = q
        results = found
        selected = 0
    }

    func move(_ delta: Int) {
        let n = shown.count
        guard n > 0 else { return }
        selected = max(0, min(n - 1, selected + delta))
    }

    var current: FileItem? { shown.indices.contains(selected) ? shown[selected] : nil }
}

@MainActor
final class QuickSearchController: NSObject, NSWindowDelegate {
    static let shared = QuickSearchController()
    let model = QuickSearchModel()
    private var panel: QuickSearchWindow?
    private var monitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show(query: String? = nil) {
        if panel == nil { build() }
        guard let panel else { return }
        if let query { model.query = query }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - f.height * 0.16))
        }
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        installMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        if VoiceSearch.shared.owner == "quick" { VoiceSearch.shared.stop() }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func build() {
        let p = QuickSearchWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
                                  styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        let root = QuickSearchView(model: model)
            .environment(AppState.shared)
            .focusEffectDisabled()
        let host = NSHostingView(rootView: root)
        host.frame = p.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            if !VoiceSearch.shared.isListening { hide() }
        }
    }

    private func installMonitor() {
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let window = event.window
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let panel = QuickSearchController.shared.panel, window === panel else { return false }
                return QuickSearchController.shared.handle(keyCode: keyCode, flags: flags)
            }
            return handled ? nil : event
        }
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        switch Int(keyCode) {
        case 125: model.move(1); return true                 // ↓
        case 126: model.move(-1); return true                // ↑
        case 53: hide(); return true                         // esc
        case 36, 76:                                          // return
            guard let item = model.current else { return true }
            hide()
            if mods.contains(.command) {
                AppState.shared.revealInApp(item)
            } else if mods.contains(.option) {
                FileActions.revealInFinder([item])
            } else {
                FileActions.open([item])
            }
            return true
        default:
            return false
        }
    }
}

struct QuickSearchView: View {
    @Environment(AppState.self) private var state
    @Bindable var model: QuickSearchModel
    @FocusState private var focused: Bool

    var body: some View {
        let listening = state.voice.isListening && state.voice.owner == "quick"
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(DS.text)
                TextField("", text: $model.query, prompt: Text("Find any file…").foregroundStyle(DS.text3))
                    .textFieldStyle(.plain).font(DS.px(20)).foregroundStyle(DS.text)
                    .focused($focused)
                if listening { VoiceLevelView(level: state.voice.level) }
                Kbd(state.prefs.quickSearchHotKey.display)
                if state.prefs.voiceEnabled {
                    MicButton(active: listening, size: 34) {
                        state.voice.toggle(owner: "quick", onUpdate: { model.query = $0 }, onFinish: { _ in })
                    }
                }
            }
            .padding(.horizontal, 18).frame(height: 62)

            if !model.parsed.chips.isEmpty && !model.query.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        PixelLabel("Understood as")
                        ForEach(model.parsed.chips) { Chip(label: $0.label, symbol: [.looks, .colour].contains($0.kind) ? "sparkles" : nil, style: .understood) }
                        if model.understanding { Badge("✦ Reading your sentence…", tone: .magic) }
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.bottom, 10)
            }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)

            let shown = model.shown
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        PixelLabel(model.query.isEmpty ? "Latest downloads" : "Best matches").padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                            QuickRow(item: item, selected: i == model.selected, reason: SearchEngine.reason(for: item, model.parsed))
                                .id(item.id)
                                .onTapGesture {
                                    model.selected = i
                                    if NSApp.currentEvent?.clickCount ?? 1 >= 2 { QuickSearchController.shared.hide(); FileActions.open([item]) }
                                }
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                        }
                        if shown.isEmpty && !model.query.isEmpty {
                            Text("No files match — try saying it differently").font(DS.body).foregroundStyle(DS.text2).padding(30).frame(maxWidth: .infinity)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selected) { _, i in if shown.indices.contains(i) { proxy.scrollTo(shown[i].id) } }
            }

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            HStack(spacing: 16) {
                hint("↩", "Open"); hint("⌘↩", "Show in OrcaFind"); hint("⌥↩", "Show in Finder")
                Spacer()
                hint("esc", "Close")
            }
            .padding(.horizontal, 16).frame(height: 36)
        }
        .frame(width: 700, height: 480)
        // Follows light and dark mode, like the rest of the app.
        .background(ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [Color.dyn(0xFFFFFF, 0x1B1F26).opacity(0.55), Color.dyn(0xFFFFFF, 0x1B1F26).opacity(0.75)], startPoint: .top, endPoint: .bottom)
        })
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.dyn(0xFFFFFF, 0x3A404A).opacity(0.75)))
        .onChange(of: model.focusToken) { _, _ in DispatchQueue.main.async { focused = true } }
        .onAppear { focused = true }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) { Kbd(key); Text(label).font(DS.caption).foregroundStyle(DS.text2) }
    }
}

private struct QuickRow: View {
    let item: FileItem
    let selected: Bool
    var reason: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Thumb(item: item, size: 80, mode: item.category == .images || item.category == .videos ? .fill : (item.category == .documents ? .page : .fit))
                .frame(width: 38, height: 40).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(DS.body).lineLimit(1).truncationMode(.middle)
                Text(reason.map { $0 + " · " + Fmt.relative(item.activityDate) }
                     ?? [item.parentName, Fmt.size(item.size), Fmt.relative(item.activityDate)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(DS.caption).opacity(0.75).lineLimit(1)
            }
            Spacer()
            if let s = item.source { Badge(s.name, tone: selected ? .neutral : .info) }
            if selected { Text("↩").font(.system(size: 12, weight: .medium)) }
        }
        .foregroundStyle(selected ? DS.onBrand : DS.text)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? DS.brand : .clear))
        .contentShape(Rectangle())
    }
}
