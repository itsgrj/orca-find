import SwiftUI
import UniformTypeIdentifiers

// Tidy › Recently removed: everything Orca moved to the Trash, filed away, replaced with an edit,
// or a capture you deleted, with when, who and why, and Put back. Figma: "Proposals · Recently removed".

enum RemovedFilter: CaseIterable {
    case everything, byYou, automatic, captures
    var title: String {
        switch self {
        case .everything: return "Everything"
        case .byYou: return "By you"
        case .automatic: return "Automatic"
        case .captures: return "Captures"
        }
    }
    func matches(_ e: Removal) -> Bool {
        switch self {
        case .everything: return true
        case .byYou: return !e.automatic && !e.isCapture
        case .automatic: return e.automatic
        case .captures: return e.isCapture
        }
    }
}

/// Row state that only lasts while the screen is open: "Putting back…", then "Back where it was".
@MainActor
@Observable
final class PutBackSession {
    var busy: Set<UUID> = []
    var justBack: Set<UUID> = []

    func putBack(_ ids: [UUID]) {
        let log = RemovalLog.shared
        let todo = ids.filter { !busy.contains($0) }
        guard !todo.isEmpty else { return }
        busy.formUnion(todo)
        Task { @MainActor in
            // A beat of "Putting back…" so the change reads as an action, not a flicker.
            try? await Task.sleep(nanoseconds: 250_000_000)
            var failed: [String] = []
            for id in todo {
                do { try log.putBack(id); justBack.insert(id) } catch { failed.append(error.localizedDescription) }
            }
            busy.subtract(todo)
            if let f = failed.first { AppState.shared.showToast("Couldn’t put it back: \(f)") }
        }
    }
}

struct RecentlyRemovedScreen: View {
    /// Design snapshots only: open with this typed in the search box.
    static var snapshotQuery: String?

    @Environment(AppState.self) private var state
    @State private var query = RecentlyRemovedScreen.snapshotQuery ?? ""
    @State private var filter: RemovedFilter = .everything
    @State private var session = PutBackSession()
    @State private var lookAlikes: [LookAlikeGroup]?

    private var log: RemovalLog { RemovalLog.shared }

    var body: some View {
        @Bindable var prefs = state.prefs
        let all = log.recent
        let searched = all.filter { RecentlyRemovedScreen.matches($0, query) }
        let shown = searched.filter(filter.matches)
        let timeline = prefs.removedTimeline
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "Recently removed",
                             subtitle: all.isEmpty ? "Nothing in the last 30 days"
                                : timeline ? "What Orca did with your files, day by day"
                                : "\(Fmt.plural(all.count, "thing")) in the last 30 days",
                             back: ("Tidy", { state.navigate(.cleanUp) })) {
                    if !all.isEmpty {
                        ViewSwitch(timeline: $prefs.removedTimeline)
                        RemovedSearchField(text: $query)
                    }
                }
                if all.isEmpty {
                    EmptyRemoved().frame(maxWidth: .infinity).padding(.top, 110)
                } else {
                    chips(searched, counts: !timeline)
                    if !query.isEmpty && searched.isEmpty {
                        NothingCalled(query: query, groups: lookAlikes)
                    } else if shown.isEmpty {
                        Text("Nothing here in the last 30 days.").font(DS.body).foregroundStyle(DS.text2).padding(.top, 8)
                    } else if timeline {
                        RemovedTimeline(entries: shown, session: session)
                    } else {
                        note
                        RemovedList(entries: shown, session: session)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
        }
        .task(id: query) {
            lookAlikes = nil
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2, !log.recent.contains(where: { RecentlyRemovedScreen.matches($0, q) }) else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let roots = LookAlike.watchedRoots
            let found = await Task.detached(priority: .userInitiated) { LookAlike.find(matching: q, roots: roots) }.value
            if !Task.isCancelled { lookAlikes = found }
        }
    }

    static func matches(_ e: Removal, _ q: String) -> Bool {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let key = LookAlike.key(q)
        return LookAlike.key(e.name).contains(key) || LookAlike.key(e.originalPath).contains(key)
            || LookAlike.key(e.captureTitle ?? "").contains(key)
    }

