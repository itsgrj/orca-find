import SwiftUI

// MARK: - Downloads

struct DownloadsScreen: View {
    @Environment(AppState.self) private var state

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
                    ForEach(items) { item in
                        DownloadRow(item: item, selected: state.selection.contains(item.id))
                            .onTapGesture { state.click(item, in: items) }
                            .contextMenu { FileMenu(items: state.selection.contains(item.id) ? state.selectedItems : [item]) }
                            .onDrag { NSItemProvider(object: item.url as NSURL) }
                        Rectangle().fill(DS.border).frame(height: 1)
                    }
                }
            }
        }
        .card(14)
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

    private let colors: [CleanupKind: UInt32] = [.bigOldVideos: 0x7C5CFF, .oldInstallers: 0xFFB020, .duplicates: 0x3BA4FF, .unusedApps: 0xF46A60, .forgottenDownloads: 0x1FB57A, .oldScreenshots: 0x8A9BA8]
    private let tones: [CleanupKind: DS.Tone] = [.bigOldVideos: .magic, .oldInstallers: .attention, .duplicates: .info, .unusedApps: .critical, .forgottenDownloads: .success, .oldScreenshots: .emphasis]

    var body: some View {
        let tidy = state.tidy
        let scanning = tidy.isScanning || state.dupes.isScanning
        GeometryReader { geo in
            let cw = (geo.size.width - 64 - 32) / 3
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: scanning && tidy.lastScan == nil ? "Looking around…" : "You could free \(Fmt.size(tidy.grandTotal))",
                                 subtitle: "Nothing is deleted — files go to the Trash, and Undo is one click away.") {
                        if scanning { ProgressView().controlSize(.small) }
                        Button("Scan again") { tidy.scan(); state.dupes.scan() }.buttonStyle(.secondary).disabled(scanning)
                    }
                    storageBar
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cw), spacing: 16, alignment: .top), count: 3), alignment: .leading, spacing: 16) {
                        ForEach(order, id: \.self) { kind in card(kind) }
                    }
                    autoRules
                }
                .padding(.horizontal, 32).padding(.vertical, 22)
            }
        }
    }

    private var order: [CleanupKind] { [.bigOldVideos, .oldInstallers, .duplicates, .unusedApps, .forgottenDownloads, .oldScreenshots] }

    private var storageBar: some View {
        let tidy = state.tidy
        let total = max(1, order.reduce(Int64(0)) { $0 + tidy.total($1) })
        let disk = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]))
        let used = Int64(disk?.volumeTotalCapacity ?? 0) - (disk?.volumeAvailableCapacityForImportantUsage ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(order, id: \.self) { k in
                        let v = tidy.total(k)
                        if v > 0 { Rectangle().fill(Color(hex: colors[k]!)).frame(width: max(3, g.size.width * CGFloat(Double(v) / Double(total)))) }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 16) {
                ForEach(order, id: \.self) { k in
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: colors[k]!)).frame(width: 8, height: 8)
                        Text("\(k.title) \(Fmt.size(tidy.total(k)))").font(DS.caption).foregroundStyle(DS.text2)
                    }
                }
                Spacer()
                if used > 0 { Text("\(Fmt.size(used)) of \(Fmt.size(Int64(disk?.volumeTotalCapacity ?? 0))) used").font(DS.caption).foregroundStyle(DS.text2) }
            }
        }
        .padding(16).card(14)
    }

    private func card(_ kind: CleanupKind) -> some View {
        let tidy = state.tidy
        let items: [FileItem] = kind == .duplicates ? state.dupes.groups.prefix(4).compactMap { $0.items.first } : (tidy.results[kind] ?? []).prefix(4).map(\.item)
        let count = tidy.count(kind)
        let scanning = kind == .duplicates ? state.dupes.isScanning : tidy.isScanning
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ToneIcon(symbol: symbol(kind), tone: tones[kind]!, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(DS.body).foregroundStyle(DS.text)
                    Text(kind.detail).font(DS.caption).foregroundStyle(DS.text2).lineLimit(2)
                }
                Spacer(minLength: 4)
                if scanning { ProgressView().controlSize(.small) } else { Text(tidy.total(kind) > 0 ? Fmt.size(tidy.total(kind)) : "—").font(DS.stat).foregroundStyle(DS.text) }
            }
            HStack(spacing: 10) {
                HStack(spacing: -10) {
                    ForEach(items) { i in
                        Thumb(item: i, size: 88, mode: i.category == .images || i.category == .videos ? .fill : .fit)
                            .frame(width: 44, height: 44).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DS.surface, lineWidth: 2))
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    }
                }
                Text(scanning ? "Checking…" : count == 0 ? "All clear" : (kind == .duplicates ? Fmt.plural(state.dupes.groups.count, "group") : Fmt.plural(count, "file")))
                    .font(DS.bodySM).foregroundStyle(DS.text2)
                Spacer()
                Button("Review") { state.navigate(kind == .duplicates ? .duplicates : .cleanUpReview(kind)) }
                    .buttonStyle(.secondary).disabled(count == 0)
            }
        }
        .padding(16).card(16)
    }

    private func symbol(_ k: CleanupKind) -> String {
        switch k {
        case .forgottenDownloads: return "tray.and.arrow.down"
        case .oldInstallers: return "shippingbox"
        case .duplicates: return "square.on.square"
        case .bigOldVideos: return "film"
        case .oldScreenshots: return "camera.viewfinder"
        case .unusedApps: return "moon.zzz"
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

    var body: some View {
        let candidates = state.tidy.results[kind] ?? []
        let selected = candidates.filter { checked.contains($0.id) }.map(\.item)
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: kind.title, subtitle: kind.detail, back: ("Tidy", { state.navigate(.cleanUp) })) {
                Button("Trash selected (\(selected.count))") { state.trash(selected); checked = [] }.buttonStyle(.secondary).disabled(selected.isEmpty)
                Button("Trash all · \(Fmt.size(candidates.reduce(0) { $0 + $1.item.size }))") { confirmAll = true }.buttonStyle(.critical).disabled(candidates.isEmpty)
            }
            if candidates.isEmpty {
                EmptyState(symbol: "sparkles", tag: "All clean", tone: .success, title: "Nothing to tidy here", message: "We'll check again tomorrow.").frame(maxWidth: .infinity)
                Spacer()
            } else {
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
        .confirmationDialog("Move \(Fmt.plural(candidates.count, "file")) to the Trash?", isPresented: $confirmAll) {
            Button("Move All to Trash", role: .destructive) { state.trash(candidates.map(\.item)); checked = [] }
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
        .confirmationDialog("Move \(Fmt.plural(m.selectedExtras.count, "duplicate")) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { state.trash(m.selectedExtras) }
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
