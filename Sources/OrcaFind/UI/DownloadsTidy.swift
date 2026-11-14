import SwiftUI

// MARK: - Downloads

enum DownloadsGrouping: String, CaseIterable, Identifiable {
    case none, kind, date
    var id: String { rawValue }
    var title: String { self == .none ? "None" : self == .kind ? "Kind" : "Date" }
}

struct DownloadsScreen: View {
    @Environment(AppState.self) private var state
    @AppStorage("downloadsGroupBy") private var groupBy: DownloadsGrouping = .none
    @State private var plan: SortDownloads.Plan?

    private var selectedKey: String? { if case .downloadedFrom(let k) = state.section { return k }; return nil }

    var body: some View {
        let stats = state.homeStats
        let sources = Array(stats.sources.prefix(9))
        GeometryReader { geo in
            let w = min(176, (geo.size.width - 64 - 16 * 6) / 7)
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Downloaded from",
                             subtitle: "Every download remembers where it came from. \(Fmt.count(stats.downloaded)) files from \(stats.sources.count) sources.")
                if sources.isEmpty {
                    EmptyState(symbol: "arrow.down.circle", tag: "Nothing yet", title: "No downloads with a source yet",
                               message: "Files you download from the web, Gmail, Slack and other apps show up here, grouped by where they came from.")
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(sources) { s in
                                let items = stats.sourceItems[s.id] ?? []
                                let kind = items.first?.category ?? .documents
                                GlassFolder(title: s.source.name, meta: "\(Fmt.count(s.count)) · \(Fmt.size(s.size))",
                                            palette: s.source.isWebsite ? .of(.documents) : .brand(s.source.color), style: .of(kind),
                                            items: items, width: w) { state.navigate(selectedKey == s.id ? .downloadedFrom(nil) : .downloadedFrom(s.id)) }
                                    .opacity(selectedKey == nil || selectedKey == s.id ? 1 : 0.45)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    table
                }
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 16)
        }
        .overlay(alignment: .bottom) { SelectionBar() }
        .sheet(isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
            if let plan { SortPlanSheet(plan: plan) { self.plan = nil } }
        }
    }

    /// Same files, under a heading per kind or per day. Only the view changes; nothing moves.
    private func sections(_ items: [FileItem]) -> [(title: String, items: [FileItem])] {
        switch groupBy {
        case .none:
            return [("", items)]
        case .kind:
            var by: [String: [FileItem]] = [:]
            for i in items { by[SortDownloads.folder(for: i) ?? "Other", default: []].append(i) }
            return (SortDownloads.order + ["Other"]).compactMap { k in by[k].map { (k, $0) } }
        case .date:
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            func bucket(_ d: Date) -> String {
                if d >= today { return "Today" }
                if d >= today.addingTimeInterval(-86_400) { return "Yesterday" }
                if d >= today.addingTimeInterval(-6 * 86_400) { return "This week" }
                if d >= today.addingTimeInterval(-29 * 86_400) { return "This month" }
                return "Older"
            }
            var by: [String: [FileItem]] = [:]
            for i in items { by[bucket(i.added ?? i.activityDate), default: []].append(i) }
            return ["Today", "Yesterday", "This week", "This month", "Older"].compactMap { k in by[k].map { (k, $0) } }
        }
    }

    private var table: some View {
        let items = Array(state.visibleItems.prefix(400))
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(selectedKey.flatMap { k in state.homeStats.sources.first { $0.id == k }?.source.name }.map { "From \($0)" } ?? "All downloads")
                    .font(DS.body).foregroundStyle(DS.text)
                Spacer()
                Button { state.navigate(.downloadedFrom(nil)) } label: { Chip(label: "All", symbol: "arrow.down.circle", style: selectedKey == nil ? .selected : .normal) }.buttonStyle(.plain)
                ForEach(state.homeStats.sources.prefix(5)) { s in
                    Button { state.navigate(.downloadedFrom(s.id)) } label: { Chip(label: s.source.name, style: selectedKey == s.id ? .selected : .normal) }.buttonStyle(.plain)
                }
                SortMenu()
                Picker(selection: $groupBy) {
                    ForEach(DownloadsGrouping.allCases) { Text($0.title).tag($0) }
                } label: { Text("Group by").font(DS.bodySM).foregroundStyle(DS.text2) }
                    .pickerStyle(.menu).fixedSize()
                    .help("Shows the files under a heading per kind or per day. Nothing moves.")
                Button("Sort into folders…") { plan = SortDownloads.plan(FileIndex.shared.items) }
                    .buttonStyle(.secondary)
                    .help("Shows the plan first. Nothing moves until you say so.")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 12) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("From").frame(width: 130, alignment: .leading)
                Text("Size").frame(width: 80, alignment: .leading)
                Text("Downloaded").frame(width: 110, alignment: .leading)
                Color.clear.frame(width: 20, height: 1)
            }
            .font(DS.bodySM).foregroundStyle(DS.text2)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(DS.surface2)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sections(items), id: \.title) { sec in
                        if !sec.title.isEmpty {
                            HStack(spacing: 8) {
                                PixelLabel(sec.title)
                                Text("\(sec.items.count)").font(DS.caption).foregroundStyle(DS.text3)
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                        }
                        ForEach(sec.items) { item in
                            DownloadRow(item: item, selected: state.selection.contains(item.id))
                                .onTapGesture { state.click(item, in: items) }
                                .contextMenu { FileMenu(items: state.selection.contains(item.id) ? state.selectedItems : [item]) }
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                            Rectangle().fill(DS.border).frame(height: 1)
                        }
                    }
                }
            }
        }
        .card(14)
    }
}