    private func chips(_ list: [Removal], counts: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(RemovedFilter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    Chip(label: counts ? "\(f.title) · \(list.filter(f.matches).count)" : f.title,
                         style: filter == f ? .selected : .normal)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var note: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
            Text("Files stay in your Mac’s Trash, so Put back works until the Trash is emptied. Captures you delete stay here for 30 days.")
                .font(DS.body)
        }
        .foregroundStyle(DS.Tone.info.fg)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Tone.info.bg))
    }
}

// MARK: - Header controls

private struct ViewSwitch: View {
    @Binding var timeline: Bool
    var body: some View {
        HStack(spacing: 2) {
            seg("List", "line.3.horizontal.decrease", !timeline) { timeline = false }
            seg("Timeline", "calendar", timeline) { timeline = true }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.tertiary.opacity(0.75)))
    }

    private func seg(_ label: String, _ symbol: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(label).font(DS.body)
            }
            .foregroundStyle(on ? DS.text : DS.text2)
            .padding(.horizontal, 10).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? DS.surface : .clear)
                .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }
}

private struct RemovedSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(DS.text3)
            TextField("", text: $text, prompt: Text("Search removed things").foregroundColor(DS.text3))
                .textFieldStyle(.plain).font(DS.body).foregroundStyle(DS.text).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.text3) }
                    .buttonStyle(.plain).help("Clear").handCursor()
            }
        }
        .padding(.horizontal, 8).frame(width: 260, height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? DS.focus : DS.border, lineWidth: focused ? 2 : 1))
    }
}

// MARK: - Words

enum RemovedWords {
    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()
    static let shortDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()
    static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f }()

    /// "9:00 AM" today and yesterday, "Mon 9 Nov" before that.
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        return cal.isDateInToday(d) || cal.isDateInYesterday(d) ? time.string(from: d) : day.string(from: d)
    }

    /// TODAY · YESTERDAY · EARLIER THIS WEEK · EARLIER
    static func bucket(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if d > Date().addingTimeInterval(-7 * 86_400) { return "Earlier this week" }
        return "Earlier"
    }

    static func grouped<T>(_ list: [T], date: (T) -> Date) -> [(String, [T])] {
        var out: [(String, [T])] = []
        for x in list {
            let b = bucket(date(x))
            if let i = out.firstIndex(where: { $0.0 == b }) { out[i].1.append(x) } else { out.append((b, [x])) }
        }
        return out
    }

    /// "Put back today", "Put back on Mon", "Put back on 9 Nov".
    static func putBackOn(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Put back today" }
        if cal.isDateInYesterday(d) { return "Put back yesterday" }
        if d > Date().addingTimeInterval(-6 * 86_400) { return "Put back on \(weekday.string(from: d))" }
        return "Put back on \(shortDay.string(from: d))"
    }

    static func goneFor(_ e: Removal) -> String {
        let days = Int(ceil(e.expires.timeIntervalSinceNow / 86_400))
        if days <= 1 { return "gone for good tomorrow" }
        if days <= 3 { return "gone for good in \(days) days" }
        return "gone for good on \(shortDay.string(from: e.expires))"
    }

    static func folder(_ e: Removal) -> String { (e.originalPath as NSString).deletingLastPathComponent }

    /// The small label: "Old installer · automatic", "You moved it to the Trash".
    static func badge(_ e: Removal) -> (String, DS.Tone) {
        switch e.kind {
        case .filed: return ("Filed into a monthly folder · automatic", .info)
        case .replaced: return ("Replaced by your edit", .neutral)
        case .capture: return ("You deleted this capture", .neutral)
        case .clip: return ("You deleted this clip", .neutral)
        case .trashed:
            if e.automatic { return ("\(e.reason ?? "Clean up") · automatic", .info) }
            if let r = e.reason { return ("\(r) · you moved it to the Trash", .neutral) }
            return ("You moved it to the Trash", .neutral)
        }
    }

    /// The second line under the name, which says what changed when Put back can't go the simple way.
    static func detail(_ e: Removal, _ s: PutBackState, justBack: Bool) -> String {
        let was = "Was \(RemovalLog.place(folder(e)))"
        switch s {
        case .nameTaken:
            return "A new file called \(e.name) is \(RemovalLog.place(folder(e)))"
        case .folderGone:
            return "Its folder \(RemovalLog.friendlyFolder(folder(e))) isn’t there any more"
        case .alreadyBack:
            return e.isCapture ? "It’s back in Captures" : "You put it back yourself (from the Trash in Finder)"
        case .done:
            if e.isCapture { return "Back in Captures" }
            guard let p = e.restoredPath else { return was }
            let name = (p as NSString).lastPathComponent
            let back = "Back \(RemovalLog.place((p as NSString).deletingLastPathComponent))"
            return name == e.name ? back : "\(back) as \(name)"
        default: break
        }
        switch e.kind {
        case .capture, .clip: return "Capture · \(goneFor(e))"
        case .filed: return "\(was) · now in \(RemovalLog.friendlyFolder(((e.nowPath ?? "") as NSString).deletingLastPathComponent, depth: 2))"
        case .replaced: return "\(was) · your edited copy took its place"
        case .trashed: return was
        }
    }

    static func plural(_ word: String, _ n: Int) -> String {
        guard n != 1 else { return word }
        let lower = word.lowercased()
        if lower.hasSuffix("y") && !lower.hasSuffix("ay") { return String(word.dropLast()) + "ies" }
        return word + "s"
    }
}

