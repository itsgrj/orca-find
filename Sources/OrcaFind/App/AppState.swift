import SwiftUI
import Observation

enum AppSection: Hashable {
    case home, library, recents, category(FileCategory), screenshots, largeFiles
    case downloadedFrom(String?)
    case duplicates, cleanUp, cleanUpReview(CleanupKind)
    case smartFolder(UUID), folder(String), search
    case captures, capture(String)

    var isBrowser: Bool {
        switch self {
        case .home, .library, .duplicates, .cleanUp, .cleanUpReview, .captures, .capture: return false
        default: return true
        }
    }

    enum Tab: String, CaseIterable { case home = "Home", captures = "Captures", library = "Library", downloads = "Downloads", tidy = "Tidy" }

    var tab: Tab {
        switch self {
        case .home, .search: return .home
        case .downloadedFrom: return .downloads
        case .captures, .capture: return .captures
        case .cleanUp, .cleanUpReview, .duplicates: return .tidy
        default: return .library
        }
    }
}

/// Searches saved before smart folders existed (migrated on first launch).
private struct LegacySavedSearch: Codable {
    var id = UUID()
    var name: String
    var query: String
}

/// The rules sheet (F3): a new folder or the rules of an existing one.
struct FolderDraft: Identifiable {
    var folder: SmartFolder
    var isNew: Bool
    var description = ""
    var id: UUID { folder.id }
}

/// Built-in smart folders that can be hidden from the Library (but not deleted).
enum BuiltinFolder: String, CaseIterable, Identifiable {
    case recents, large, screenshots
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recents: return "Recents"
        case .large: return "Large files"
        case .screenshots: return "Screenshots"
        }
    }
}

enum DatePreset: String, CaseIterable, Identifiable {
    case any, today, week, month, year, older
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: return "Any date"
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .year: return "Last 12 months"
        case .older: return "Older than a year"
        }
    }
    func matches(_ d: Date, now: Date = Date()) -> Bool {
        switch self {
        case .any: return true
        case .today: return Calendar.current.isDateInToday(d)
        case .week: return d > now.addingTimeInterval(-7 * 86_400)
        case .month: return d > now.addingTimeInterval(-30 * 86_400)
        case .year: return d > now.addingTimeInterval(-365 * 86_400)
        case .older: return d <= now.addingTimeInterval(-365 * 86_400)
        }
    }
}

enum SizePreset: String, CaseIterable, Identifiable {
    case any, small, medium, large, huge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: return "Any size"
        case .small: return "Under 1 MB"
        case .medium: return "1 – 100 MB"
        case .large: return "Over 100 MB"
        case .huge: return "Over 1 GB"
        }
    }
    func matches(_ s: Int64) -> Bool {
        switch self {
        case .any: return true
        case .small: return s < 1_000_000
        case .medium: return s >= 1_000_000 && s <= 100_000_000
        case .large: return s > 100_000_000
        case .huge: return s > 1_000_000_000
        }
    }
}

struct BrowserFilters: Equatable {
    var category: FileCategory?
    var date: DatePreset = .any
    var size: SizePreset = .any
    var sourceKey: String?

    var isActive: Bool { category != nil || date != .any || size != .any || sourceKey != nil }