/// The plan for Sort into folders: every move listed before anything happens.
struct SortPlanSheet: View {
    @Environment(AppState.self) private var state
    let plan: SortDownloads.Plan
    let close: () -> Void
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sort Downloads into folders").font(DS.headingSM).foregroundStyle(DS.text)
                Text(plan.count == 0 ? "Everything in Downloads is already in a folder, or still arriving."
                     : "\(Fmt.plural(plan.count, "loose file")) go into a folder for each kind, inside Downloads. Nothing moves until you click Sort.")
                    .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            let rows = plan.groups.count + plan.groups.filter { open.contains($0.id) }.reduce(0) { $0 + min(41, $1.files.count) }
            if rows > 12 {
                ScrollView { planList }.frame(height: 360)
            } else {
                planList
            }
            HStack {
                Text("Undo puts every file back where it was.").font(DS.caption).foregroundStyle(DS.text2)
                Spacer()
                Button("Cancel") { close() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button(plan.count == 0 ? "Done" : "Sort \(Fmt.plural(plan.count, "file"))") { sort() }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(DS.surface)
    }

    private var planList: some View {
                VStack(spacing: 0) {
                    ForEach(plan.groups) { g in
                        Button { if open.contains(g.id) { open.remove(g.id) } else { open.insert(g.id) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").foregroundStyle(DS.text2)
                                Text("Downloads › \(g.folder)").font(DS.body).foregroundStyle(DS.text)
                                Spacer()
                                Text("\(Fmt.plural(g.files.count, "file")) · \(Fmt.size(g.size))").font(DS.bodySM).foregroundStyle(DS.text2)
                                Image(systemName: open.contains(g.id) ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.text3)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if open.contains(g.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(g.files.prefix(40)) { f in
                                    Text(f.name).font(DS.bodySM).foregroundStyle(DS.text2).lineLimit(1).truncationMode(.middle)
                                }
                                if g.files.count > 40 { Text("and \(g.files.count - 40) more").font(DS.caption).foregroundStyle(DS.text3) }
                            }
                            .padding(.leading, 40).padding(.trailing, 14).padding(.bottom, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Rectangle().fill(DS.border).frame(height: 1)
                    }
                    if !plan.leftAlone.isEmpty {
                        note("clock", "Left alone: \(Fmt.plural(plan.leftAlone.count, "file")) still downloading or added in the last 2 minutes")
                    }
                    if !plan.other.isEmpty {
                        note("questionmark.folder", "Stay where they are: \(Fmt.plural(plan.other.count, "file")) of other kinds, like apps")
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(DS.text2)
            Text(text).font(DS.bodySM).foregroundStyle(DS.text2)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func sort() {
        guard plan.count > 0 else { close(); return }
        let done = SortDownloads.run(plan)
        close()
        // The index watches the disk, so the moves show up by themselves.
        state.showToast("Sorted \(Fmt.plural(done.count, "file")) into \(Fmt.plural(Set(done.moves.map { $0.to.deletingLastPathComponent().path }).count, "folder"))", undo: {
            let n = SortDownloads.undo(done)
            AppState.shared.showToast("Put back \(Fmt.plural(n, "file"))")
        })
    }
}

struct DownloadRow: View {
    let item: FileItem
    var selected = false
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Thumb(item: item, size: 64, mode: item.category == .images || item.category == .videos ? .fill : .fit)
                    .frame(width: 32, height: 32).background(DS.surface2).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(DS.body).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                    Text(item.kindName).font(DS.caption).foregroundStyle(DS.text2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group { if let s = item.source { Badge(s.name, tone: s.isWebsite ? .neutral : .info) } else { Text("") } }.frame(width: 130, alignment: .leading)
            Text(Fmt.size(item.size)).font(DS.bodySM).foregroundStyle(DS.text2).frame(width: 80, alignment: .leading)
            Text(Fmt.relative(item.added ?? item.activityDate)).font(DS.bodySM).foregroundStyle(DS.text2).frame(width: 110, alignment: .leading)
            Button { FileActions.revealInFinder([item]) } label: { Image(systemName: "folder").foregroundStyle(DS.text2) }.buttonStyle(.plain).frame(width: 20).help("Show in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(selected ? DS.focus.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Tidy

struct TidyScreen: View {
    @Environment(AppState.self) private var state
    @State private var trash: LibraryCleanup.TrashInfo?
    @State private var confirmEmpty = false
    /// The startup disk's size and space in use. Asking macOS takes 5–20 ms, so it's read once, off the main
    /// thread, not on every redraw.
    @State private var disk: (total: Int64, used: Int64)?

    private let tones: [CleanupKind: DS.Tone] = [.bigOldVideos: .magic, .oldInstallers: .attention, .duplicates: .info, .lookAlikes: .magic,
                                                 .unusedApps: .critical, .forgottenDownloads: .success, .oldScreenshots: .emphasis,
                                                 .mailAttachments: .info, .appLeftovers: .neutral]

    /// Safe to clear: things Orca is sure are spare. Your call: things you might still want.
    private let safe: [CleanupKind] = [.oldInstallers, .duplicates, .mailAttachments]
    private let yourCall: [CleanupKind] = [.bigOldVideos, .lookAlikes, .unusedApps, .oldScreenshots, .forgottenDownloads, .appLeftovers]
    private var order: [CleanupKind] { safe + yourCall }

    /// Each card's numbers, worked out once per redraw (duplicate totals walk every group).
    private struct Figures {
        var total: [CleanupKind: Int64] = [:]
        var count: [CleanupKind: Int] = [:]
        var groups: [CleanupKind: Int] = [:]
        var preview: [CleanupKind: [FileItem]] = [:]
        var grand: Int64 = 0
    }

    private func figures() -> Figures {
        var f = Figures()
        let tidy = state.tidy
        var dupGroups: [DuplicateGroup.Kind: [DuplicateGroup]] = [:]
        for g in state.dupes.groups { dupGroups[g.kind, default: []].append(g) }
        for kind in order {
            if let dk: DuplicateGroup.Kind = kind == .duplicates ? .identical : kind == .lookAlikes ? .lookAlike : nil {
                let gs = dupGroups[dk] ?? []
                f.total[kind] = gs.reduce(0) { $0 + $1.reclaimable }
                f.count[kind] = gs.reduce(0) { $0 + $1.items.count - 1 }
                f.groups[kind] = gs.count
                f.preview[kind] = gs.prefix(4).compactMap { $0.items.first }
            } else {
                let list = tidy.results[kind] ?? []
                f.total[kind] = list.reduce(0) { $0 + $1.item.size }
                f.count[kind] = list.count
                f.preview[kind] = list.prefix(4).map(\.item)
            }
            f.grand += f.total[kind] ?? 0
        }
        return f
    }

    var body: some View {
        let tidy = state.tidy
        let scanning = tidy.isScanning || state.dupes.isScanning
        let f = figures()
        GeometryReader { geo in
            let cw = (geo.size.width - 64 - 32) / 3
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: scanning && tidy.lastScan == nil ? "Looking around…" : "You could free \(Fmt.size(f.grand))",
                                 subtitle: "Nothing is deleted. Files go to the Trash, and Undo is one click away.") {
                        if scanning { ProgressView().controlSize(.small) }
                        Button("Scan again") { tidy.scan(); state.dupes.scan(); loadTrash(); loadDisk() }.buttonStyle(.secondary).disabled(scanning)
                    }
                    storageBar(f)
                    trashLine
                    section("Safe to clear", "Orca is sure these are spare, so they come ticked for you.", safe, cw, f)
                    section("Your call", "You might still want these. Nothing is ticked until you choose.", yourCall, cw, f)
                    autoRules
                    RecentlyRemovedRow()
                }
                .padding(.horizontal, 32).padding(.vertical, 22)
            }
        }
        .task { loadTrash(); loadDisk() }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) {
                Task.detached {
                    LibraryCleanup.emptyTrash()
                    let info = LibraryCleanup.trashInfo()
                    await MainActor.run { trash = info; AppState.shared.showToast("Emptied the Trash") }
                }
            }
        } message: {
            Text("\(Fmt.plural(trash?.count ?? 0, "item")) (\(Fmt.size(trash?.size ?? 0))) will be erased for good. This can’t be undone.")
        }
    }

    private func loadDisk() {
        Task.detached(priority: .utility) {
            let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = Int64(v?.volumeTotalCapacity ?? 0)
            let used = total - (v?.volumeAvailableCapacityForImportantUsage ?? 0)
            await MainActor.run { disk = total > 0 ? (total, used) : nil }
        }
    }

    private func loadTrash() {
        Task.detached(priority: .utility) {
            let info = LibraryCleanup.trashInfo()
            await MainActor.run { trash = info }
        }
    }

    private func section(_ title: String, _ subtitle: String, _ kinds: [CleanupKind], _ cw: CGFloat, _ f: Figures) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(DS.headingSM).foregroundStyle(DS.text)
                Text(subtitle).font(DS.bodySM).foregroundStyle(DS.text2)
            }
            // A plain grid: there are only a few cards, so a lazy grid's measuring passes cost more than they save.
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                ForEach(Array(stride(from: 0, to: kinds.count, by: 3)), id: \.self) { start in
                    GridRow {
                        ForEach(kinds[start..<min(start + 3, kinds.count)], id: \.self) { kind in card(kind, f).frame(width: cw) }
                    }
                }
            }
        }
    }

    /// What the Trash is holding, with Empty Trash (it asks first).
    @ViewBuilder private var trashLine: some View {
        if let t = trash {
            HStack(spacing: 12) {
                ToneIcon(symbol: "trash", tone: .neutral, size: 32)
                if t.readable {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.count == 0 ? "The Trash is empty" : "The Trash is holding \(Fmt.size(t.size))").font(DS.body).foregroundStyle(DS.text)
                        Text(t.count == 0 ? "Nothing waiting to be erased." : "\(Fmt.plural(t.count, "item")) you already threw away still take up space until it’s emptied.")
                            .font(DS.caption).foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Button("Empty Trash…") { confirmEmpty = true }.buttonStyle(.secondary).disabled(t.count == 0)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("See what the Trash is holding").font(DS.body).foregroundStyle(DS.text)
                        Text("macOS asks for Full Disk Access before Orca can look inside the Trash.").font(DS.caption).foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Button("Open System Settings") { Onboarding.openFullDiskAccess() }.buttonStyle(.secondary)
                }
            }
            .padding(14).card(14)
        }
    }

