import Foundation

/// Orca Find never deletes anything permanently: every removal goes to the Trash and can be undone.
/// Each one is also written to Recently removed (RemovalLog), with who did it and why.
@MainActor
enum Trash {
    struct Result {
        var moved: [(original: URL, trashed: URL)] = []
        var failed: [URL] = []
        var bytes: Int64 = 0
        var count: Int { moved.count }
    }

    /// `automatic`: an automatic clean up rule did it. `reason`: "Old installer", "Duplicate"…
    /// `from`: where you were, "Library › Images".
    static func move(_ items: [FileItem], automatic: Bool = false, reason: String? = nil, from: String? = nil) -> Result {
        var result = Result()
        var logged: [(original: URL, trashed: URL, size: Int64)] = []
        for item in items {
            var trashed: NSURL?
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
                if let t = trashed as URL? {
                    result.moved.append((item.url, t))
                    logged.append((item.url, t, item.size))
                }
                result.bytes += item.size
            } catch {
                result.failed.append(item.url)
            }
        }
        FileIndex.shared.remove(paths: result.moved.map { $0.original.path })
        RemovalLog.shared.recordTrashed(logged, automatic: automatic, reason: reason, from: from)
        return result
    }

    /// Puts items back where they were. Returns how many came back.
    @discardableResult
    static func restore(_ result: Result) -> Int {
        var restored = 0
        var back: [String] = []
        for (original, trashed) in result.moved {
            do {
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: trashed, to: original)
                restored += 1
                back.append(trashed.path)
                if let item = FileScanner.makeItem(url: original, rootName: FileIndex.rootName(for: original.path, items: [])) {
                    FileIndex.shared.upsert([item])
                }
            } catch {
                NSLog("OrcaFind: could not restore \(original.path): \(error)")
            }
        }
        RemovalLog.shared.markRestored(trashedPaths: back)
        return restored
    }
}
