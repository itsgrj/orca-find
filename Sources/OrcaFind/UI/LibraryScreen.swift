import SwiftUI

struct LibraryScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let stats = state.homeStats
        GeometryReader { geo in
            let width = geo.size.width - 64
            let w = min(200, (width - 16 * 5) / 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ScreenHeader(title: "Library", subtitle: "\(Fmt.count(stats.totalCount)) files · \(Fmt.size(stats.totalSize)) on this Mac") {
                        HStack(spacing: 8) {
                            Button { state.newFolderSheet() } label: { Label("New smart folder", systemImage: "folder.badge.plus") }.buttonStyle(.primary)
                            Button { pickFolder() } label: { Label("Pin a folder…", systemImage: "pin") }.buttonStyle(.secondary)
                        }
                    }
                    section("Kinds") {
                        HStack(spacing: 16) {
                            ForEach(FileCategory.library) { c in
                                GlassFolder(title: c.title, meta: "\(Fmt.count(stats.counts[c] ?? 0)) · \(Fmt.size(stats.sizes[c] ?? 0))",
                                            palette: .of(c), style: .of(c), items: stats.recentBy[c] ?? [], width: w) { state.navigate(.category(c)) }
                            }
                        }
                    }
                    section("Smart folders") {
                        FlowLayout(spacing: 16) {
                            if !state.hiddenBuiltins.contains(BuiltinFolder.recents.rawValue) {
                                GlassFolder(title: "Recents", meta: "\(Fmt.count(stats.recentCount)) · last 30 days", palette: .of(.documents), style: .sheets,
                                            items: Array(stats.recentAll.filter { $0.category == .documents }.prefix(3)), width: w) { state.navigate(.recents) }
                                    .contextMenu { builtinMenu(.recents) }
                            }
                            if !state.hiddenBuiltins.contains(BuiltinFolder.large.rawValue) {
                                GlassFolder(title: "Large files", meta: "\(Fmt.count(stats.largeFiles)) · \(state.prefs.largeFileMB) MB+", palette: .of(.videos), style: .icons,
                                            items: stats.largeItems, width: w) { state.navigate(.largeFiles) }
                                    .contextMenu { builtinMenu(.large) }
                            }
                            if !state.hiddenBuiltins.contains(BuiltinFolder.screenshots.rawValue) {
                                GlassFolder(title: "Screenshots", meta: "\(Fmt.count(stats.screenshots)) files", palette: .of(.images), style: .prints,
                                            items: stats.screenshotItems, width: w) { state.navigate(.screenshots) }
                                    .contextMenu { builtinMenu(.screenshots) }
                            }
                            ForEach(state.smartFolders) { f in SmartFolderTile(folder: f, width: w) }
                            AddTile(title: "New smart folder", width: w) { state.newFolderSheet() }
                                .help("A folder that fills itself: describe it or pick rules (⇧⌘N)")
                        }
                    }
                    section("Pinned") {
                        FlowLayout(spacing: 16) {
                            ForEach(state.pinnedFolders, id: \.self) { path in
                                let pv = state.pinnedPreviews[path]
                                let kind = pv?.items.first?.category ?? .documents
                                GlassFolder(title: FileManager.default.displayName(atPath: path), meta: "\(Fmt.count(pv?.count ?? 0)) items · pinned",
                                            palette: .of(kind), style: .of(kind), items: pv?.items ?? [], width: w) { state.navigate(.folder(path)) }
                                    .contextMenu {
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                        Button("Unpin", role: .destructive) { state.unpin(path) }
                                    }
                            }
                            AddTile(title: "Pin a folder", width: w) { pickFolder() }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
            }
        }
    }

    @ViewBuilder private func builtinMenu(_ b: BuiltinFolder) -> some View {
        Button("Open") {
            switch b {
            case .recents: state.navigate(.recents)
            case .large: state.navigate(.largeFiles)
            case .screenshots: state.navigate(.screenshots)
            }
        }
        Divider()
        Button("Hide from Library") { state.hideBuiltin(b) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { PixelLabel(title); content() }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true; p.prompt = "Pin"
        guard p.runModal() == .OK else { return }
        for u in p.urls { state.pinFolder(u.path) }
    }
}

// MARK: - Browse a kind / smart folder / pinned folder / saved search

struct BrowseScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var prefs = state.prefs
        let items = state.visibleItems
        VStack(alignment: .leading, spacing: 14) {
            header
            if let f = smartFolder { SmartFolderRules(folder: f) }
            HStack(spacing: 8) {
                FilterMenus(showKind: !isCategory)
                Spacer()
                SortMenu()
                HStack(spacing: 2) {
                    IconBtn(symbol: "square.grid.2x2", selected: prefs.viewMode == .grid, help: "Grid (⌘1)") { prefs.viewMode = .grid }
                    IconBtn(symbol: "list.bullet", selected: prefs.viewMode == .list, help: "List (⌘2)") { prefs.viewMode = .list }
                }
                .padding(2).background(RoundedRectangle(cornerRadius: 9).fill(DS.tertiary.opacity(0.6)))
                if prefs.viewMode == .grid {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(DS.text2)
                        Slider(value: $prefs.cardSize, in: 110...320).frame(width: 90).controlSize(.mini)
                        Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(DS.text2)
                    }
                    .help("Card size (⌘+ / ⌘−)")
                }
                IconBtn(symbol: "sidebar.right", selected: state.showInspector, help: "Inspector (⌘I)") { state.showInspector.toggle() }
            }
            HStack(alignment: .top, spacing: 16) {
                if items.isEmpty {
                    VStack {
                        if state.isRefreshing { ProgressView().controlSize(.large).padding(60) }
                        else { emptyState }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if prefs.viewMode == .grid {
                    GeometryReader { geo in
                        ScrollViewReader { proxy in
                            ScrollView {
                                CardGrid(items: items, width: geo.size.width, target: CGFloat(prefs.cardSize) + 30,
                                         snippets: smartFolder == nil ? [:] : SmartFolder.newLabels(items, since: state.folderSeenBefore))
                                    .padding(.bottom, 80)
                            }
                            .onChange(of: state.scrollTarget) { _, t in if let t { withAnimation { proxy.scrollTo(t) }; state.scrollTarget = nil } }
                        }
                    }
                } else {
                    FileTable(items: items).card(14)
                }
                if state.showInspector, state.selection.count == 1, let sel = state.selectedItems.first {
                    InspectorPanel(item: sel, terms: []).frame(width: 330).id(sel.id)
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 12)
        .overlay(alignment: .bottom) { SelectionBar() }
        .animation(.easeOut(duration: 0.2), value: state.selection.count)
    }

    private var isCategory: Bool { if case .category = state.section { return true }; return false }
    private var smartFolder: SmartFolder? { if case .smartFolder(let id) = state.section { return state.folder(id) }; return nil }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("Library") { state.navigate(.library) }.buttonStyle(.plain).font(DS.body).foregroundStyle(DS.text2)
            if case .folder(let path) = state.section {
                ForEach(crumbs(path), id: \.1) { name, p in
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.text3)
                    if p == path { Text(name).font(DS.headingLG).foregroundStyle(DS.text) }
                    else { Button(name) { state.navigate(.folder(p)) }.buttonStyle(.plain).font(DS.body).foregroundStyle(DS.text2) }
                }
            } else {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.text3)
                Text(state.title(for: state.section)).font(DS.headingLG).foregroundStyle(DS.text)
            }
            if smartFolder != nil { Badge("Smart folder", tone: .magic) }
            Text(state.visibleItems.isEmpty ? "" : "\(Fmt.plural(state.visibleItems.count, "item")) · \(Fmt.size(state.visibleSize))\(smartFolder != nil ? " · updates itself" : "")")
                .font(DS.body).foregroundStyle(DS.text2)
            Spacer()
            if let f = smartFolder {
                Button { state.editRules(f.id) } label: { Label("Edit rules", systemImage: "slider.horizontal.3") }.buttonStyle(.secondary)
                Menu { SmartFolderMenu(folder: f, includeOpen: false) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text).frame(width: 28, height: 28)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("More")
            }
        }
    }

    private func crumbs(_ path: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var p = path
        let home = NSHomeDirectory()
        while p.count > 1 && out.count < 4 {
            out.insert((FileManager.default.displayName(atPath: p), p), at: 0)
            if p == home { break }
            p = (p as NSString).deletingLastPathComponent
        }
        return out
    }

    @ViewBuilder private var emptyState: some View {
        if state.filters.isActive {
            EmptyState(symbol: "line.3.horizontal.decrease", tag: "No matches", title: "No files match these filters", message: "Clear a filter to see more.",
                       actions: AnyView(Button("Clear filters") { state.filters = BrowserFilters() }.buttonStyle(.primary)))
        } else if let f = smartFolder {
            EmptyState(symbol: "folder.badge.gearshape", tag: "Nothing yet", title: "Nothing here yet",
                       message: "New files that match these rules will show up here on their own.",
                       actions: AnyView(Button("Edit rules") { state.editRules(f.id) }.buttonStyle(.secondary)))
        } else if case .folder = state.section {
            EmptyState(symbol: "folder", tag: "Empty", title: "This folder is empty", message: "Files you add here show up straight away.")
        } else {
            EmptyState(symbol: "tray", tag: "Nothing yet", title: "Nothing here yet", message: "When files like this appear in your folders, they'll show up here.")
        }
    }
}

