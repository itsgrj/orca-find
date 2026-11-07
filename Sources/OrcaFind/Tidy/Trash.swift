import Foundation

/// Orca Find never deletes anything permanently: every removal goes to the Trash and can be undone.
@MainActor
enum Trash {
    struct Result {
        var moved: [(original: URL, trashed: URL)] = []
        var failed: [URL] = []
        var bytes: Int64 = 0
        var count: Int { moved.count }
    }

    static func move(_ items: [FileItem]) -> Result {
        var result = Result()
        for item in items {
            var trashed: NSURL?
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
                if let t = trashed as URL? { result.moved.append((item.url, t)) }
                result.bytes += item.size
            } catch {
                result.failed.append(item.url)
            }
        }
        FileIndex.shared.remove(paths: result.moved.map { $0.original.path })
        return result
    }

    /// Puts items back where they were. Returns how many came back.
    @discardableResult
    static func restore(_ result: Result) -> Int {
        var restored = 0
        for (original, trashed) in result.moved {
            do {
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: trashed, to: original)
                restored += 1
            } catch {
                NSLog("OrcaFind: could not restore \(original.path): \(error)")
            }
        }
        return restored
    }
}