// MARK: - Row pieces shared by List and Timeline

/// The 28 pt thumbnail: the real file (from wherever it is now), the capture's picture, or a kind icon.
struct RemovedThumb: View {
    let entry: Removal
    var size: CGFloat = 28
    @State private var item: FileItem?
    @State private var picture: NSImage?

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
            } else if let item {
                Thumb(item: item, size: size * 2, mode: item.category == .images || item.category == .videos ? .fill : .fit)
            } else {
                ZStack {
                    DS.tertiary
                    Image(systemName: symbol).font(.system(size: size * 0.5)).foregroundStyle(DS.text2)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: entry.restored) { await load() }
    }

    private var symbol: String {
        if entry.isCapture { return "camera.viewfinder" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if FileCategory.installerExts.contains(ext) { return "shippingbox" }
        return KindPalette.symbol(FileCategory.classify(ext: ext, type: UTType(filenameExtension: ext)))
    }

    /// Disk checks and picture decoding happen off the main thread, so a long list doesn't stall scrolling.
    private func load() async {
        if entry.isCapture, let id = entry.captureID {
            let here = [RemovalLog.capturesFolder.appendingPathComponent("\(id).png"), CaptureStore.folder.appendingPathComponent("\(id).png")]
            let px = Int(size * 3)
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let url = here.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
                return CaptureStore.pngData(url, maxPixel: px)
            }.value
            if Task.isCancelled { return }
            picture = data.flatMap(NSImage.init(data:))
            return
        }
        let candidates = [entry.restoredPath, entry.nowPath, entry.originalPath].compactMap { $0 }
        let path = await Task.detached(priority: .utility) {
            candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        }.value
        if Task.isCancelled { return }
        guard let path else { item = nil; return }
        if let known = FileIndex.shared.item(path) {
            item = known
        } else {
            let url = URL(fileURLWithPath: path)
            item = await Task.detached(priority: .utility) { FileScanner.makeItem(url: url, rootName: "") }.value
        }
        // Installers and archives have no picture worth showing; the kind icon reads better.
        if let i = item, i.isInstaller || i.category == .archives || i.category == .other { item = nil }
    }
}

/// What the trailing side of a row offers. The button only shows when it will work.
struct PutBackControls: View {
    @Environment(AppState.self) private var state
    let entry: Removal
    let session: PutBackSession
    /// Timeline sub-rows use quieter, plain buttons.
    var compact = false
    /// On a Timeline card (which has its own "Show folder").
    var timeline = false

