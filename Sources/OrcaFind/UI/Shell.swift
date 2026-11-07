import SwiftUI
import AppKit

struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var st = state
        ZStack(alignment: .top) {
            AppBackground(style: state.prefs.background, showArt: state.section == .home && state.searchText.isEmpty)
            VStack(spacing: 0) {
                if state.inlineChrome {
                    TopBar(inline: true).frame(height: 52).background(DS.topbar)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !state.inlineChrome {
                DS.topbar.frame(height: 52).frame(maxWidth: .infinity).ignoresSafeArea(edges: .top)
                    .overlay(WindowDragArea().ignoresSafeArea(edges: .top))
                    .allowsHitTesting(true)
            }
            if !state.prefs.onboarded {
                OnboardingView().transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(toast: toast) { state.toast = nil }
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: state.toast)
        .toolbar {
            if !state.inlineChrome {
                ToolbarItem(placement: .navigation) { BrandAndTabs() }
                ToolbarItem(placement: .primaryAction) { TrailingBar() }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(item: $st.previewItem) { item in
            LargePreview(item: item).environment(state)
        }
        .sheet(item: $st.folderSheet) { draft in
            SmartFolderSheet(draft: draft).environment(state)
        }
        .modifier(SmartFolderAlerts())
        .background(WindowAccessor { window in
            if state.mainWindow !== window {
                state.mainWindow = window
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                window.toolbarStyle = .unified
                window.minSize = NSSize(width: 1080, height: 720)
                window.backgroundColor = NSColor(hex: 0x1A1A1A)
            }
        })
        .onAppear { state.openWindowAction = openWindow }
        .navigationTitle("")
    }

    @ViewBuilder private var content: some View {
        switch state.section {
        case .home, .search: HomeScreen()
        case .library: LibraryScreen()
        case .recents: RecentsScreen()
        case .downloadedFrom: DownloadsScreen()
        case .cleanUp: TidyScreen()
        case .cleanUpReview(let k): ReviewScreen(kind: k)
        case .duplicates: DuplicatesScreen()
        default: BrowseScreen()
        }
    }
}

/// Used inline (snapshots) — the real window puts these pieces in the toolbar.
struct TopBar: View {
    var inline = false
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in Circle().fill(Color(hex: UInt32(c))).frame(width: 12, height: 12) }
            }
            BrandAndTabs()
            Spacer()
            TrailingBar()
        }
        .padding(.horizontal, 16)
    }
}

struct BrandAndTabs: View {
    @Environment(AppState.self) private var state
    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                Text("orca find").font(DS.headingSM)
            }
            .foregroundStyle(.white)
            .padding(.leading, 6)
            HStack(spacing: 2) {
                ForEach(AppSection.Tab.allCases, id: \.self) { tab in
                    let active = state.section.tab == tab
                    Button { go(tab) } label: {
                        Text(tab.rawValue).font(DS.body)
                            .foregroundStyle(active ? .white : DS.onDark2)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(active ? DS.topbarField : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
        }
    }

    private func go(_ tab: AppSection.Tab) {
        switch tab {
        case .home: state.navigate(.home)
        case .library: state.navigate(.library)
        case .downloads: state.navigate(.downloadedFrom(nil))
        case .tidy: state.navigate(.cleanUp)
        }
    }
}

struct TrailingBar: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if state.player.current != nil { MiniPlayer() }
            if state.section.tab != .home {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DS.onDark2)
                    // macOS ignores styling on a TextField prompt and paints it in the light-mode
                    // placeholder grey, which vanishes on the dark bar — so draw the placeholder ourselves.
                    TextField("", text: $query)
                        .textFieldStyle(.plain).font(DS.body).foregroundStyle(.white)
                        .background(alignment: .leading) {
                            if query.isEmpty {
                                Text("Search or ask…").font(DS.body).foregroundStyle(DS.onDark2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .focused($focused)
                        .frame(width: 210)
                        .onChange(of: query) { _, q in
                            guard !q.isEmpty else { return }
                            state.beginSearch(q)
                            query = ""
                        }
                    Button { state.navigate(.home); state.startVoiceSearch() } label: {
                        Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(DS.onDark)
                    }.buttonStyle(.plain).help("Search by voice (⌥⌘F)")
                    Kbd("⌘K", dark: true)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.topbarField))
            }
            Menu {
                if state.smartFolders.isEmpty { Text("No smart folders yet") }
                ForEach(state.smartFolders) { f in
                    let n = state.folderStats[f.id]?.newCount ?? 0
                    Button(n > 0 ? "\(f.name)  ·  \(n) new" : f.name) { state.navigate(.smartFolder(f.id)) }
                }
                Divider()
                Button("New Smart Folder…") { state.newFolderSheet() }
            } label: {
                Image(systemName: "folder.badge.gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.onDark)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            // .borderlessButton re-renders the label as a black template image; a plain-styled
            // button menu keeps our colour and sizing so it matches the moon / gear icons.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Smart folders")
            IconBtn(symbol: "moon", dark: true, help: "Light / dark (⌃⌘T)") { state.prefs.toggleDark() }
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.onDark).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help("Settings (⌘,)")
        }
    }
}