    private func storageBar(_ f: Figures) -> some View {
        let total = max(1, f.grand)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(order, id: \.self) { k in
                        let v = f.total[k] ?? 0
                        if v > 0 { Rectangle().fill(Color(hex: k.color)).frame(width: max(3, g.size.width * CGFloat(Double(v) / Double(total)))) }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 16) {
                ForEach(order.filter { (f.total[$0] ?? 0) > 0 }, id: \.self) { k in
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: k.color)).frame(width: 8, height: 8)
                        Text("\(k.title) \(Fmt.size(f.total[k] ?? 0))").font(DS.caption).foregroundStyle(DS.text2)
                    }
                }
                Spacer()
                if let disk, disk.used > 0 { Text("\(Fmt.size(disk.used)) of \(Fmt.size(disk.total)) used").font(DS.caption).foregroundStyle(DS.text2) }
            }
        }
        .padding(16).card(14)
    }

    private func card(_ kind: CleanupKind, _ f: Figures) -> some View {
        let tidy = state.tidy
        let dupKind: DuplicateGroup.Kind? = kind == .duplicates ? .identical : kind == .lookAlikes ? .lookAlike : nil
        let items = f.preview[kind] ?? []
        let count = f.count[kind] ?? 0
        let size = f.total[kind] ?? 0
        let checking = tidy.isChecking(kind)
        let locked = kind == .mailAttachments && tidy.mailNeedsAccess
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ToneIcon(symbol: kind.symbol, tone: tones[kind] ?? .neutral, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(DS.body).foregroundStyle(DS.text)
                    Text(kind.detail).font(DS.caption).foregroundStyle(DS.text2).lineLimit(2)
                }
                Spacer(minLength: 4)
                if checking { ProgressView().controlSize(.small) } else { Text(size > 0 ? Fmt.size(size) : "—").font(DS.stat).foregroundStyle(DS.text) }
            }
            HStack(spacing: 10) {
                HStack(spacing: -10) {
                    ForEach(items) { i in
                        Group {
                            if i.rootName == "Library" {
                                Image(nsImage: FileIcons.icon(i.path)).resizable().scaledToFit().padding(4)
                            } else {
                                Thumb(item: i, size: 88, mode: i.category == .images || i.category == .videos ? .fill : .fit)
                            }
                        }
                        .frame(width: 44, height: 44).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DS.surface, lineWidth: 2))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    }
                }
                Text(checking ? "Still looking…" : locked ? "Needs Full Disk Access" : count == 0 ? "All clear"
                     : (dupKind != nil ? Fmt.plural(f.groups[kind] ?? 0, "group") : Fmt.plural(count, "file")))
                    .font(DS.bodySM).foregroundStyle(DS.text2)
                Spacer()
                if locked {
                    Button("Allow…") { Onboarding.openFullDiskAccess() }.buttonStyle(.secondary)
                } else {
                    Button("Review") {
                        if let dupKind { state.dupes.focus = dupKind; state.navigate(.duplicates) } else { state.navigate(.cleanUpReview(kind)) }
                    }
                    .buttonStyle(.secondary).disabled(count == 0 || checking)
                }
            }
        }
        .padding(16).card(16)
        .overlay(alignment: .topTrailing) {
            if kind.isSafe && count > 0 && !checking {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(DS.Tone.success.fg).padding(8)
                    .help("Ticked for you when you review")
            }
        }
    }

    private var autoRules: some View {
        @Bindable var p = state.prefs
        return HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic clean up").font(DS.body).foregroundStyle(DS.text)
                Text("Off until you turn them on · runs hourly").font(DS.caption).foregroundStyle(DS.text2)
            }
            Toggle(isOn: $p.autoTrashInstallers) { Text("Move installers to the Trash after \(p.autoInstallerDays) days").font(DS.bodySM) }.toggleStyle(.switch).controlSize(.small)
            Toggle(isOn: $p.autoSortScreenshots) { Text("File screenshots into a folder per month").font(DS.bodySM) }.toggleStyle(.switch).controlSize(.small)
            Spacer()
            if let last = p.autoLog.first { Text("\(last.message) · \(Fmt.relative(last.date))").font(DS.caption).foregroundStyle(DS.text2).lineLimit(1) }
        }
        .padding(16).card(14)
    }
}