    var body: some View {
        let s = RemovalLog.shared.state(entry)
        HStack(spacing: 10) {
            if session.busy.contains(entry.id) {
                Text("Putting back…").font(DS.bodySM).foregroundStyle(DS.text3)
            } else {
                switch s {
                case .ready:
                    if entry.kind == .filed && !compact && !timeline, let p = entry.nowPath { reveal(p) }
                    put(entry.kind == .replaced && timeline ? "Put the original back" : "Put back")
                case .nameTaken(let n):
                    put("Put back as “\(n)”")
                case .folderGone(let f):
                    put("Put back in \(f)")
                case .alreadyBack:
                    Text("Already back").font(DS.bodySM).foregroundStyle(DS.text2)
                    if !entry.isCapture { reveal(entry.originalPath) }
                case .trashEmptied:
                    Text(entry.isCapture ? "Gone for good" : "The Trash was emptied")
                        .font(DS.bodySM).foregroundStyle(DS.text3)
                case .movedSince:
                    Text(entry.kind == .clip ? "Its capture is gone" : "It was moved since").font(DS.bodySM).foregroundStyle(DS.text3)
                case .done(let d):
                    if session.justBack.contains(entry.id) {
                        Text("Back where it was").font(DS.bodySM).foregroundStyle(DS.Tone.success.fg)
                        if entry.isCapture {
                            if let id = entry.captureID {
                                Button("Open") { state.navigate(.capture(id)) }.buttonStyle(.plainP)
                            }
                        } else if let p = entry.restoredPath { reveal(p) }
                    } else {
                        Text(RemovedWords.putBackOn(d)).font(DS.bodySM).foregroundStyle(DS.Tone.success.fg)
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private func put(_ label: String) -> some View {
        Button(label) { session.putBack([entry.id]) }
            .buttonStyle(compact ? PButtonStyle(kind: .plain) : PButtonStyle(kind: .secondary))
            .truncationMode(.middle)
    }

    private func reveal(_ path: String) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            .buttonStyle(.plainP)
    }
}

// MARK: - List (opens first)

private struct RemovedList: View {
    let entries: [Removal]
    let session: PutBackSession

    static let nameWidth: CGFloat = 404
    static let badgeWidth: CGFloat = 330
    static let whenWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 28, height: 1)
                Text("Name").frame(maxWidth: Self.nameWidth, alignment: .leading).layoutPriority(1)
                Text("What happened").frame(width: Self.badgeWidth, alignment: .leading)
                Text("When").frame(width: Self.whenWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .font(DS.bodySM).foregroundStyle(DS.text2)
            .padding(.horizontal, 12).frame(height: 30)
            ForEach(RemovedWords.grouped(entries, date: \.date), id: \.0) { bucket, rows in
                PixelLabel(bucket, color: DS.text3)
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                ForEach(rows) { e in RemovedRow(entry: e, session: session) }
            }
        }
        .padding(8)
        .card(14)
    }
}

private struct RemovedRow: View {
    let entry: Removal
    let session: PutBackSession
    @State private var hover = false

    var body: some View {
        let s = RemovalLog.shared.state(entry)
        let gone = s == .trashEmptied
        let badge = RemovedWords.badge(entry)
        HStack(spacing: 12) {
            RemovedThumb(entry: entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(DS.body).foregroundStyle(gone ? DS.text3 : DS.text)
                Text(RemovedWords.detail(entry, s, justBack: session.justBack.contains(entry.id)))
                    .font(DS.bodySM).foregroundStyle(DS.text3)
            }
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: RemovedList.nameWidth, alignment: .leading).layoutPriority(1)
            Badge(badge.0, tone: badge.1).frame(width: RemovedList.badgeWidth, alignment: .leading)
            Text(RemovedWords.when(entry.date)).font(DS.body).foregroundStyle(DS.text2)
                .frame(width: RemovedList.whenWidth, alignment: .leading)
            Spacer(minLength: 0)
            PutBackControls(entry: entry, session: session).fixedSize()
        }
        .padding(.horizontal, 12).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? DS.hover : .clear))
        .onHover { hover = $0 }
        .help(entry.originalPath)
    }
}

// MARK: - Timeline (sentences, one card per action)

private struct RemovedTimeline: View {
    let entries: [Removal]
    let session: PutBackSession

    var body: some View {
        let batches = RemovedTimeline.batches(entries)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(RemovedWords.grouped(batches, date: { $0[0].date }), id: \.0) { bucket, list in
                PixelLabel(bucket, color: DS.text2).padding(.top, 4)
                ForEach(Array(list.enumerated()), id: \.element[0].batch) { i, batch in
                    HStack(alignment: .top, spacing: 22) {
                        rail(batch, first: i == 0, last: i == list.count - 1)
                        TimelineCard(batch: batch, session: session)
                    }
                }
            }
        }
    }

    /// Entries of one action, kept in the order they happened.
    static func batches(_ list: [Removal]) -> [[Removal]] {
        var order: [UUID] = []
        var map: [UUID: [Removal]] = [:]
        for e in list {
            if map[e.batch] == nil { order.append(e.batch) }
            map[e.batch, default: []].append(e)
        }
        return order.compactMap { map[$0] }
    }

    private func rail(_ batch: [Removal], first: Bool, last: Bool) -> some View {
        let e = batch[0]
        return ToneIcon(symbol: TimelineCard.symbol(e), tone: e.automatic ? .info : .neutral, size: 36)
            .padding(.top, 12)
            .frame(width: 44)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(alignment: .top) {
                Rectangle().fill(DS.border).frame(width: 1)
                    .padding(.top, first ? 12 : -12).padding(.bottom, last ? 0 : -12)
            }
    }
}

