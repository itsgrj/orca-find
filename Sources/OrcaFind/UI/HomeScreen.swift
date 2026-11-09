import SwiftUI

struct HomeScreen: View {
    @Environment(AppState.self) private var state

    private var hasQuery: Bool { !state.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let q = hasQuery
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("What are you looking for?").font(DS.display).foregroundStyle(DS.text)
                Text("Type it or just say it. Orca reads file names, the text inside files and screenshots, where each download came from — and what you said about your captures.")
                    .font(DS.body).foregroundStyle(DS.text2).multilineTextAlignment(.center)
            }
            .frame(height: q ? 0 : nil)
            .opacity(q ? 0 : 1)
            .clipped()
            .padding(.top, q ? 0 : 50)
            .padding(.bottom, q ? 0 : 22)

            SearchCard(compact: q)
                .frame(maxWidth: q ? .infinity : 760)
                .padding(.horizontal, q ? 24 : 32)
                .padding(.top, q ? 16 : 0)

            if q {
                SearchResults()
            } else {
                GeometryReader { geo in
                    ScrollView { PrivateAIReminder().padding(.horizontal, 32).padding(.top, 22); HomeExtras(width: geo.size.width - 64).padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 30) }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: q)
    }
}

// MARK: - Search card

struct SearchCard: View {
    @Environment(AppState.self) private var state
    var compact: Bool
    @FocusState private var focused: Bool
    @State private var exampleIndex = 0
    @State private var editingChip: String?

    private let examples = ["the PDF with the blue cover", "screenshots with wifi password", "that photo of a dog at the beach",
                            "pdfs from last week over 5 mb", "photos of receipts from last month", "invoices from gmail"]

