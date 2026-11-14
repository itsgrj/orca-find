import AppKit

/// One thing Orca took away: a file it moved to the Trash or filed into a folder, an original an edit
/// replaced, or a capture (or its clip) you deleted. Kept 30 days so "did Orca delete this?" always has an answer.
struct Removal: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case trashed, filed, replaced, capture, clip }

    var id = UUID()
    /// Removals made by one action (one Move to Trash, one hourly clean up) share a batch: one Timeline card.
    var batch: UUID
    var date: Date
    var kind: Kind
    var automatic: Bool
    /// Why, in plain words: "Old installer", "Duplicate". Nil for a plain Move to Trash.
    var reason: String?
    /// Where you were when you did it: "Library › Images".
    var from: String?
    var name: String
    var originalPath: String
    /// Where it is now: in the Trash, in the folder it was filed into, or in Orca's removed-captures folder.
    var nowPath: String?
    var size: Int64 = 0
    /// Replaced: the name of the edited copy that took its place.
    var replacedBy: String?
    var captureID: String?
    var captureTitle: String?
    /// The whole capture, so Put back can bring it back exactly.
    var captureJSON: Data?
    var clipSeconds: Double?
    var restored: Date?
    var restoredPath: String?

    var isCapture: Bool { kind == .capture || kind == .clip }
    /// When Orca erases a deleted capture or clip for good.
    var expires: Date { date.addingTimeInterval(RemovalLog.keepDays * 86_400) }
}

/// What Put back can do for a row right now. The button only shows when it will work.
enum PutBackState: Equatable {
    case ready
    case nameTaken(newName: String)
    case folderGone(folder: String)
    case alreadyBack
    case trashEmptied
    case movedSince
    case done(Date)
}

@MainActor
@Observable
final class RemovalLog {
    static let shared = RemovalLog()
    nonisolated static let keepDays: Double = 30

    /// Newest first.
    private(set) var entries: [Removal] = []

    private var fileURL: URL { CaptureStore.baseDirectory.appendingPathComponent("removed.json") }