private struct TimelineCard: View {
    @Environment(AppState.self) private var state
    let batch: [Removal]
    let session: PutBackSession

    private var first: Removal { batch[0] }

    var body: some View {
        let log = RemovalLog.shared
        let open = batch.filter { e in
            switch log.state(e) { case .ready, .nameTaken, .folderGone: return !session.busy.contains(e.id); default: return false }
        }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(DS.headingSM).foregroundStyle(DS.text).lineLimit(2)
                    Text(subtitle).font(DS.bodySM).foregroundStyle(DS.text2).lineLimit(1)
                }
                Spacer(minLength: 12)
                if first.kind == .filed, let p = first.nowPath {
                    Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }.buttonStyle(.plainP)
                }
                if batch.count == 1 {
                    PutBackControls(entry: first, session: session, timeline: true)
                } else if !open.isEmpty {
                    Button(open.count == 2 ? "Put both back" : open.count == batch.count ? "Put all back" : "Put \(open.count) back") {
                        session.putBack(open.map(\.id))
                    }.buttonStyle(.secondary)
                } else if batch.contains(where: { session.busy.contains($0.id) }) {
                    Text("Putting back…").font(DS.bodySM).foregroundStyle(DS.text3)
                }
            }
            if batch.count > 1 {
                if first.kind == .filed { strip } else { subList }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(14)
    }

    static func symbol(_ e: Removal) -> String {
        switch e.kind {
        case .filed: return "photo.on.rectangle.angled"
        case .replaced: return "wand.and.stars"
        case .capture, .clip: return "camera.viewfinder"
        case .trashed: return e.reason == "Old installer" ? "shippingbox" : "trash"
        }
    }

    private var title: String {
        let e = first, n = batch.count
        switch e.kind {
        case .filed:
            let to = RemovalLog.friendlyFolder(((e.nowPath ?? "") as NSString).deletingLastPathComponent, depth: 2)
            return n == 1 ? "Orca filed \(e.name) into \(to)" : "Orca filed \(n) screenshots into \(to)"
        case .replaced: return "Your edited copy replaced \(e.name)"
        case .capture: return "You deleted the capture “\(e.captureTitle ?? e.name)”"
        case .clip: return "You deleted the clip from “\(e.captureTitle ?? "a capture")”"
        case .trashed:
            let who = e.automatic ? "Orca" : "You"
            if n == 1 { return "\(who) moved \(e.name) to the Trash" }
            let what = e.reason.map { RemovedWords.plural($0.lowercased(), n) } ?? "items"
            return "\(who) moved \(n) \(what) to the Trash"
        }
    }

    private var subtitle: String {
        let e = first
        let time = RemovedWords.time.string(from: e.date)
        let was = "was \(RemovalLog.place(RemovedWords.folder(e)))"
        var parts: [String]
        switch e.kind {
        case .filed: parts = ["Automatic clean up", "moved, not deleted"]
        case .replaced: parts = ["The original went to the Trash", was]
        case .capture, .clip: parts = ["Kept here until \(RemovedWords.shortDay.string(from: e.expires)), then gone for good"]
        case .trashed:
            if e.automatic {
                parts = ["Automatic clean up", e.reason == "Old installer"
                         ? "installers older than \(state.prefs.autoInstallerDays) days" : (e.reason ?? "").lowercased()]
            } else {
                parts = [e.from.map { "From \($0)" }, batch.count == 1 ? was : nil].compactMap { $0 }
            }
        }
        return (parts.filter { !$0.isEmpty } + [time]).joined(separator: " · ")
    }

    /// Up to six files with their own Put back.
    private var subList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(batch.prefix(6)) { e in
                HStack(spacing: 10) {
                    RemovedThumb(entry: e, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).font(DS.body).foregroundStyle(DS.text)
                        Text("\(RemovedWords.detail(e, RemovalLog.shared.state(e), justBack: false))\(e.size > 0 ? " · \(Fmt.size(e.size))" : "")")
                            .font(DS.bodySM).foregroundStyle(DS.text3)
                    }
                    .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    PutBackControls(entry: e, session: session, compact: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            if batch.count > 6 {
                Text("and \(batch.count - 6) more").font(DS.bodySM).foregroundStyle(DS.text3).padding(.horizontal, 14).padding(.vertical, 4)
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.surface2))
    }

    /// Filed screenshots: a strip of pictures, the files are all in one folder.
    private var strip: some View {
        HStack(spacing: 6) {
            ForEach(batch.prefix(8)) { e in RemovedThumb(entry: e, size: 44) }
            Text("\(Fmt.plural(batch.count, "screenshot")) from your \(RemovalLog.friendlyFolder(RemovedWords.folder(first)))")
                .font(DS.bodySM).foregroundStyle(DS.text2).padding(.leading, 4)
        }
    }
}

