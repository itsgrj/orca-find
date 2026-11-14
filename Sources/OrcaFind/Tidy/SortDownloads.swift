import Foundation

/// Sort into folders: puts the loose files in ~/Downloads into a folder per kind. Always shown as a plan
/// first; nothing moves until you say so, and Undo puts every file back.
enum SortDownloads {
    struct Group: Identifiable {
        let folder: String           // "Pictures"
        var files: [FileItem]
        var id: String { folder }
        var size: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    struct Plan {
        var groups: [Group] = []
        /// Still downloading, or added in the last 2 minutes.
        var leftAlone: [FileItem] = []
        /// Kinds without a folder of their own (stay where they are).
        var other: [FileItem] = []
        var count: Int { groups.reduce(0) { $0 + $1.files.count } }
    }

    struct Done {
        var moves: [(from: URL, to: URL)] = []
        var madeFolders: [URL] = []
        var count: Int { moves.count }
    }

    static let partialExts: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]
    static let order = ["Pictures", "Videos", "Music", "Documents", "Installers", "Archives"]

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].standardizedFileURL
    }

    static func folder(for item: FileItem) -> String? {
        if item.isInstaller { return "Installers" }
        switch item.category {
        case .images: return "Pictures"
        case .videos: return "Videos"
        case .music: return "Music"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .apps, .other: return nil
        }
    }

    /// The loose files directly in Downloads (not ones already in a subfolder).
    static func plan(_ items: [FileItem], now: Date = Date()) -> Plan {
        let root = downloadsFolder.path
        var byFolder: [String: [FileItem]] = [:]
        var plan = Plan()
        for item in items where !item.isFolder && !item.isPackage
            && item.url.deletingLastPathComponent().standardizedFileURL.path == root
            && !item.name.hasPrefix(".") {
            let fresh = now.timeIntervalSince(max(item.added ?? .distantPast, item.modified ?? .distantPast)) < 120
            if fresh || partialExts.contains(item.ext.lowercased()) { plan.leftAlone.append(item); continue }
            if let f = folder(for: item) { byFolder[f, default: []].append(item) } else { plan.other.append(item) }
        }
        plan.groups = order.compactMap { f in byFolder[f].map { Group(folder: f, files: $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) } }
        return plan
    }

    static func run(_ plan: Plan) -> Done {
        let fm = FileManager.default
        var done = Done()
        for g in plan.groups {
            let dir = downloadsFolder.appendingPathComponent(g.folder, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true); done.madeFolders.append(dir) } catch { continue }
            }
            for f in g.files {
                // Skip anything that changed since the plan was shown (moved, renamed, still being written).
                guard fm.fileExists(atPath: f.path) else { continue }
                let dest = FileDrop.freeName(for: f.name, in: dir)
                do { try fm.moveItem(at: f.url, to: dest); done.moves.append((f.url, dest)) } catch {
                    NSLog("OrcaFind: sort could not move \(f.path): \(error.localizedDescription)")
                }
            }
        }
        return done
    }

    /// Puts every file back, and removes the folders the sort made if they're empty again.
    @discardableResult
    static func undo(_ done: Done) -> Int {
        let fm = FileManager.default
        var n = 0
        for m in done.moves.reversed() {
            let back = fm.fileExists(atPath: m.from.path) ? FileDrop.freeName(for: m.from.lastPathComponent, in: m.from.deletingLastPathComponent()) : m.from
            if (try? fm.moveItem(at: m.to, to: back)) != nil { n += 1 }
        }
        for dir in done.madeFolders {
            let left = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0 != ".DS_Store" } ?? []
            if left.isEmpty { try? fm.removeItem(at: dir) }
        }
        return n
    }
}