    var body: some View {
        @Bindable var st = state
        let listening = state.voice.isListening && state.voice.owner == "main"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: compact ? 16 : 19, weight: .medium)).foregroundStyle(DS.text2)
                TextField("", text: $st.searchText, prompt: Text("Try “\(examples[exampleIndex])”").foregroundStyle(DS.text3))
                    .textFieldStyle(.plain)
                    .font(DS.searchLG)
                    .foregroundStyle(DS.text)
                    .focused($focused)
                    .onSubmit { state.selectFirstResult() }
                    .onExitCommand { if state.searchText.isEmpty { focused = false } else { state.searchText = "" } }
                if listening { VoiceLevelView(level: state.voice.level) }
                if !state.searchText.isEmpty {
                    Button { state.searchText = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.text3) }
                        .buttonStyle(.plain).help("Clear")
                }
                if !compact { Kbd("⇧⌘Space") }
                if state.prefs.voiceEnabled {
                    MicButton(active: listening, size: compact ? 34 : 40) { state.startVoiceSearch() }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, compact ? 12 : 16)

            if listening {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").foregroundStyle(DS.text2)
                    Text(state.voice.transcript.isEmpty ? "Listening… say something like “photos from last weekend”" : "Heard “\(state.voice.transcript)”")
                        .font(DS.bodySM).foregroundStyle(DS.text2)
                    if state.voice.isOnDevice { Badge("On this Mac", tone: .success) }
                    Spacer()
                    Kbd("esc")
                    Button("Done") { state.voice.stop() }.buttonStyle(.primary)
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            }

            if compact {
                HStack(spacing: 6) {
                    if !state.parsed.chips.isEmpty { PixelLabel("Understood as") }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.parsed.chips) { c in
                                Chip(label: c.label, symbol: chipSymbol(c.kind), style: .understood) { state.removeChip(c) }
                                    .help(c.kind == .looks ? "Click to change what Orca looks for" : c.isGuess ? "Guessed by Apple Intelligence from your sentence — click × if it's wrong" : "")
                                    .handCursor(c.kind == .looks)
                                    .onTapGesture { if c.kind == .looks { editingChip = c.id } }
                                    .popover(isPresented: Binding(get: { editingChip == c.id }, set: { if !$0 { editingChip = nil } }), arrowEdge: .bottom) {
                                        LookEditor(chip: c) { editingChip = nil }.environment(state)
                                    }
                            }
                            if state.understanding {
                                Badge("✦ Reading your sentence…", tone: .magic)
                                    .transition(.opacity)
                            }
                            FilterMenus()
                        }
                    }
                    Spacer(minLength: 0)
                    Button { st.showSaveFolder = true } label: { Label("Save as smart folder", systemImage: "folder.badge.plus") }
                        .buttonStyle(.secondary).help("Keep this search as a folder in your Library — it fills itself (⌥⌘S)")
                        .popover(isPresented: $st.showSaveFolder, arrowEdge: .bottom) {
                            SaveFolderPopover { state.showSaveFolder = false }.environment(state)
                        }
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            } else if !listening {
                Rectangle().fill(DS.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    PixelLabel("Try asking")
                    FlowLayout(spacing: 8) {
                        ForEach(Array(zip(["that tiger photo I downloaded", "photos of receipts", "the PDF with the blue cover", "whiteboard photos from last week", "screenshots with wifi password"],
                                           ["photo", "sparkles", "doc.richtext", "rectangle.and.pencil.and.ellipsis", "text.viewfinder"])), id: \.0) { text, icon in
                            Button { state.searchText = text } label: { Chip(label: text, symbol: icon) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous).strokeBorder(focused ? DS.focus.opacity(0.7) : DS.border, lineWidth: focused ? 1.5 : 1))
        .shadow(color: .black.opacity(compact ? 0.05 : 0.12), radius: compact ? 2 : 24, y: compact ? 1 : 12)
        .onChange(of: state.focusSearchToken) { _, _ in focused = true; Caret.toEnd() }
        .onAppear { if compact || state.prefs.onboarded { focused = true; Caret.toEnd() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if state.searchText.isEmpty { exampleIndex = (exampleIndex + 1) % examples.count }
            }
        }
    }

    private func chipSymbol(_ k: QueryChip.Kind) -> String {
        switch k {
        case .type: return "square.stack.3d.up"
        case .date: return "calendar"
        case .size: return "scalemass"
        case .source: return "arrow.down.circle"
        case .device: return "camera"
        case .location: return "folder"
        case .name: return "textformat"
        case .text: return "text.viewfinder"
        case .looks, .colour: return "sparkles"
        case .sort: return "arrow.up.arrow.down"
        }
    }
}

/// Date / size / source filter menus (shared by search and browse screens).
struct FilterMenus: View {
    @Environment(AppState.self) private var state
    var showKind = false
    var body: some View {
        @Bindable var st = state
        HStack(spacing: 6) {
            if showKind {
                Menu {
                    Button("Any kind") { st.filters.category = nil }
                    ForEach(FileCategory.allCases) { c in Button(c.title) { st.filters.category = c } }
                } label: { Chip(label: state.filters.category?.title ?? "Any kind", symbol: "square.stack.3d.up", style: state.filters.category == nil ? .normal : .selected, menu: true) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            Menu {
                ForEach(DatePreset.allCases) { d in Button(d.title) { st.filters.date = d } }
            } label: { Chip(label: state.filters.date.title, symbol: "calendar", style: state.filters.date == .any ? .normal : .selected, menu: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                ForEach(SizePreset.allCases) { s in Button(s.title) { st.filters.size = s } }
            } label: { Chip(label: state.filters.size.title, symbol: "scalemass", style: state.filters.size == .any ? .normal : .selected, menu: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                Button("Anywhere") { st.filters.sourceKey = nil }
                Divider()
                ForEach(state.homeStats.sources.prefix(30)) { s in Button("\(s.source.name) (\(s.count))") { st.filters.sourceKey = s.id } }
            } label: {
                Chip(label: state.filters.sourceKey.flatMap { k in state.homeStats.sources.first { $0.id == k }?.source.name }.map { "From " + $0 } ?? "From anywhere",
                     symbol: "arrow.down.circle", style: state.filters.sourceKey == nil ? .normal : .selected, menu: true)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }
}

// MARK: - Home below the search box

struct HomeExtras: View {
    @Environment(AppState.self) private var state
    let width: CGFloat

    var body: some View {
        let stats = state.homeStats
        VStack(spacing: 24) {
            HStack(spacing: 8) {
                pill("New downloads", "\(stats.latestDownloads.filter { ($0.added ?? .distantPast) > Date().addingTimeInterval(-7 * 86_400) }.count)") { state.navigate(.downloadedFrom(nil)) }
                pill("Duplicate groups", state.dupes.lastScan == nil ? "…" : "\(state.dupes.groups.count)") { state.navigate(.duplicates) }
                pill("Can be freed", state.tidy.lastScan == nil ? "…" : Fmt.size(state.tidy.grandTotal)) { state.navigate(.cleanUp) }
                pill("Unused apps", "\(state.tidy.count(.unusedApps))") { state.navigate(.cleanUpReview(.unusedApps)) }
            }

            let w = min(200, (width - 16 * 5) / 6)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Your library").font(DS.headingSM).foregroundStyle(DS.text)
                        Spacer()
                        Button("Open Library tab") { state.navigate(.library) }.buttonStyle(.plainP)
                    }
                    HStack(spacing: 16) {
                        ForEach(FileCategory.library) { c in
                            GlassFolder(title: c.title, meta: "\(Fmt.count(stats.counts[c] ?? 0)) · \(Fmt.size(stats.sizes[c] ?? 0))",
                                        palette: .of(c), style: .of(c), items: stats.recentBy[c] ?? [], width: w) {
                                state.navigate(.category(c))
                            }
                        }
                    }
                }

            let onHome = state.smartFolders.filter(\.showOnHome)
            if !onHome.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Your smart folders").font(DS.headingSM).foregroundStyle(DS.text)
                        Spacer()
                        Button("New smart folder") { state.newFolderSheet() }.buttonStyle(.plainP)
                    }
                    FlowLayout(spacing: 16) {
                        ForEach(onHome) { f in SmartFolderTile(folder: f, width: w) }
                    }
                }
            }

            if !stats.recentAll.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Jump back in").font(DS.headingSM).foregroundStyle(DS.text)
                        Spacer()
                        Button("See all recents") { state.navigate(.recents) }.buttonStyle(.plainP)
                    }
                    CardGrid(items: stats.recentAll, width: width, target: 180, aspect: 1.08, maxRows: 1)
                }
            }
        }
    }

    private func pill(_ label: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(DS.bodySM).foregroundStyle(DS.text)
                Text(value).font(DS.caption).foregroundStyle(DS.text).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(DS.tertiary))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(DS.surface))
            .overlay(Capsule().strokeBorder(DS.border))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .handCursor()
    }
}