// MARK: - Empty (07) and "nothing called …" (10)

private struct EmptyRemoved: View {
    @Environment(AppState.self) private var state
    var body: some View {
        VStack(spacing: 56) {
            VStack(spacing: 12) {
                DitherBlob(symbol: "tray")
                Text("Orca hasn’t removed anything").font(DS.headingSM).foregroundStyle(DS.text)
                Text("Anything Orca moves to the Trash or files away shows up here for 30 days, with a button to put it back.")
                    .font(DS.bodySM).foregroundStyle(DS.text2).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            .padding(28).frame(width: 434).card(16)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(DS.text2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looking for something that went missing?").font(DS.body).foregroundStyle(DS.text)
                    Text("Search for it on Home. Orca also checks for folders and files with almost the same name.")
                        .font(DS.bodySM).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 12)
                Button("Search on Home") { state.navigate(.home); state.focusSearch() }.buttonStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).frame(width: 664).card(10)
        }
    }
}

private struct NothingCalled: View {
    let query: String
    let groups: [LookAlikeGroup]?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Orca hasn’t removed anything called “\(query)”").font(DS.headingMD).foregroundStyle(DS.text)
            Text("Not in the last 30 days, not by you through Orca, and not by an automatic clean up. If it went missing, something outside Orca moved it, or it’s hiding behind a look-alike name.")
                .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            if let groups {
                ForEach(groups) { g in LookAlikeNote(group: g) }
            } else if query.count >= 2 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking for look-alike names…").font(DS.bodySM).foregroundStyle(DS.text3)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(14)
    }
}

/// The short look-alike note inside search (10).
private struct LookAlikeNote: View {
    let group: LookAlikeGroup
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.doc").font(.system(size: 18)).foregroundStyle(DS.Tone.attention.fg)
            VStack(alignment: .leading, spacing: 2) {
                Text(LookAlikeWords.headline(group)).font(DS.body)
                Text(LookAlikeWords.short(group)).font(DS.bodySM)
            }
            .foregroundStyle(DS.Tone.attention.fg)
            Spacer(minLength: 12)
            Button("Show both") { LookAlikeWords.reveal(group) }.buttonStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Tone.attention.bg))
    }
}

// MARK: - Look-alike names on Home search (09)

enum LookAlikeWords {
    static func kindWord(_ g: LookAlikeGroup, _ n: Int) -> String {
        g.allFolders ? (n == 1 ? "folder" : "folders") : (n == 1 ? "file" : "files")
    }

    /// "2 folders on your Desktop are called “[ SIGMAFLOW ]”"
    static func headline(_ g: LookAlikeGroup) -> String {
        let shown = g.keeper?.name.trimmingCharacters(in: .whitespaces) ?? ""
        let place = RemovalLog.friendlyFolder(g.folder)
        return "\(g.members.count) \(kindWord(g, g.members.count)) \(place == "Desktop" ? "on your Desktop" : "in \(place)") are called “\(shown)”"
    }

    static func amount(_ m: LookAlikeGroup.Member) -> String {
        if m.isFolder { return m.count == 0 ? "is empty" : "has \(Fmt.plural(m.count, "item")) (\(Fmt.size(m.size)))" }
        return m.size == 0 ? "is empty" : "is \(Fmt.size(m.size))"
    }

    /// "One is empty, the other has 30 items (5 GB). Their names differ only by a space at the end."
    static func short(_ g: LookAlikeGroup) -> String {
        let sorted = g.members.sorted { ($0.isFolder ? Int64($0.count) : $0.size) < ($1.isFolder ? Int64($1.count) : $1.size) }
        let first = sorted.first.map(amount) ?? ""
        let last = sorted.last.map(amount) ?? ""
        return "One \(first), the other \(last). \(g.differsBy)"

    }