struct MiniPlayer: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let p = state.player
        HStack(spacing: 9) {
            Group {
                if let art = p.artwork { Image(nsImage: art).resizable().scaledToFill() }
                else { Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0xFFB21A)) }
            }
            .frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(DS.caption).foregroundStyle(.white).lineLimit(1)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white).frame(width: g.size.width * p.progress)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in p.seek(to: loc.x / max(1, g.size.width)) }
                }
                .frame(height: 3)
            }
            .frame(width: 120)
            Button { p.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain)
            Button { p.toggle() } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
            Button { p.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
            Button { p.stop() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(DS.onDark2)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.topbarField))
    }
}

/// Puts the caret at the end of the focused text field (instead of selecting everything).
enum Caret {
    static func toEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }
}

// MARK: - Shared screen pieces

struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var back: (String, () -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let back {
                Button(action: back.1) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold)); Text(back.0).font(DS.bodySM) }
                        .foregroundStyle(DS.link)
                }.buttonStyle(.plain)
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(DS.headingLG).foregroundStyle(DS.text)
                    if let subtitle { Text(subtitle).font(DS.body).foregroundStyle(DS.text2) }
                }
                Spacer()
                trailing
            }
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, back: (String, () -> Void)? = nil) {
        self.title = title; self.subtitle = subtitle; self.back = back; self.trailing = EmptyView()
    }
}

/// Context menu shared by every file view.
struct FileMenu: View {
    @Environment(AppState.self) private var state
    let items: [FileItem]
    var body: some View {
        let single = items.count == 1 ? items.first : nil
        Button("Quick Look") { state.toggleQuickLook() }
        Button(items.count > 1 ? "Open \(items.count) Items" : "Open") { FileActions.open(items) }
        if let s = single, s.category == .music { Button("Play") { state.player.play(s, in: state.visibleItems) } }
        Button("Show in Finder") { FileActions.revealInFinder(items) }
        Divider()
        if let s = single { Button(s.isFolder ? "Pin to Library" : "Pin Folder to Library") { state.pin(s) } }
        Button("Copy") { FileActions.copy(items) }
        Button("Copy Path") { FileActions.copyPath(items) }
        if items.contains(where: { $0.category == .images || $0.ext == "pdf" }) {
            Button("Copy Text") { state.copyTextFromSelection() }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { state.trash(items) }.disabled(items.allSatisfy(\.isFolder))
    }
}

/// Drag one file (macOS 14) or the whole selection (macOS 26) into other apps.
struct FileDrag: ViewModifier {
    let item: FileItem
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.draggable(containerItemID: item.id, containerNamespace: namespace)
        } else {
            content.onDrag { NSItemProvider(object: item.url as NSURL) }
        }
    }
}