struct ReviewScreen: View {
    @Environment(AppState.self) private var state
    let kind: CleanupKind
    @State private var checked: Set<String> = []
    @State private var confirmAll = false
    @State private var ticked = false

    var body: some View {
        let candidates = state.tidy.results[kind] ?? []
        let selected = candidates.filter { checked.contains($0.id) }.map(\.item)
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: kind.title, subtitle: kind.detail, back: ("Tidy", { state.navigate(.cleanUp) })) {
                Button("Trash selected (\(selected.count))") { state.trash(selected, reason: kind.removalReason, includeFolders: true); checked = [] }.buttonStyle(.secondary).disabled(selected.isEmpty)
                Button("Trash all · \(Fmt.size(candidates.reduce(0) { $0 + $1.item.size }))") { confirmAll = true }.buttonStyle(.critical).disabled(candidates.isEmpty)
            }
            if candidates.isEmpty {
                EmptyState(symbol: "sparkles", tag: "All clean", tone: .success, title: "Nothing to tidy here", message: "We'll check again tomorrow.").frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: kind.isSafe ? "checkmark.circle.fill" : "hand.raised").foregroundStyle(kind.isSafe ? DS.Tone.success.fg : DS.text2)
                    Text(kind.isSafe ? "Safe to clear: Orca is sure these are spare, so they’re ticked for you."
                         : "Your call: you might still want some of these, so nothing is ticked.")
                        .font(DS.bodySM).foregroundStyle(DS.text2)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        checkbox(on: checked.count == candidates.count) { checked = checked.count == candidates.count ? [] : Set(candidates.map(\.id)) }
                        Text("File").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Why").frame(width: 260, alignment: .leading)
                        Text("Size").frame(width: 80, alignment: .leading)
                        Color.clear.frame(width: 40, height: 1)
                    }
                    .font(DS.bodySM).foregroundStyle(DS.text2)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(DS.surface2)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(candidates) { c in
                                HStack(spacing: 12) {
                                    checkbox(on: checked.contains(c.id)) { if checked.contains(c.id) { checked.remove(c.id) } else { checked.insert(c.id) } }
                                    HStack(spacing: 10) {
                                        Thumb(item: c.item, size: 64, mode: c.item.category == .images || c.item.category == .videos ? .fill : .fit)
                                            .frame(width: 32, height: 32).background(DS.surface2).clipShape(RoundedRectangle(cornerRadius: 7))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(c.item.name).font(DS.body).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                                            Text((c.item.parentPath as NSString).abbreviatingWithTildeInPath).font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Badge(c.note, tone: c.note.contains("installed") && !c.note.contains("Not") ? .success : .neutral).frame(width: 260, alignment: .leading)
                                    Text(Fmt.size(c.item.size)).font(DS.bodySM).foregroundStyle(DS.text2).frame(width: 80, alignment: .leading)
                                    HStack(spacing: 8) {
                                        Button { state.previewItem = c.item } label: { Image(systemName: "eye") }.buttonStyle(.plain)
                                        Button { FileActions.revealInFinder([c.item]) } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                                    }
                                    .foregroundStyle(DS.text2).frame(width: 40)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(checked.contains(c.id) ? DS.hover : Color.clear)
                                Rectangle().fill(DS.border).frame(height: 1)
                            }
                        }
                    }
                }
                .card(14)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Tone.success.fg)
                    Text("Files stored only in iCloud are skipped, so nothing downloads behind your back.").font(DS.caption).foregroundStyle(DS.text2)
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
        .onAppear { if !ticked { checked = state.tidy.preticked(kind); ticked = true } }
        .confirmationDialog("Move \(Fmt.plural(candidates.count, "file")) to the Trash?", isPresented: $confirmAll) {
            Button("Move All to Trash", role: .destructive) { state.trash(candidates.map(\.item), reason: kind.removalReason, includeFolders: true); checked = [] }
        } message: { Text("You can put them back from the Trash, or press Undo right after.") }
    }

    private func checkbox(on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(on ? DS.brand : DS.surface)
                RoundedRectangle(cornerRadius: 4).strokeBorder(on ? .clear : DS.borderStrong)
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.onBrand) }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }
}