    static func reveal(_ g: LookAlikeGroup) {
        NSWorkspace.shared.activateFileViewerSelecting(g.members.map(\.url))
    }

    static func memberNote(_ m: LookAlikeGroup.Member, in g: LookAlikeGroup) -> String {
        var parts = [RemovalLog.friendlyFolder(g.folder)]
        if let c = m.created { parts.append("made \(RemovedWords.shortDay.string(from: c))") }
        let n = m.name
        if n.hasSuffix(" ") { parts.append("name ends with a space") }
        else if n.hasPrefix(" ") { parts.append("name starts with a space") }
        else if n.unicodeScalars.contains(where: LookAlike.invisible.contains) { parts.append("name has an invisible character") }
        if m.id == g.keeper?.id && !m.isEmpty { parts.append(g.allFolders ? "your files are here" : "this is the full one") }
        return parts.joined(separator: " · ")
    }
}

/// Above Home search results when the words match look-alike names: says nothing was deleted, and where the files are.
struct LookAlikeBanner: View {
    let group: LookAlikeGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "doc.on.doc").font(.system(size: 20)).foregroundStyle(DS.Tone.attention.fg).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("These \(group.members.count == 2 ? "two" : "\(group.members.count)") \(LookAlikeWords.kindWord(group, 2)) look the same, but they aren’t")
                        .font(DS.headingSM)
                    Text(explanation).font(DS.body).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.Tone.attention.fg)
                Spacer(minLength: 12)
                Button("Show \(group.members.count == 2 ? "both" : "all") in Finder") { LookAlikeWords.reveal(group) }.buttonStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(group.members) { m in member(m) }
            }
            .padding(.leading, 34)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Tone.attention.bg))
    }

    private var explanation: String {
        let emptyOne = group.members.contains(where: \.isEmpty)
        let lead = "\(group.difference), so Finder shows them identically."
        let which = emptyOne
            ? " One of them is empty; \(group.allFolders ? "your files are in the other one" : "the other one is the full file")."
            : " One is much smaller than the other."
        return lead + which + " Nothing was deleted."
    }

    private func member(_ m: LookAlikeGroup.Member) -> some View {
        let keeper = m.id == group.keeper?.id && !m.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: m.isFolder ? "folder.fill" : "doc.fill").font(.system(size: 13)).foregroundStyle(DS.text2)
                Text("“\(m.name)”").font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                Badge(m.isEmpty ? "Empty" : keeper ? (group.allFolders ? "Has your files" : "The full one") : LookAlikeWords.amount(m),
                      tone: keeper ? .success : .neutral)
            }
            Text("\(m.isFolder ? (m.count == 0 ? "Empty" : "\(Fmt.plural(m.count, "item")) · \(Fmt.size(m.size))") : Fmt.size(m.size)) · \(LookAlikeWords.memberNote(m, in: group))")
                .font(DS.bodySM).foregroundStyle(DS.text2).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .card(10)
    }
}

// MARK: - Tidy entry row (01)

struct RecentlyRemovedRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let recent = RemovalLog.shared.recent
        let week = recent.filter { $0.date > Date().addingTimeInterval(-7 * 86_400) }
        let auto = week.filter(\.automatic).count
        Button { state.navigate(.recentlyRemoved) } label: {
            HStack(spacing: 16) {
                ToneIcon(symbol: "arrow.uturn.backward", tone: .info, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recently removed").font(DS.body).foregroundStyle(DS.text)
                    Text("Everything Orca moved to the Trash or filed away, and why. Put anything back in one click.")
                        .font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
                }
                Spacer(minLength: 12)
                HStack(spacing: -8) {
                    ForEach(week.prefix(4)) { e in
                        RemovedThumb(entry: e, size: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.surface, lineWidth: 2))
                    }
                }
                Text(week.isEmpty ? (recent.isEmpty ? "Nothing yet" : "Nothing this week")
                     : "\(week.count) this week\(auto > 0 ? " · \(auto) automatic" : "")")
                    .font(DS.body).foregroundStyle(DS.text2)
                Text("Open").font(DS.bodySM).foregroundStyle(DS.text)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.borderStrong))
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .card(14)
    }
}
