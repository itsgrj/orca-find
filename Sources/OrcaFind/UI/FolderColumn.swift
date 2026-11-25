import Foundation

/// What the list's Folder column says for each file.
///
/// Usually just the folder the file sits in ("Invoices", or "Home" for files directly in the home
/// folder). When two files in the same list have exactly the same name, one folder name may not be
/// enough: both copies of LICENSE.txt can sit in folders called "fonts" and "Fonts". Then each of
/// those rows shows as much of the path as it takes to tell them apart: "BrowserExtension › fonts"
/// vs "Resources › Fonts". Folder names are compared ignoring case, so that pair does count as a clash.
enum FolderLabels {
    static let separator = " › "

    /// Labels for files whose names clash, keyed by file id. Files not in here use `plain(for:)`.
    /// One pass over the names; only clashing groups do any path work.
    static func clashing(in items: [FileItem]) -> [String: String] {
        var seen = Set<String>(minimumCapacity: items.count)
        var dupes = Set<String>()
        for item in items where !seen.insert(item.name).inserted { dupes.insert(item.name) }
        guard !dupes.isEmpty else { return [:] }

        var groups: [String: [FileItem]] = [:]
        for item in items where dupes.contains(item.name) { groups[item.name, default: []].append(item) }

        var out: [String: String] = [:]
        for group in groups.values {
            let paths = group.map { folders(of: $0) }
            // Grow every copy's label one folder at a time; a copy is done once no other copy
            // ends in the same folders (ignoring case), or when it runs out of folders.
            // Linear in the group size per step, so hundreds of "index.js" stay cheap.
            var pending = Array(paths.indices)
            var k = 1
            while !pending.isEmpty {
                let tails = paths.map { $0.suffix(k).joined(separator: "/").lowercased() }
                var counts: [String: Int] = [:]
                for t in tails { counts[t, default: 0] += 1 }
                pending = pending.filter { i in
                    guard counts[tails[i]] == 1 || k >= paths[i].count else { return true }
                    out[group[i].id] = paths[i].suffix(k).joined(separator: separator)
                    return false
                }
                k += 1
            }
        }
        return out
    }

    /// Remembers the last list's labels. The table redraws on every click (selection), and checking
    /// 10k names each time costs 4–11 ms; comparing ids (paths) against the last list is ~0.1 ms.
    final class Cache {
        private var ids: [String] = []
        private var labels: [String: String] = [:]
        func labels(for items: [FileItem]) -> [String: String] {
            if items.count == ids.count, zip(items, ids).allSatisfy({ $0.id == $1 }) { return labels }
            ids = items.map(\.id)
            labels = FolderLabels.clashing(in: items)
            return labels
        }
    }

    /// The folder the file sits in, the way the column shows it.
    static func plain(for item: FileItem) -> String { folders(of: item).last ?? "" }

    /// The file's folders from the top down, starting at "Home" for anything inside the home folder.
    private static func folders(of item: FileItem) -> [String] {
        let parent = item.parentPath
        let home = NSHomeDirectory()
        if parent == home { return ["Home"] }
        if parent.hasPrefix(home + "/") {
            return ["Home"] + parent.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        }
        let parts = parent.split(separator: "/").map(String.init)
        return parts.isEmpty ? ["/"] : parts
    }
}