    func apply(_ items: [FileItem]) -> [FileItem] {
        guard isActive else { return items }
        let now = Date()
        return items.filter { item in
            if let c = category, item.category != c { return false }
            if !date.matches(item.activityDate, now: now) { return false }
            if !size.matches(item.size) { return false }
            if let k = sourceKey, item.source?.key != k { return false }
            return true
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var undo: (() -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct SourceSummary: Identifiable, Hashable {
    let source: DownloadSource
    var count: Int
    var size: Int64
    var id: String { source.key }
}

struct HomeStats {
    var counts: [FileCategory: Int] = [:]
    var sizes: [FileCategory: Int64] = [:]
    var totalCount = 0
    var totalSize: Int64 = 0
    var screenshots = 0
    var largeFiles = 0
    var downloaded = 0
    var recentImages: [FileItem] = []
    var recentVideos: [FileItem] = []
    var recentMusic: [FileItem] = []
    var recentDocuments: [FileItem] = []
    var latestDownloads: [FileItem] = []
    var sources: [SourceSummary] = []
    var recentBy: [FileCategory: [FileItem]] = [:]
    var recentAll: [FileItem] = []
    var screenshotItems: [FileItem] = []
    var largeItems: [FileItem] = []
    var sourceItems: [String: [FileItem]] = [:]
    var recentCount = 0
}

enum MoveDirection { case left, right, up, down }

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let index = FileIndex.shared
    let prefs = Preferences.shared
    let tidy = TidyModel.shared
    let dupes = DuplicatesModel.shared
    let player = MusicPlayer.shared
    let voice = VoiceSearch.shared

    private(set) var section: AppSection = .home
    @ObservationIgnored private var sectionBeforeSearch: AppSection = .home

    var searchText = "" { didSet { if searchText != oldValue { searchTextChanged() } } }
    private(set) var parsed = ParsedQuery()
    /// Apple Intelligence is reading the current sentence (chips may still change).
    private(set) var understanding = false
    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var dismissedGuesses: Set<String> = []
    /// Hand edits to the current search from the "Looks like" editor (reset when the text changes).
    @ObservationIgnored private var manualLooks: [LookTerm] = []
    @ObservationIgnored private var manualTerms: [String] = []
    @ObservationIgnored private var lookExtras: [String: [String]] = [:]

    var filters = BrowserFilters() { didSet { if filters != oldValue { scheduleRefresh(immediate: true) } } }
    var sort = SortSpec(field: .date, ascending: false) { didSet { if sort != oldValue { scheduleRefresh(immediate: true) } } }

    var selection: Set<String> = [] { didSet { if selection != oldValue { selectionChanged() } } }
    @ObservationIgnored var anchorID: String?

    private(set) var visibleItems: [FileItem] = []
    private(set) var visibleSize: Int64 = 0
    private(set) var isRefreshing = false
    private(set) var homeStats = HomeStats()
    private(set) var pinnedPreviews: [String: (items: [FileItem], count: Int)] = [:]
    private(set) var folderStats: [UUID: SmartFolderStats] = [:]
    /// When the open smart folder was last looked at before now (its "New" badges compare against this).
    private(set) var folderSeenBefore: Date?

    var showInspector = false
    var previewItem: FileItem?
    var focusSearchToken = 0
    var scrollTarget: String?
    var gridColumns = 4
    var toast: Toast?
    /// What's typed in the top bar while on Captures (filters captures instead of files).
    var capturesQuery = ""
    /// Which folder of the Captures tab is open (nil = the folders) and which tag narrows it.
    var capturesFolder: CaptureFolder?
    var capturesTag: String?
    var folderSheet: FolderDraft?
    var renamingFolder: SmartFolder?
    var deletingFolder: SmartFolder?
    /// Opens the "Save as smart folder" popover on the search card (⌥⌘S).
    var showSaveFolder = false

    var smartFolders: [SmartFolder] = [] { didSet { persistFolders() } }
    var hiddenBuiltins: Set<String> = [] { didSet { UserDefaults.standard.set(Array(hiddenBuiltins), forKey: "hiddenBuiltinFolders") } }
    var pinnedFolders: [String] = [] { didSet { UserDefaults.standard.set(pinnedFolders, forKey: "pinnedFolders") } }
    var inlineChrome = false

    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "smartFolders"), let list = try? JSONDecoder().decode([SmartFolder].self, from: data) {
            smartFolders = list
        }
        if let data = d.data(forKey: "savedSearches"), let old = try? JSONDecoder().decode([LegacySavedSearch].self, from: data) {
            // Saved searches are smart folders now: same search, shown as a folder with editable rules.
            for s in old where !smartFolders.contains(where: { $0.id == s.id }) {
                let rules = SmartFolder.rules(from: QueryParser.parse(s.query))
                if !rules.isEmpty { smartFolders.append(SmartFolder(id: s.id, name: s.name, rules: rules)) }
            }
            d.removeObject(forKey: "savedSearches")
        }
        hiddenBuiltins = Set(d.stringArray(forKey: "hiddenBuiltinFolders") ?? [])
        pinnedFolders = UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? []
        index.onChange.append { AppState.shared.indexChanged() }
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(smartFolders) {
            UserDefaults.standard.set(data, forKey: "smartFolders")
        }
    }

    // MARK: - Navigation

    func navigate(_ s: AppSection) {
        if !searchText.isEmpty {
            searchText = ""
        }
        setSection(s)
    }

    private func setSection(_ s: AppSection) {
        guard s != section else { return }
        section = s
        selection = []
        anchorID = nil
        filters = BrowserFilters()
        if s != .search && sort.field == .relevance { sort = SortSpec(field: .date, ascending: false) }
        if case .folder = s { sort = SortSpec(field: .name, ascending: true) }
        folderSeenBefore = nil
        if case .smartFolder(let id) = s, let i = smartFolders.firstIndex(where: { $0.id == id }) {
            folderSeenBefore = smartFolders[i].lastSeen
            smartFolders[i].lastSeen = Date()
            scheduleStats()
        }
        else if sort.field == .name && s != .search { sort = SortSpec(field: .date, ascending: false) }
        scheduleRefresh(immediate: true)
        switch s {
        case .cleanUp, .cleanUpReview:
            if tidy.lastScan == nil { tidy.scan() }
            if dupes.lastScan == nil { dupes.scan() }
        case .duplicates:
            if dupes.lastScan == nil { dupes.scan() }
        default: break
        }
    }

    private func searchTextChanged() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        refineTask?.cancel()
        understanding = false
        if trimmed.isEmpty {
            parsed = ParsedQuery()
            dismissedGuesses = []
            if section == .search { setSection(sectionBeforeSearch) }
            return
        }
        if !editingText { manualLooks = []; manualTerms = []; lookExtras = [:]; dismissedGuesses = [] }
        recomputeParsed()
        if SentenceUnderstanding.cache[trimmed.lowercased()] == nil { scheduleUnderstanding(trimmed) }
        if section != .search {
            sectionBeforeSearch = section
            setSection(.search)
            sort = SortSpec(field: .relevance, ascending: false)
        }
        scheduleRefresh()
    }