struct FileTable: View {
    @Environment(AppState.self) private var state
    let items: [FileItem]
    @State private var order: [KeyPathComparator<FileItem>] = []

    var body: some View {
        @Bindable var st = state
        Table(of: FileItem.self, selection: $st.selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 8) {
                    Thumb(item: item, size: 24, mode: item.category == .images || item.category == .videos ? .fill : .fit)
                        .frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(item.name).font(DS.body).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 240, ideal: 360)
            TableColumn("Kind", value: \.kindName) { Text($0.kindName).font(DS.bodySM).foregroundStyle(DS.text2) }.width(min: 80, ideal: 130)
            TableColumn("Size", value: \.size) { Text($0.isFolder ? "—" : Fmt.size($0.size)).font(DS.bodySM).foregroundStyle(DS.text2) }.width(min: 60, ideal: 80)
            TableColumn("Date", value: \.sortDate) { Text(Fmt.date($0.activityDate)).font(DS.bodySM).foregroundStyle(DS.text2) }.width(min: 110, ideal: 150)
            TableColumn("From", value: \.sourceName) { item in
                if let s = item.source { Badge(s.name, tone: .info) } else { Text("") }
            }
            .width(min: 70, ideal: 110)
        } rows: {
            ForEach(items) { item in TableRow(item).itemProvider { NSItemProvider(object: item.url as NSURL) } }
        }
        .scrollContentBackground(.hidden)
        // Table's header is an opaque, square NSTableHeaderView — clip it so it
        // follows the card's rounded corners instead of poking out of them.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu(forSelectionType: String.self) { ids in FileMenu(items: items.filter { ids.contains($0.id) }) } primaryAction: { ids in state.activate(ids: ids) }
        .onChange(of: order) { _, o in
            guard let f = o.first else { return }
            let field: SortField
            switch f.keyPath {
            case \FileItem.name: field = .name
            case \FileItem.size: field = .size
            case \FileItem.kindName: field = .kind
            default: field = .date
            }
            state.sort = SortSpec(field: field, ascending: f.order == .forward)
        }
    }
}