    /// Deleted captures wait here (picture, voice note, clip) until they're put back or 30 days pass.
    static var capturesFolder: URL {
        let dir = CaptureStore.folder.appendingPathComponent("Removed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? RemovalLog.decoder.decode([Removal].self, from: data) {
            entries = list
        }
        purge()
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private func save() {
        guard let data = try? RemovalLog.encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Everything from the last 30 days.
    var recent: [Removal] {
        let cutoff = Date().addingTimeInterval(-RemovalLog.keepDays * 86_400)
        return entries.filter { $0.date > cutoff }
    }

    // MARK: - Recording

    func record(_ list: [Removal]) {
        guard !list.isEmpty else { return }
        entries.insert(contentsOf: list.sorted { $0.date > $1.date }, at: 0)
        save()
    }

    /// Files moved to the Trash in one go.
    func recordTrashed(_ moved: [(original: URL, trashed: URL, size: Int64)], automatic: Bool, reason: String?, from: String?) {
        let batch = UUID(), now = Date()
        record(moved.map {
            Removal(batch: batch, date: now, kind: .trashed, automatic: automatic, reason: reason, from: from,
                    name: $0.original.lastPathComponent, originalPath: $0.original.path, nowPath: $0.trashed.path, size: $0.size)
        })
    }

    /// Screenshots the monthly rule moved into a folder.
    func recordFiled(_ moved: [(original: URL, filed: URL, size: Int64)]) {
        let batch = UUID(), now = Date()
        record(moved.map {
            Removal(batch: batch, date: now, kind: .filed, automatic: true, reason: "Filed into a monthly folder",
                    name: $0.original.lastPathComponent, originalPath: $0.original.path, nowPath: $0.filed.path, size: $0.size)
        })
    }

    /// An original that went to the Trash so the edited copy could take its place.
    func recordReplaced(original: URL, trashed: URL, size: Int64, copyName: String) {
        record([Removal(batch: UUID(), date: Date(), kind: .replaced, automatic: false, name: original.lastPathComponent,
                        originalPath: original.path, nowPath: trashed.path, size: size, replacedBy: copyName)])
    }

    /// The Undo right after a Move to Trash: those rows become "put back", they don't disappear.
    func markRestored(trashedPaths: [String]) {
        let set = Set(trashedPaths)
        var changed = false
        for i in entries.indices where entries[i].restored == nil && set.contains(entries[i].nowPath ?? "") {
            entries[i].restored = Date(); entries[i].restoredPath = entries[i].originalPath; changed = true
        }
        if changed { save() }
    }

    // MARK: - Captures (kept 30 days, then erased: the only thing Orca ever deletes itself)

    /// Moves the capture's files aside and remembers the capture, so Put back can bring it back exactly.
    /// Returns the row's id, or nil if its picture couldn't be kept (then the caller erases it as before).
    func removeCapture(_ c: Capture) -> UUID? {
        let fm = FileManager.default
        let dir = RemovalLog.capturesFolder
        let picture = dir.appendingPathComponent("\(c.id).png")
        for ext in ["png", "m4a", "mov"] {
            let src = CaptureStore.folder.appendingPathComponent("\(c.id).\(ext)")
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dir.appendingPathComponent("\(c.id).\(ext)")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        guard fm.fileExists(atPath: picture.path), let json = try? JSONEncoder().encode(c) else { return nil }
        let size = ["png", "m4a", "mov"].reduce(Int64(0)) { $0 + RemovalLog.fileSize(dir.appendingPathComponent("\(c.id).\($1)")) }
        let e = Removal(batch: UUID(), date: Date(), kind: .capture, automatic: false, from: "Captures",
                        name: RemovalLog.captureName(c), originalPath: CaptureStore.folder.appendingPathComponent("\(c.id).png").path,
                        nowPath: picture.path, size: size, captureID: c.id, captureTitle: RemovalLog.captureName(c), captureJSON: json)
        record([e])
        return e.id
    }

    /// Delete Clip, Keep Picture: the clip waits here the same way. Returns the row's id.
    func removeClip(of c: Capture) -> UUID? {
        let fm = FileManager.default
        let dst = RemovalLog.capturesFolder.appendingPathComponent("\(c.id).mov")
        try? fm.removeItem(at: dst)
        guard (try? fm.moveItem(at: c.clipURL, to: dst)) != nil else { try? fm.removeItem(at: c.clipURL); return nil }
        let e = Removal(batch: UUID(), date: Date(), kind: .clip, automatic: false, from: "Captures",
                        name: "Clip from “\(RemovalLog.captureName(c))”", originalPath: c.clipURL.path, nowPath: dst.path,
                        size: RemovalLog.fileSize(dst), captureID: c.id, captureTitle: RemovalLog.captureName(c), clipSeconds: c.clipSeconds)
        record([e])
        return e.id
    }

    static func captureName(_ c: Capture) -> String {
        if !c.title.isEmpty { return c.title }
        let note = c.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return String(note.prefix(60)) }
        return "Capture from \(c.sourceLabel)"
    }

    /// Drops rows older than 30 days, and erases the deleted captures and clips they were keeping.
    func purge() {
        let cutoff = Date().addingTimeInterval(-RemovalLog.keepDays * 86_400)
        let old = entries.filter { $0.date <= cutoff }
        guard !old.isEmpty else { return }
        let fm = FileManager.default
        for e in old where e.isCapture && e.restored == nil {
            guard let id = e.captureID else { continue }
            let exts = e.kind == .clip ? ["mov"] : ["png", "m4a", "mov"]
            for ext in exts { try? fm.removeItem(at: RemovalLog.capturesFolder.appendingPathComponent("\(id).\(ext)")) }
        }
        let ids = Set(old.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    // MARK: - Put back

    func state(_ e: Removal) -> PutBackState {
        if let r = e.restored { return .done(r) }
        let fm = FileManager.default
        switch e.kind {
        case .capture:
            guard let id = e.captureID, e.captureJSON != nil else { return .trashEmptied }
            if CaptureStore.shared.get(id) != nil { return .alreadyBack }
            return fm.fileExists(atPath: RemovalLog.capturesFolder.appendingPathComponent("\(id).png").path) ? .ready : .trashEmptied
        case .clip:
            guard let id = e.captureID, CaptureStore.shared.get(id) != nil else { return .movedSince }
            return fm.fileExists(atPath: e.nowPath ?? "") ? .ready : .trashEmptied
        case .trashed, .replaced, .filed:
            let now = e.nowPath ?? ""
            if !fm.fileExists(atPath: now) {
                // Gone from where Orca put it. If the same file is back at its old place, you put it back yourself.
                if fm.fileExists(atPath: e.originalPath), e.size == 0 || RemovalLog.fileSize(URL(fileURLWithPath: e.originalPath)) == e.size {
                    return .alreadyBack
                }
                return e.kind == .filed ? .movedSince : .trashEmptied
            }
            let original = URL(fileURLWithPath: e.originalPath)
            let parent = original.deletingLastPathComponent()
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: parent.path, isDirectory: &isDir) || !isDir.boolValue {
                return .folderGone(folder: RemovalLog.friendlyFolder(RemovalLog.fallbackFolder(for: original).path))
            }
            if fm.fileExists(atPath: original.path) {
                return .nameTaken(newName: RemovalLog.freeURL(for: original).lastPathComponent)
            }
            return .ready
        }
    }

    enum PutBackError: LocalizedError {
        case cannot(String)
        var errorDescription: String? { if case .cannot(let s) = self { return s }; return nil }
    }

    /// Puts it back. Never overwrites: a taken name gets " 2", a missing folder sends it to the top folder it lived in.
    @discardableResult
    func putBack(_ id: UUID) throws -> URL? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let e = entries[i]
        let fm = FileManager.default
        var landed: URL?
        switch e.kind {
        case .capture:
            guard let cid = e.captureID, let data = e.captureJSON, var c = try? JSONDecoder().decode(Capture.self, from: data) else {
                throw PutBackError.cannot("This capture can’t come back")
            }
            for ext in ["png", "m4a", "mov"] {
                let src = RemovalLog.capturesFolder.appendingPathComponent("\(cid).\(ext)")
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = CaptureStore.folder.appendingPathComponent("\(cid).\(ext)")
                try? fm.removeItem(at: dst)
                try fm.moveItem(at: src, to: dst)
            }
            c.reminderID = nil
            CaptureStore.shared.save(c)
            CaptureLibrary.shared.reload()
            RemovalLog.readdReminder(c)
            landed = CaptureStore.folder.appendingPathComponent("\(cid).png")
        case .clip:
            guard let cid = e.captureID, var c = CaptureStore.shared.get(cid), let now = e.nowPath else {
                throw PutBackError.cannot("Its capture is gone")
            }
            try? fm.removeItem(at: c.clipURL)
            try fm.moveItem(at: URL(fileURLWithPath: now), to: c.clipURL)
            c.clipSeconds = e.clipSeconds
            CaptureLibrary.shared.update(c)
            landed = c.clipURL
        case .trashed, .replaced, .filed:
            guard let now = e.nowPath, fm.fileExists(atPath: now) else {
                throw PutBackError.cannot(e.kind == .filed ? "It was moved since" : "The Trash was emptied")
            }
            var original = URL(fileURLWithPath: e.originalPath)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: original.deletingLastPathComponent().path, isDirectory: &isDir) || !isDir.boolValue {
                original = RemovalLog.fallbackFolder(for: original).appendingPathComponent(original.lastPathComponent)
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let dest = fm.fileExists(atPath: original.path) ? RemovalLog.freeURL(for: original) : original
            try fm.moveItem(at: URL(fileURLWithPath: now), to: dest)
            // A filed screenshot was in the index at its new place; the Trash isn't indexed.
            if e.kind == .filed { FileIndex.shared.remove(paths: [now]) }
            if let item = FileScanner.makeItem(url: dest, rootName: FileIndex.rootName(for: dest.path, items: [])) {
                FileIndex.shared.upsert([item])
            }
            landed = dest
        }
        entries[i].restored = Date()
        entries[i].restoredPath = landed?.path
        save()
        return landed
    }

    private static func readdReminder(_ c: Capture) {
        guard let due = c.reminderDate, due > Date() else { return }
        Task { @MainActor in
            var notes = c.note
            if let link = c.links.first { notes += "\n\n" + link }
            let title = c.title.isEmpty ? "Look at your capture" : c.title
            if let rid = await RemindersBridge.add(title: title, notes: notes, due: due, link: c.deepLink),
               var fresh = CaptureStore.shared.get(c.id) {
                fresh.reminderID = rid
                CaptureLibrary.shared.update(fresh)
            }
        }
    }

    // MARK: - Words

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// "IMG_4100 copy 2.JPG" when "IMG_4100 copy.JPG" is taken.
    nonisolated static func freeURL(for url: URL) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        var candidate = url
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// When its folder is gone: the closest folder above it that's still there (usually the top folder it
    /// lived in: Documents, Downloads, Desktop). Never the home folder or the disk itself; then the Desktop.
    nonisolated static func fallbackFolder(for url: URL) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var dir = url.deletingLastPathComponent().standardizedFileURL
        let fm = FileManager.default
        while dir.path != "/" && dir.path != home {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: home).appendingPathComponent("Desktop", isDirectory: true)
    }

    /// "Documents › Invoices", "Desktop", "Screenshots › 2026-11 November" (the last `depth` folders).
    nonisolated static func friendlyFolder(_ path: String, depth: Int = 3) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p.hasPrefix(home + "/") { p = String(p.dropFirst(home.count + 1)) } else if p == home { return "your home folder" }
        let parts = p.split(separator: "/").map(String.init)
        if parts.isEmpty { return "/" }
        return parts.suffix(depth).joined(separator: " › ")
    }