    @ObservationIgnored private var editingText = false

    /// Rules → Apple Intelligence's reading (if any) → hand edits from the Looks-like editor.
    private func recomputeParsed() {
        let key = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var q = QueryParser.parse(searchText)
        if let r = SentenceUnderstanding.cache[key] { q = QueryParser.merge(q, r, dismissed: dismissedGuesses) }
        let before = q.chips
        q.looks.removeAll { dismissedGuesses.contains("Looks like: " + $0.word) }
        q.chips.removeAll { dismissedGuesses.contains($0.label) }
        if dismissedGuesses.contains("colour") { q.coverColours = []; q.chips.removeAll { $0.kind == .colour } }
        for m in manualLooks where !q.looks.contains(where: { $0.word == m.word }) { q.looks.append(m) }
        for i in q.looks.indices { if let extra = lookExtras[q.looks[i].word] { q.looks[i].labels += extra.filter { !q.looks[i].labels.contains($0) } } }
        for t in manualTerms where !q.terms.contains(t) { q.terms.append(t) }
        if !manualLooks.isEmpty || !manualTerms.isEmpty || !dismissedGuesses.isEmpty { QueryParser.refreshChips(&q, previous: q.chips.isEmpty ? before : q.chips) }
        parsed = q
    }

    func removeChip(_ chip: QueryChip) {
        if chip.ranges.isEmpty {
            // A guess or a hand edit (no words in the text to delete): remember and re-apply.
            dismissedGuesses.insert(chip.kind == .date ? "date" : chip.kind == .colour ? "colour" : chip.label)
            manualLooks.removeAll { "Looks like: " + $0.word == chip.label }
            if chip.kind == .text { manualTerms = [] }
            recomputeParsed()
            scheduleRefresh(immediate: true)
            return
        }
        searchText = QueryParser.removing(chip, from: searchText)
    }

    // MARK: - Looks-like editor (S10)

    private func look(for chip: QueryChip) -> LookTerm? { parsed.looks.first { "Looks like: " + $0.word == chip.label } }

    /// Replace what a "Looks like" chip looks for.
    func replaceLook(_ chip: QueryChip, with word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, let new = QueryParser.lookTerm(for: w) else { return }
        if !chip.ranges.isEmpty {
            editText(chip.ranges, with: w)
        } else {
            dismissedGuesses.insert(chip.label)
            manualLooks.removeAll { "Looks like: " + $0.word == chip.label }
            manualLooks.append(new)
            recomputeParsed(); scheduleRefresh(immediate: true)
        }
    }

    /// Search for the word in names and text instead of in pictures.
    func lookAsText(_ chip: QueryChip) {
        guard let l = look(for: chip) else { return }
        if !chip.ranges.isEmpty {
            editText(chip.ranges, with: "\"\(l.word)\"")
        } else {
            dismissedGuesses.insert(chip.label)
            manualLooks.removeAll { $0.word == l.word }
            manualTerms.append(l.word)
            recomputeParsed(); scheduleRefresh(immediate: true)
        }
    }

    /// Also accept related things (tiger → feline, animal).
    func widenLook(_ chip: QueryChip, with labels: [String]) {
        guard let l = look(for: chip) else { return }
        lookExtras[l.word, default: []] += labels
        recomputeParsed(); scheduleRefresh(immediate: true)
    }