struct DuplicatesScreen: View {
    @Environment(AppState.self) private var state
    @State private var filter: DuplicateGroup.Kind?
    @State private var confirm = false

    var body: some View {
        let m = state.dupes
        let groups = m.groups.filter { filter == nil || $0.kind == filter }
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(title: "Duplicates",
                         subtitle: m.isScanning ? m.phase : "\(Fmt.plural(m.groups.count, "group")) · \(Fmt.size(m.totalReclaimable)) can be freed · iCloud-only files skipped",
                         back: ("Tidy", { state.navigate(.cleanUp) })) {
                HStack(spacing: 2) {
                    seg("All \(m.groups.count)", filter == nil) { filter = nil }
                    seg("Identical \(m.groups.filter { $0.kind == .identical }.count)", filter == .identical) { filter = .identical }
                    seg("Look-alikes \(m.groups.filter { $0.kind == .lookAlike }.count)", filter == .lookAlike) { filter = .lookAlike }
                }
                .padding(2).background(RoundedRectangle(cornerRadius: 9).fill(DS.tertiary))
                Button("Move \(Fmt.plural(m.selectedExtras.count, "duplicate")) to Trash") { confirm = true }
                    .buttonStyle(.critical).disabled(m.selectedExtras.isEmpty)
            }
            if m.isScanning { ProgressView(value: m.progress).tint(DS.brand) }
            if !m.isScanning && m.groups.isEmpty && m.lastScan != nil {
                EmptyState(symbol: "checkmark.seal", tag: "All clean", tone: .success, title: "No duplicates found", message: "Every file is one of a kind.").frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { g in groupCard(g) }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
        .task { if m.lastScan == nil { m.scan() } }
        .onAppear { if let f = m.focus { filter = f; m.focus = nil } }
        .confirmationDialog("Move \(Fmt.plural(m.selectedExtras.count, "duplicate")) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { state.trash(m.selectedExtras, reason: "Duplicate") }
        } message: { Text("One copy in each group is kept. Frees \(Fmt.size(m.totalReclaimable)).") }
    }

    private func seg(_ label: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(DS.bodySM).foregroundStyle(on ? DS.text : DS.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? DS.surface : .clear))
        }.buttonStyle(.plain)
    }

    private func groupCard(_ g: DuplicateGroup) -> some View {
        let label: (String, DS.Tone) = g.kind == .identical ? ("Identical", .info) : (Set(g.items.map(\.ext)).count > 1 ? ("HEIC + JPEG pair", .attention) : ("Look-alike", .magic))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { state.dupes.toggle(g.id) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(g.included ? DS.brand : DS.surface)
                        RoundedRectangle(cornerRadius: 4).strokeBorder(g.included ? .clear : DS.borderStrong)
                        if g.included { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.onBrand) }
                    }.frame(width: 16, height: 16)
                }.buttonStyle(.plain)
                Badge(label.0, tone: label.1)
                Text("\(Fmt.plural(g.items.count, "copy", "copies")) · frees \(Fmt.size(g.reclaimable))").font(DS.body).foregroundStyle(DS.text)
                Spacer()
                Text("Click a file to keep it instead").font(DS.caption).foregroundStyle(DS.text2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(g.items) { item in
                        let keep = item.id == g.keepID
                        VStack(alignment: .leading, spacing: 5) {
                            ZStack(alignment: .topLeading) {
                                Thumb(item: item, size: 176, mode: item.category == .documents ? .page : (item.category == .images ? .fill : .fit))
                                    .frame(width: 176, height: 116).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(keep ? DS.brand : .clear, lineWidth: 3))
                                Text(keep ? "KEEP" : "TRASH").font(DS.label).foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(keep ? Color(hex: 0x303030) : DS.critical))
                                    .padding(8)
                            }
                            Text(item.name).font(DS.bodySM).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                            Text("\(item.parentName) · \(Fmt.size(item.size))\(item.dimensionsText.map { " · " + $0 } ?? "")").font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
                        }
                        .frame(width: 176)
                        .opacity(g.included ? 1 : 0.5)
                        .onTapGesture { if NSApp.currentEvent?.clickCount ?? 1 >= 2 { state.previewItem = item } else { state.dupes.setKeep(g.id, item.id) } }
                        .contextMenu { FileMenu(items: [item]) }
                    }
                }
            }
        }
        .padding(16).card(16)
    }
}

extension CleanupKind {
    /// One of them, for Recently removed: "Old installer · you moved it to the Trash".
    var removalReason: String {
        switch self {
        case .bigOldVideos: return "Big old video"
        case .oldInstallers: return "Old installer"
        case .duplicates: return "Duplicate"
        case .unusedApps: return "Unused app"
        case .lookAlikes: return "Look-alike photo"
        case .mailAttachments: return "Mail attachment"
        case .appLeftovers: return "Leftover from a deleted app"
        case .forgottenDownloads: return "Forgotten download"
        case .oldScreenshots: return "Old screenshot"
        }
    }
}


/// Finder icons for files in ~/Library, kept once asked for: NSWorkspace looks each one up from disk.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 400 { cache.removeAll() }
        cache[path] = i
        return i
    }
}