struct FileDragContainer: ViewModifier {
    @Environment(AppState.self) private var state
    let items: [FileItem]
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .dragContainer(for: DragFile.self, in: namespace) { (ids: [String]) -> [DragFile] in
                    let lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    return ids.compactMap { lookup[$0] }.map { DragFile(id: $0.id, url: $0.url) }
                }
                .dragContainerSelection(Array(state.selection), containerNamespace: namespace)
        } else {
            content
        }
    }
}

/// Which card the pointer is over. Lives in its own observable so only the cards that read it
/// re-render when it changes — the grid (and its ForEach over thousands of items) doesn't.
@Observable final class GridHover { var id: String? }

private struct HoverCard: View {
    let hover: GridHover
    let item: FileItem
    let width: CGFloat
    let height: CGFloat
    let selected: Bool
    let snippet: String?
    var body: some View {
        GlassFileCard(item: item, width: width, height: height, selected: selected, snippet: snippet, hovering: hover.id == item.id)
    }
}

/// Grid of glass cards with selection, double-click, context menu, drag-out and keyboard support.
/// The caller passes the available width (grids inside ScrollViews can't measure it themselves).
struct CardGrid: View {
    @Environment(AppState.self) private var state
    let items: [FileItem]
    let width: CGFloat
    var target: CGFloat = 188
    var aspect: CGFloat = 1.02
    var snippets: [String: String] = [:]
    var maxRows: Int? = nil
    @Namespace private var dragSpace
    @State private var hover = GridHover()

    var body: some View {
        let spacing: CGFloat = 16
        let cols = max(1, Int((width + spacing) / (target + spacing)))
        let w = max(80, floor((width - CGFloat(cols - 1) * spacing) / CGFloat(cols)))
        let shown = maxRows.map { Array(items.prefix($0 * cols)) } ?? items
        let h = w * aspect
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: spacing, alignment: .top), count: cols), alignment: .leading, spacing: spacing) {
            ForEach(shown) { item in
                HoverCard(hover: hover, item: item, width: w, height: h, selected: state.selection.contains(item.id), snippet: snippets[item.id])
                    .id(item.id)
                    .onTapGesture { state.click(item, in: items) }
                    .contextMenu { FileMenu(items: state.selection.contains(item.id) ? state.selectedItems : [item]) }
                    .modifier(FileDrag(item: item, namespace: dragSpace))
            }
        }
        .modifier(FileDragContainer(items: shown, namespace: dragSpace))
        // One hover tracker for the whole grid. Per-card onHover made SwiftUI re-hit-test every card on
        // every scroll tick (cards slide under a still pointer) — the biggest cost when scrolling big folders.
        .onContinuousHover { phase in
            var id: String?
            if case .active(let p) = phase, p.x >= 0, p.y >= 0 {
                let col = Int(p.x / (w + spacing)), row = Int(p.y / (h + spacing))
                let inCard = p.x - CGFloat(col) * (w + spacing) <= w && p.y - CGFloat(row) * (h + spacing) <= h
                let i = row * cols + col
                if inCard, col < cols, i < shown.count { id = shown[i].id }
            }
            if hover.id != id { hover.id = id }
        }
        .onAppear { if maxRows == nil { state.gridColumns = cols } }
        .onChange(of: cols) { _, c in if maxRows == nil { state.gridColumns = c } }
    }
}

/// Floating bar shown when several files are selected.
struct SelectionBar: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let sel = state.selectedItems
        if sel.count > 1 {
            DarkPill {
                Text("\(sel.count) selected · \(Fmt.size(sel.reduce(0) { $0 + $1.size }))").font(DS.body)
                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 18)
                barButton("eye", "Quick Look") { state.toggleQuickLook() }
                barButton("doc.on.doc", "Copy") { FileActions.copy(sel) }
                barButton("folder", "Show in Finder") { FileActions.revealInFinder(sel) }
                Button { state.trash(sel) } label: {
                    Label("Move to Trash", systemImage: "trash").font(DS.bodySM).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DS.critical))
                }.buttonStyle(.plain)
                Button { state.selection = [] } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).opacity(0.7)
            }
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    private func barButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(label, systemImage: icon).font(DS.bodySM).padding(.horizontal, 8).padding(.vertical, 5) }.buttonStyle(.plain)
    }
}