    private func editText(_ ranges: [NSRange], with replacement: String) {
        let ns = NSMutableString(string: searchText)
        for (i, r) in ranges.sorted(by: { $0.location > $1.location }).enumerated() where r.location + r.length <= ns.length {
            ns.replaceCharacters(in: r, with: i == ranges.count - 1 ? replacement : "")
        }
        editingText = true
        searchText = (ns as String).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        editingText = false
    }

    /// Ask Apple Intelligence about sentence-like queries once typing pauses. The rule-based
    /// chips and results stay on screen meanwhile; refined chips replace them when ready.
    private func scheduleUnderstanding(_ text: String) {
        guard prefs.smartSentences, SentenceUnderstanding.worthRefining(text),
              SentenceUnderstanding.status == .available else { return }
        let key = text.lowercased()
        refineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.understanding = true }
            let r = await SentenceUnderstanding.refine(text)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.understanding = false
                guard let r, self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key else { return }
                SentenceUnderstanding.cache[key] = r
                let old = self.parsed
                self.recomputeParsed()
                if self.parsed != old { self.scheduleRefresh(immediate: true) }
            }
        }
    }

    /// Typing into the top-bar field on another tab: jump to search on Home and keep typing there.
    func beginSearch(_ text: String) {
        searchText = text
        focusSearchToken += 1
    }

    func refreshStats() { scheduleStats() }

    func focusSearch() {
        openMainWindow()
        if section.tab != .home && section.tab != .captures { navigate(.home) }
        focusSearchToken += 1
    }

    func selectFirstResult() {
        guard let first = visibleItems.first else { return }
        selection = [first.id]
        anchorID = first.id
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
    }

    // MARK: - Refresh pipeline

    private func indexChanged() {
        scheduleRefresh()
        scheduleStats()
    }

    func scheduleRefresh(immediate: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            if !immediate { try? await Task.sleep(nanoseconds: 140_000_000) }
            guard !Task.isCancelled else { return }
            await self.performRefresh()
        }
    }

    private func performRefresh() async {
        let section = self.section
        switch section {
        case .home, .duplicates, .cleanUp:
            visibleItems = []; visibleSize = 0; return
        case .cleanUpReview(let kind):
            setVisible((tidy.results[kind] ?? []).map(\.item)); return
        default: break
        }
        let items = index.items
        let filters = self.filters
        let sort = self.sort
        let parsed = self.parsed
        let largeBytes = Int64(prefs.largeFileMB) * 1_000_000
        let folders = smartFolders
        isRefreshing = true
        let result: [FileItem] = await Task.detached(priority: .userInitiated) {
            var base: [FileItem]
            var ranked = false
            switch section {
            case .recents:
                let cutoff = Date().addingTimeInterval(-30 * 86_400)
                base = items.filter { $0.activityDate > cutoff && $0.category != .apps }
            case .category(let c):
                base = items.filter { $0.category == c }
            case .screenshots:
                base = items.filter(\.isScreenshot)
            case .largeFiles:
                base = items.filter { $0.size >= largeBytes && !$0.isFolder }
            case .downloadedFrom(let key):
                base = items.filter { item in
                    guard let s = item.source else { return false }
                    return key == nil || s.key == key
                }
            case .smartFolder(let id):
                base = folders.first(where: { $0.id == id })?.run(in: items) ?? []
            case .search:
                base = SearchEngine.run(parsed, in: items)
                ranked = true
            case .folder(let path):
                let url = URL(fileURLWithPath: path)
                let root = FileIndex.rootName(for: path, items: items)
                base = FileScanner.list(folder: url, rootName: root)
            default:
                base = []
            }
            base = filters.apply(base)
            if sort.field == .relevance {
                if !ranked { base = SearchEngine.apply(SortSpec(field: .date, ascending: false), to: base) }
            } else if !(section == .search && parsed.sort != nil && sort.field == .relevance) {
                base = SearchEngine.apply(sort, to: base)
            }
            if case .folder = section {
                base = base.filter(\.isFolder) + base.filter { !$0.isFolder }
            }
            return base
        }.value
        guard !Task.isCancelled, section == self.section else { return }
        setVisible(result)
        isRefreshing = false
        if section == .search, let first = result.first, !result.contains(where: { selection.contains($0.id) }) {
            selection = [first.id]
            anchorID = first.id
        }
    }

    private func setVisible(_ items: [FileItem]) {
        visibleItems = items
        visibleSize = items.reduce(0) { $0 + $1.size }
        let ids = Set(items.map(\.id))
        if !selection.isEmpty, section.isBrowser || isReview {
            let kept = selection.filter { ids.contains($0) || index.item($0) != nil }
            if kept != selection { selection = kept }
        }
    }

    private var isReview: Bool { if case .cleanUpReview = section { return true }; return false }

    private func scheduleStats() {
        statsTask?.cancel()
        statsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let items = index.items
            let large = Int64(prefs.largeFileMB) * 1_000_000
            let pinned = self.pinnedFolders
            let folders = self.smartFolders
            let (stats, previews, counts) = await Task.detached(priority: .utility) { () -> (HomeStats, [String: (items: [FileItem], count: Int)], [UUID: SmartFolderStats]) in
                let st = AppState.computeStats(items, largeBytes: large)
                var pv: [String: (items: [FileItem], count: Int)] = [:]
                for p in pinned {
                    let list = FileScanner.list(folder: URL(fileURLWithPath: p), rootName: (p as NSString).lastPathComponent)
                    let files = list.filter { !$0.isFolder }.sorted { $0.activityDate > $1.activityDate }
                    pv[p] = (Array(files.prefix(3)), list.count)
                }
                var cs: [UUID: SmartFolderStats] = [:]
                for f in folders { cs[f.id] = AppState.folderStats(f, items: items) }
                return (st, pv, cs)
            }.value
            guard !Task.isCancelled else { return }
            self.homeStats = stats
            self.pinnedPreviews = previews
            self.folderStats = counts
        }
    }

    nonisolated static func folderStats(_ f: SmartFolder, items: [FileItem]) -> SmartFolderStats {
        let found = f.run(in: items)
        var st = SmartFolderStats()
        st.count = found.count
        st.size = found.reduce(0) { $0 + $1.size }
        st.newCount = found.lazy.filter { SmartFolder.arrival($0) > f.lastSeen }.count
        st.preview = Array(found.prefix(3))
        var tally: [FileCategory: Int] = [:]
        for i in found.prefix(200) { tally[i.category, default: 0] += 1 }
        st.kind = tally.max { $0.value < $1.value }?.key ?? .documents
        if st.kind == .other { st.kind = .documents }
        return st
    }

    nonisolated static func computeStats(_ items: [FileItem], largeBytes: Int64) -> HomeStats {
        var s = HomeStats()
        var sources: [String: SourceSummary] = [:]
        for item in items where !item.isFolder {
            s.counts[item.category, default: 0] += 1
            s.sizes[item.category, default: 0] += item.size
            s.totalCount += 1
            s.totalSize += item.size
            if item.isScreenshot { s.screenshots += 1 }
            if item.size >= largeBytes { s.largeFiles += 1 }
            if let src = item.source {
                s.downloaded += 1
                sources[src.key, default: SourceSummary(source: src, count: 0, size: 0)].count += 1
                sources[src.key]?.size += item.size
            }
        }
        func recent(_ c: FileCategory) -> [FileItem] {
            Array(items.filter { $0.category == c && !$0.isScreenshot }.sorted { $0.activityDate > $1.activityDate }.prefix(14))
        }
        s.recentImages = recent(.images)
        s.recentVideos = recent(.videos)
        s.recentMusic = recent(.music)
        s.recentDocuments = recent(.documents)
        s.latestDownloads = Array(items.filter { $0.rootName == "Downloads" }
            .sorted { ($0.added ?? $0.activityDate) > ($1.added ?? $1.activityDate) }.prefix(14))
        s.sources = sources.values.sorted { a, b in
            if a.source.isWebsite != b.source.isWebsite { return !a.source.isWebsite }
            return a.count > b.count
        }
        let byDate = items.filter { !$0.isFolder }.sorted { $0.activityDate > $1.activityDate }
        for c in FileCategory.library { s.recentBy[c] = Array(byDate.lazy.filter { $0.category == c && !$0.isScreenshot }.prefix(3)) }
        s.recentBy[.images] = Array(byDate.lazy.filter { $0.category == .images }.prefix(3))
        s.recentAll = Array(byDate.lazy.filter { $0.category != .apps }.prefix(12))
        s.screenshotItems = Array(byDate.lazy.filter(\.isScreenshot).prefix(3))
        s.largeItems = Array(byDate.lazy.filter { $0.size >= largeBytes }.sorted { $0.size > $1.size }.prefix(3))
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        s.recentCount = byDate.lazy.filter { $0.activityDate > monthAgo && $0.category != .apps }.count
        var perSource: [String: [FileItem]] = [:]
        for item in byDate { if let k = item.source?.key, (perSource[k]?.count ?? 0) < 3 { perSource[k, default: []].append(item) } }
        s.sourceItems = perSource
        return s
    }

    // MARK: - Selection

    var selectedItems: [FileItem] {
        let visible = visibleItems.filter { selection.contains($0.id) }
        if visible.count == selection.count { return visible }
        let fromIndex = selection.compactMap { id in visible.contains(where: { $0.id == id }) ? nil : index.item(id) }
        return visible + fromIndex
    }

    func click(_ item: FileItem, in list: [FileItem]) {
        let event = NSApp.currentEvent
        let mods = event?.modifierFlags ?? []
        if (event?.clickCount ?? 1) >= 2 {
            selection = [item.id]
            anchorID = item.id
            activate(item, in: list)
            return
        }
        if mods.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchorID = item.id
        } else if mods.contains(.shift), let anchor = anchorID,
                  let a = list.firstIndex(where: { $0.id == anchor }),
                  let b = list.firstIndex(where: { $0.id == item.id }) {
            selection = Set(list[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [item.id]
            anchorID = item.id
        }
    }

    /// Double-click: folders open, songs play, everything else gets the large preview.
    func activate(_ item: FileItem, in list: [FileItem]) {
        if item.isFolder {
            navigate(.folder(item.path))
        } else if item.category == .music {
            player.play(item, in: list)
        } else if item.category == .apps {
            FileActions.open([item])
        } else {
            previewItem = item
        }
    }

    func activate(ids: Set<String>) {
        let items = visibleItems.filter { ids.contains($0.id) }
        if items.count == 1, let item = items.first { activate(item, in: visibleItems) }
        else { FileActions.open(items) }
    }

    func openSelection() {
        let items = selectedItems
        if items.count == 1, let item = items.first, item.isFolder { navigate(.folder(item.path)); return }
        FileActions.open(items)
    }

    func selectAll() {
        selection = Set(visibleItems.map(\.id))
    }

    @discardableResult
    func moveSelection(_ dir: MoveDirection, list: [FileItem]? = nil) -> Int? {
        let list = list ?? visibleItems
        guard !list.isEmpty else { return nil }
        let current = anchorID.flatMap { id in list.firstIndex { $0.id == id } }
        let step: Int
        switch dir {
        case .left: step = -1
        case .right: step = 1
        case .up: step = prefs.viewMode == .grid ? -max(1, gridColumns) : -1
        case .down: step = prefs.viewMode == .grid ? max(1, gridColumns) : 1
        }
        let next: Int
        if let current { next = max(0, min(list.count - 1, current + step)) } else { next = 0 }
        let id = list[next].id
        selection = [id]
        anchorID = id
        scrollTarget = id
        return next
    }

    private func selectionChanged() {
        if QuickLookCoordinator.shared.isVisible, selection.count == 1, let id = selection.first,
           let i = visibleItems.firstIndex(where: { $0.id == id }) {
            QuickLookCoordinator.shared.update(items: visibleItems, index: i)
        }
    }

    // MARK: - Quick Look & preview

    func toggleQuickLook() {
        let sel = selectedItems
        guard !sel.isEmpty else {
            if QuickLookCoordinator.shared.isVisible { QuickLookCoordinator.shared.close() }
            return
        }
        if sel.count > 1 {
            QuickLookCoordinator.shared.toggle(items: sel, index: 0)
        } else if let i = visibleItems.firstIndex(where: { $0.id == sel[0].id }) {
            QuickLookCoordinator.shared.toggle(items: visibleItems, index: i)
        } else {
            QuickLookCoordinator.shared.toggle(items: sel, index: 0)
        }
    }

    func quickLookMove(_ dir: MoveDirection) {
        let ql = QuickLookCoordinator.shared
        if selection.count > 1 || !visibleItems.contains(where: { selection.contains($0.id) }) {
            let delta = (dir == .left || dir == .up) ? -1 : 1
            ql.update(items: ql.items, index: ql.currentIndex + delta)
            return
        }
        if let i = moveSelection(dir) { ql.update(items: visibleItems, index: i) }
    }

    func previewStep(_ delta: Int) {
        guard let cur = previewItem else { return }
        let list = visibleItems.isEmpty ? homeList : visibleItems
        guard let i = list.firstIndex(where: { $0.id == cur.id }) else { return }
        let j = i + delta
        guard list.indices.contains(j) else { return }
        let next = list[j]
        if next.isFolder { return }
        previewItem = next
        selection = [next.id]
        anchorID = next.id
        scrollTarget = next.id
    }

    private var homeList: [FileItem] {
        homeStats.latestDownloads + homeStats.recentImages + homeStats.recentVideos + homeStats.recentDocuments
    }

    // MARK: - File actions

    func trash(_ items: [FileItem]) {
        let targets = items.filter { !$0.isFolder }
        guard !targets.isEmpty else { return }
        let result = Trash.move(targets)
        let paths = Set(result.moved.map { $0.original.path })
        selection.subtract(paths)
        tidy.remove(paths: paths)
        dupes.removeTrashed(paths)
        if case .folder = section { scheduleRefresh(immediate: true) }
        if result.count > 0 {
            showToast("Moved \(Fmt.plural(result.count, "item")) to the Trash · \(Fmt.size(result.bytes))") {
                let n = Trash.restore(result)
                AppState.shared.showToast("Put back \(Fmt.plural(n, "item"))")
            }
        }
        if !result.failed.isEmpty {
            showToast("Couldn't move \(Fmt.plural(result.failed.count, "item")) to the Trash")
        }
    }

    func trashSelection() { trash(selectedItems) }

    func copyTextFromSelection() {
        let targets = selectedItems.filter { $0.category == .images || $0.ext == "pdf" }
        guard !targets.isEmpty else {
            showToast("Select a screenshot, photo or PDF to copy its text")
            return
        }
        showToast("Reading text…")
        Task.detached(priority: .userInitiated) {
            let text = targets.map { TextExtractor.textForCopy($0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            await MainActor.run {
                if text.isEmpty {
                    AppState.shared.showToast("No text found")
                } else {
                    FileActions.copyText(text)
                    AppState.shared.showToast("Copied \(Fmt.plural(text.split(whereSeparator: \.isNewline).count, "line")) of text")
                }
            }
        }
    }

    func pin(_ item: FileItem) { pinFolder(item.isFolder ? item.path : item.parentPath) }

    func pinFolder(_ folder: String) {
        guard !pinnedFolders.contains(folder) else { showToast("Already pinned"); return }
        pinnedFolders.append(folder)
        scheduleStats()
        showToast("Pinned “\((folder as NSString).lastPathComponent)” to your Library")
    }

    func unpin(_ path: String) {
        pinnedFolders.removeAll { $0 == path }
        if section == .folder(path) { navigate(.home) }
    }

    /// ⌘↩ from Quick Search: show the file inside Orca Find, in its folder, selected.
    func revealInApp(_ item: FileItem) {
        openMainWindow()
        navigate(.folder(item.parentPath))
        selection = [item.id]
        anchorID = item.id
        showInspector = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.scrollTarget = item.id
        }
    }

    // MARK: - Smart folders

    func folder(_ id: UUID) -> SmartFolder? { smartFolders.first { $0.id == id } }

    /// The rules the current search would become (F2).
    var currentSearchRules: [SmartRule] { SmartFolder.rules(from: parsed) }

    /// Save the current search as a smart folder and open it.
    func saveCurrentSearchAsFolder(name: String) {
        let rules = currentSearchRules
        guard !rules.isEmpty else { showToast("Search for something first"); return }
        let n = name.trimmingCharacters(in: .whitespaces)
        createFolder(SmartFolder(name: n.isEmpty ? SmartFolder.suggestedName(for: searchText) : n, rules: rules))
    }

    func createFolder(_ f: SmartFolder) {
        var f = f
        f.created = Date(); f.lastSeen = Date()
        smartFolders.append(f)
        scheduleStats()
        navigate(.smartFolder(f.id))
        showToast("Made “\(f.name)” — it's in your Library and fills itself")
    }

    func updateFolder(_ f: SmartFolder) {
        guard let i = smartFolders.firstIndex(where: { $0.id == f.id }) else { return }
        smartFolders[i] = f
        scheduleStats()
        if section == .smartFolder(f.id) { scheduleRefresh(immediate: true) }
    }

    func newFolderSheet(rules: [SmartRule] = [], name: String = "", description: String = "") {
        folderSheet = FolderDraft(folder: SmartFolder(name: name, rules: rules), isNew: true, description: description)
    }

    func editRules(_ id: UUID) {
        guard let f = folder(id) else { return }
        folderSheet = FolderDraft(folder: f, isNew: false)
    }

    func removeRule(_ ruleID: UUID, from id: UUID) {
        guard var f = folder(id), f.rules.count > 1 else { return }
        f.rules.removeAll { $0.id == ruleID }
        updateFolder(f)
    }

    func renameFolder(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard var f = folder(id), !n.isEmpty else { return }
        f.name = n
        updateFolder(f)
    }

    func duplicateFolder(_ id: UUID) {
        guard let f = folder(id), let i = smartFolders.firstIndex(where: { $0.id == id }) else { return }
        var copy = f
        copy.id = UUID(); copy.name = f.name + " copy"; copy.created = Date(); copy.lastSeen = Date()
        copy.rules = f.rules.map { var r = $0; r.id = UUID(); return r }
        smartFolders.insert(copy, at: i + 1)
        scheduleStats()
        showToast("Made a copy of “\(f.name)”")
    }

    func toggleOnHome(_ id: UUID) {
        guard var f = folder(id) else { return }
        f.showOnHome.toggle()
        updateFolder(f)
        showToast(f.showOnHome ? "“\(f.name)” now shows on Home" : "Removed “\(f.name)” from Home")
    }

    /// Deleting a smart folder never touches files. Undo puts it back where it was.
    func deleteFolder(_ id: UUID) {
        guard let i = smartFolders.firstIndex(where: { $0.id == id }) else { return }
        let f = smartFolders.remove(at: i)
        if section == .smartFolder(id) { navigate(.library) }
        showToast("Deleted “\(f.name)” · your files are untouched") {
            let s = AppState.shared
            s.smartFolders.insert(f, at: min(i, s.smartFolders.count))
            s.scheduleStats()
        }
    }

    func hideBuiltin(_ b: BuiltinFolder) {
        hiddenBuiltins.insert(b.rawValue)
        showToast("Hid “\(b.title)” · bring it back in Settings › Folders") { AppState.shared.hiddenBuiltins.remove(b.rawValue) }
    }

    // MARK: - View

    func biggerCards() { prefs.cardSize = min(320, prefs.cardSize + 24) }
    func smallerCards() { prefs.cardSize = max(96, prefs.cardSize - 24) }

    func showToast(_ message: String, undo: (() -> Void)? = nil) {
        toast = Toast(message: message, undo: undo)
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: undo == nil ? 2_600_000_000 : 6_000_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: - Voice

    func startVoiceSearch() {
        guard prefs.voiceEnabled else { showToast("Voice search is turned off in Settings"); return }
        let before = searchText
        voice.toggle(owner: "main", onUpdate: { text in
            AppState.shared.searchText = text
        }, onFinish: { text in
            let s = AppState.shared
            if text.isEmpty { s.searchText = before }
            if let e = s.voice.error { s.showToast(e) }
        })
    }

    // MARK: - Titles

    func title(for s: AppSection) -> String {
        switch s {
        case .home: return "Home"
        case .library: return "Library"
        case .recents: return "Recents"
        case .category(let c): return c.title
        case .screenshots: return "Screenshots"
        case .largeFiles: return "Large Files"
        case .downloadedFrom(let k):
            if let k, let src = homeStats.sources.first(where: { $0.id == k }) { return "From \(src.source.name)" }
            return "Downloaded From"
        case .duplicates: return "Duplicates"
        case .cleanUp: return "Clean Up"
        case .cleanUpReview(let k): return k.title
        case .smartFolder(let id): return folder(id)?.name ?? "Smart folder"
        case .folder(let p): return FileManager.default.displayName(atPath: p)
        case .search: return "Results"
        case .captures: return "Captures"
        case .capture(let id): return CaptureLibrary.shared.capture(id)?.title ?? "Capture"
        }
    }

    func symbol(for s: AppSection) -> String {
        switch s {
        case .home: return "house"
        case .library: return "books.vertical"
        case .recents: return "clock"
        case .category(let c): return c.symbol
        case .screenshots: return "camera.viewfinder"
        case .largeFiles: return "externaldrive"
        case .downloadedFrom: return "arrow.down.circle"
        case .duplicates: return "square.on.square"
        case .cleanUp, .cleanUpReview: return "sparkles"
        case .smartFolder: return "folder.badge.gearshape"
        case .folder: return "folder"
        case .search: return "magnifyingglass"
        case .captures, .capture: return "viewfinder"
        }
    }
}

extension FileIndex {
    nonisolated static func rootName(for path: String, items: [FileItem]) -> String {
        let home = NSHomeDirectory()
        for name in FileScanner.defaultFolderNames() where path.hasPrefix(home + "/" + name) { return name }
        if path.hasPrefix("/Applications") { return "Applications" }
        return (path as NSString).lastPathComponent
    }
}