    /// "in Downloads" / "on Desktop" / "in Documents › Invoices".
    nonisolated static func place(_ folderPath: String) -> String {
        let f = friendlyFolder(folderPath)
        return f == "Desktop" ? "on Desktop" : "in \(f)"
    }
}

// MARK: - Look-alike names

/// Two files or folders in one place whose names differ only by spaces, capitals or invisible characters,
/// so Finder shows them as the same. The usual reason a folder "vanished" when nothing was deleted.
struct LookAlikeGroup: Identifiable {
    struct Member: Identifiable {
        let url: URL
        let isFolder: Bool
        let count: Int
        let size: Int64
        let created: Date?
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var isEmpty: Bool { isFolder ? count == 0 : size == 0 }
    }
    let members: [Member]
    var id: String { members.map(\.id).joined(separator: "|") }
    var folder: String { members.first?.url.deletingLastPathComponent().path ?? "" }
    var allFolders: Bool { members.allSatisfy(\.isFolder) }
    /// The one with the files in it.
    var keeper: Member? { members.max { ($0.isFolder ? Int64($0.count) : $0.size) < ($1.isFolder ? Int64($1.count) : $1.size) } }

    /// "One name ends with a space"
    var difference: String {
        let names = members.map(\.name)
        func has(_ test: (String) -> Bool) -> Bool { names.contains(where: test) && !names.allSatisfy(test) }
        if has({ $0.hasSuffix(" ") || $0.hasSuffix("\u{00A0}") }) { return "One name ends with a space" }
        if has({ $0.hasPrefix(" ") || $0.hasPrefix("\u{00A0}") }) { return "One name starts with a space" }
        if has({ $0.unicodeScalars.contains(where: LookAlike.invisible.contains) }) { return "One name has an invisible character in it" }
        if has({ $0.contains("  ") }) { return "One name has two spaces where the other has one" }
        if Set(names.map { $0.lowercased() }).count == 1 { return "The names differ only in capital letters" }
        return "The names differ only by spaces"
    }