// MARK: - Results

struct SearchResults: View {
    @Environment(AppState.self) private var state
    @Environment(CaptureLibrary.self) private var library
    @State private var snippets: [String: String] = [:]
    /// V7: captures that match, shown above the files.
    @State private var captureHits: [Capture] = []

    var body: some View {
        let items = state.visibleItems
        HStack(alignment: .top, spacing: 16) {
            GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !captureHits.isEmpty {
                            CaptureSearchSection(hits: captureHits, terms: state.parsed.terms, width: geo.size.width)
                        }
                        if !(items.isEmpty && !captureHits.isEmpty && !state.isRefreshing) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.isRefreshing && items.isEmpty ? "Searching…"
                                     : items.isEmpty && state.parsed.isVisual ? WaysOutView.title(state.parsed)
                                     : "\(Fmt.plural(items.count, "result"))").font(DS.headingMD).foregroundStyle(DS.text)
                                Text(state.parsed.isVisual
                                     ? (items.isEmpty ? "looked at what's in \(Fmt.plural(VisualStore.shared.count, "picture")) on this Mac" : "matched by what's in the picture · looked at on this Mac")
                                     : "matched by name, text inside\(pictureHits(items) ? ", what's in the picture" : "") and where it came from · \(Fmt.size(state.visibleSize))").font(DS.bodySM).foregroundStyle(DS.text2)
                            }
                            Spacer()
                            SortMenu()
                        }
                        if items.isEmpty && !state.isRefreshing && state.parsed.isVisual {
                            WaysOutView(width: geo.size.width)
                        } else if items.isEmpty && !state.isRefreshing {
                            EmptyState(symbol: "magnifyingglass", tag: "No results", title: "Nothing matches “\(state.searchText)”",
                                       message: "Try removing a chip, or say it differently — for example “zips from last year”.",
                                       actions: AnyView(HStack {
                                           if let last = state.parsed.chips.last {
                                               Button("Remove “\(last.label)”") { state.removeChip(last) }.buttonStyle(.secondary)
                                           }
                                           Button("Clear filters") { state.filters = BrowserFilters() }.buttonStyle(.primary)
                                       }))
                                .frame(maxWidth: .infinity).padding(.top, 30)
                        } else {
                            CardGrid(items: items, width: geo.size.width, target: CGFloat(state.prefs.cardSize) + 30, snippets: snippets)
                        }
                        } else {
                            Text("No files match — only what you saved.").font(DS.bodySM).foregroundStyle(DS.text2)
                        }
                    }
                    .padding(.top, 16).padding(.bottom, 30)
                }
                .onChange(of: state.scrollTarget) { _, t in if let t { withAnimation { proxy.scrollTo(t) }; state.scrollTarget = nil } }
            }
            }
            if let sel = state.selectedItems.first, state.selection.count == 1 {
                InspectorPanel(item: sel, terms: state.parsed.terms)
                    .frame(width: 330)
                    .padding(.top, 16).padding(.bottom, 20)
                    .id(sel.id)
            }
        }
        .padding(.horizontal, 24)
        .task(id: items.prefix(80).map(\.id).joined() + state.parsed.terms.joined() + state.parsed.looks.map(\.word).joined() + state.parsed.coverColours.joined()) { await loadSnippets(items) }
        .task(id: "\(state.parsed.raw)|\(state.parsed.terms)|\(library.version)") {
            let q = state.parsed
            captureHits = await Task.detached(priority: .userInitiated) { CaptureSearch.find(q) }.value
        }
        .overlay(alignment: .bottom) { SelectionBar() }
    }

    /// A plain-words search where MobileCLIP also found pictures ("a business card").
    private func pictureHits(_ items: [FileItem]) -> Bool {
        state.parsed.scene != nil && items.prefix(40).contains { SearchEngine.reason(for: $0, state.parsed) != nil }
    }

    private func loadSnippets(_ items: [FileItem]) async {
        let terms = state.parsed.terms
        let q = state.parsed
        guard !terms.isEmpty || q.isVisual else { snippets = [:]; return }
        let targets = Array(items.prefix(80))
        let found = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            var out: [String: String] = [:]
            // A short reason when the match came from looking at the file (S6 C: card + inspector).
            for item in targets { if let r = SearchEngine.reason(for: item, q) { out[item.id] = r } }
            guard !terms.isEmpty else { return out }
            for item in targets where out[item.id] == nil && (item.hasText || item.category == .documents) {
                guard let text = Database.shared.text(for: item.path), !text.isEmpty else { continue }
                if let s = Snippet.make(text, terms: terms) { out[item.id] = s }
            }
            return out
        }.value
        snippets = found
    }
}

