import AppKit

/// Tidy's checks outside the files Orca indexes: Mail's saved attachments, what deleted apps left behind
/// in ~/Library, and what the Trash is holding. All of it is read-only until you choose to clear it.
enum LibraryCleanup {
    private static let fm = FileManager.default
    private static var home: URL { fm.homeDirectoryForCurrentUser }

    // MARK: Mail attachments

    /// Mail keeps a copy of every attachment you open in "Mail Downloads"; the email keeps the original.
    /// nil: the folder couldn't be read (Mail's data needs Full Disk Access).
    static func mailAttachments() -> [CleanupCandidate]? {
        let dirs = [home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                    home.appendingPathComponent("Library/Mail Downloads")]
        var out: [CleanupCandidate] = []
        var readable = false
        for dir in dirs where fm.fileExists(atPath: dir.path) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            readable = true
            for e in entries {
                // Each attachment sits in its own folder: show the file's name, clear the folder.
                let inner = (try? fm.contentsOfDirectory(atPath: e.path))?.first { !$0.hasPrefix(".") }
                let size = allocatedSize(e)
                guard size > 0 else { continue }
                let date = (try? e.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                out.append(CleanupCandidate(item: item(e, name: inner ?? e.lastPathComponent, size: size, date: date),
                                            note: "Saved \(date.map { Fmt.relative($0) } ?? "by Mail")"))
            }
        }
        if !readable && dirs.contains(where: { fm.fileExists(atPath: $0.path) }) { return nil }
        return out
    }

    // MARK: Leftovers from deleted apps

    /// Folders and files in ~/Library named after an app's ID, when no app with that ID (or a related one)
    /// is on this Mac. Anything touched in the last 30 days is left out: something may still be using it.
    static func appLeftovers() -> [CleanupCandidate] {
        let installed = installedBundleIDs()
        let selfID = Bundle.main.bundleIdentifier ?? "app.orcafind.mac"
        let places: [(String, String)] = [("Library/Application Support", "Settings"), ("Library/Caches", "Cache"),
                                          ("Library/Preferences", "Preferences"), ("Library/Saved Application State", "Window state"),
                                          ("Library/HTTPStorages", "Web data"), ("Library/WebKit", "Web data")]
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        var out: [CleanupCandidate] = []
        for (place, what) in places {
            let dir = home.appendingPathComponent(place)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for e in entries {
                var id = e.lastPathComponent
                for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
                guard looksLikeBundleID(id), !id.hasPrefix("com.apple."), !id.hasPrefix(selfID), !id.hasPrefix("app.orcafind") else { continue }
                guard !isInstalled(id, installed) else { continue }
                let date = (try? e.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let date, date > monthAgo { continue }
                let size = allocatedSize(e)
                guard size > 0 else { continue }
                out.append(CleanupCandidate(item: item(e, name: e.lastPathComponent, size: size, date: date),
                                            note: "\(what) · \(appName(from: id)) is no longer installed"))
            }
        }
        return out
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 3, !s.contains(" ") else { return false }
        return parts.allSatisfy { p in !p.isEmpty && p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    }

    /// "com.tinyspeck.slackmacgap" → "Slackmacgap"
    static func appName(from id: String) -> String {
        (id.split(separator: ".").last.map(String.init) ?? id).capitalized
    }

    private static func isInstalled(_ id: String, _ installed: Set<String>) -> Bool {
        let lower = id.lowercased()
        if installed.contains(lower) { return true }
        // A helper or a renamed edition of an installed app (com.google.Chrome.helper, com.microsoft.teams2).
        for app in installed where lower.hasPrefix(app + ".") || app.hasPrefix(lower + ".") || app.hasPrefix(lower) { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    private static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     home.appendingPathComponent("Applications").path]
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names where n.hasSuffix(".app") {
                if let id = Bundle(path: root + "/" + n)?.bundleIdentifier { ids.insert(id.lowercased()) }
            }
            // One level of folders inside /Applications ("Adobe Photoshop 2026/…").
            for n in names where !n.hasSuffix(".app") {
                let sub = root + "/" + n
                for m in (try? fm.contentsOfDirectory(atPath: sub)) ?? [] where m.hasSuffix(".app") {
                    if let id = Bundle(path: sub + "/" + m)?.bundleIdentifier { ids.insert(id.lowercased()) }
                }
            }
        }
        return ids
    }

    // MARK: Trash

    struct TrashInfo: Equatable {
        var size: Int64
        var count: Int
        /// False when macOS doesn't let Orca look inside (needs Full Disk Access).
        var readable: Bool
    }

    static func trashInfo() -> TrashInfo {
        guard let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: []) else {
            return TrashInfo(size: 0, count: 0, readable: false)
        }
        let visible = entries.filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".localized" }
        return TrashInfo(size: visible.reduce(0) { $0 + allocatedSize($1) }, count: visible.count, readable: true)
    }

    /// Erases everything in the Trash for good. Returns how many items went.
    @discardableResult
    static func emptyTrash() -> Int {
        guard let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: []) else { return 0 }
        var n = 0
        for e in entries where e.lastPathComponent != ".localized" {
            if (try? fm.removeItem(at: e)) != nil { n += 1 }
        }
        return n
    }

    // MARK: Helpers

    static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        var seen = 0
        while let f = e?.nextObject() as? URL {
            seen += 1
            if seen > 200_000 { break }   // a runaway cache: stop counting, the size is already big
            if let r = try? f.resourceValues(forKeys: keys), r.isDirectory != true {
                total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private static func item(_ url: URL, name: String, size: Int64, date: Date?) -> FileItem {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let ext = (name as NSString).pathExtension.lowercased()
        return FileItem(path: url.path, url: url, name: name, ext: ext, category: .other, size: size,
                        modified: date, isFolder: isDir, rootName: "Library")
    }
}