    /// "Their names differ only by a space at the end."
    var differsBy: String {
        switch difference {
        case "One name ends with a space": return "Their names differ only by a space at the end."
        case "One name starts with a space": return "Their names differ only by a space at the start."
        case "One name has an invisible character in it": return "Their names differ only by an invisible character."
        case "One name has two spaces where the other has one": return "Their names differ only by an extra space."
        case "The names differ only in capital letters": return "Their names differ only in capital letters."
        default: return "Their names differ only by spaces."
        }
    }
}

enum LookAlike {
    static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]

    /// Same name once spaces, capitals and invisible characters are set aside.
    static func key(_ name: String) -> String {
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { !invisible.contains($0) }))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .lowercased()
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Looks through the top two levels of the folders Orca watches for look-alike names matching `query`
    /// (or every look-alike when `query` is empty). Flags a group only when one member is empty or much smaller.
    nonisolated static func find(matching query: String, roots: [URL]) -> [LookAlikeGroup] {
        let q = key(query)
        let fm = FileManager.default
        var groups: [LookAlikeGroup] = []
        var visit: [(URL, Int)] = roots.map { ($0, 0) }
        var looked = 0
        while let (dir, depth) = visit.popLast(), looked < 4_000 {
            looked += 1
            guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles]) else { continue }
            var byKey: [String: [URL]] = [:]
            for k in kids { byKey[key(k.lastPathComponent), default: []].append(k) }
            for (k, urls) in byKey where urls.count > 1 && (q.isEmpty || k.contains(q)) {
                let members = urls.map(member)
                let sizes = members.map { $0.isFolder ? Int64($0.count) : $0.size }
                let big = sizes.max() ?? 0, small = sizes.min() ?? 0
                if small == 0 || (big > 0 && Double(small) / Double(big) < 0.1) {
                    groups.append(LookAlikeGroup(members: members.sorted { $0.isEmpty && !$1.isEmpty }))
                }
            }
            if depth < 1 {
                for k in kids {
                    let v = try? k.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    if v?.isDirectory == true && v?.isPackage != true { visit.append((k, depth + 1)) }
                }
            }
        }
        return groups
    }

    nonisolated private static func member(_ url: URL) -> LookAlikeGroup.Member {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey])
        let isFolder = v?.isDirectory == true && v?.isPackage != true
        var count = 0
        var size = Int64(v?.fileSize ?? 0)
        if isFolder, let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            size = 0
            for case let f as URL in e {
                count += 1
                size += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if count > 20_000 { break }
            }
        }
        return .init(url: url, isFolder: isFolder, count: count, size: size, created: v?.creationDate)
    }

    @MainActor static var watchedRoots: [URL] {
        let roots = FileIndex.shared.roots.isEmpty
            ? FileScanner.roots(extraFolders: Preferences.shared.extraFolders, disabledDefaults: Set(Preferences.shared.disabledDefaultFolders))
            : FileIndex.shared.roots
        return roots.filter { $0.name != "Applications" && $0.watched }.map(\.url)
    }
}