struct SortMenu: View {
    @Environment(AppState.self) private var state
    var body: some View {
        @Bindable var st = state
        Menu {
            ForEach(state.section == .search ? SortField.allCases : SortField.allCases.filter { $0 != .relevance }) { f in
                Button {
                    if st.sort.field == f { st.sort.ascending.toggle() } else { st.sort = SortSpec(field: f, ascending: f == .name || f == .kind) }
                } label: {
                    if state.sort.field == f { Label(f.title, systemImage: state.sort.ascending ? "chevron.up" : "chevron.down") } else { Text(f.title) }
                }
            }
        } label: { Chip(label: "Sort: \(state.sort.field == .relevance ? "Best match" : state.sort.field.title)", symbol: "line.3.horizontal.decrease", menu: true) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

enum Snippet {
    static func make(_ text: String, terms: [String]) -> String? {
        let flat = text.replacingOccurrences(of: "\n", with: "  ")
        for t in terms {
            let stem = SearchEngine.stem(t)
            if let r = flat.range(of: stem, options: [.caseInsensitive, .diacriticInsensitive]) {
                let start = flat.index(r.lowerBound, offsetBy: -18, limitedBy: flat.startIndex) ?? flat.startIndex
                let end = flat.index(r.upperBound, offsetBy: 34, limitedBy: flat.endIndex) ?? flat.endIndex
                return "…" + flat[start..<end].trimmingCharacters(in: .whitespaces) + "…"
            }
        }
        return nil
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); widest = max(widest, x)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