// MARK: - Recents

struct RecentsScreen: View {
    @Environment(AppState.self) private var state
    @State private var kind: FileCategory?

    var body: some View {
        let items = state.visibleItems.filter { kind == nil || $0.category == kind }
        let groups = Self.group(items)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button("Library") { state.navigate(.library) }.buttonStyle(.plain).font(DS.body).foregroundStyle(DS.text2)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.text3)
                Text("Recents").font(DS.headingLG).foregroundStyle(DS.text)
                Text("\(Fmt.plural(items.count, "file")) in the last 30 days").font(DS.body).foregroundStyle(DS.text2)
                Spacer()
                ForEach([nil, FileCategory.images, .videos, .documents, .music, .archives], id: \.self) { k in
                    Button { kind = k } label: { Chip(label: k?.title ?? "All", symbol: k.map(KindPalette.symbol) ?? "square.grid.2x2", style: kind == k ? .selected : .normal) }
                        .buttonStyle(.plain)
                }
            }
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.0) { title, list in
                            PixelLabel(title)
                            CardGrid(items: list, width: geo.size.width, target: 180, aspect: 0.97)
                        }
                    }
                    .padding(.bottom, 80)
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 22)
        .overlay(alignment: .bottom) { SelectionBar() }
    }

    static func group(_ items: [FileItem]) -> [(String, [FileItem])] {
        let cal = Calendar.current
        var buckets: [(String, [FileItem])] = [("Today", []), ("Yesterday", []), ("Earlier this week", []), ("Earlier this month", [])]
        for i in items {
            let d = i.activityDate
            if cal.isDateInToday(d) { buckets[0].1.append(i) }
            else if cal.isDateInYesterday(d) { buckets[1].1.append(i) }
            else if d > Date().addingTimeInterval(-7 * 86_400) { buckets[2].1.append(i) }
            else { buckets[3].1.append(i) }
        }
        return buckets.filter { !$0.1.isEmpty }
    }
}
