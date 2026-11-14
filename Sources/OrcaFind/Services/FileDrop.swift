import AppKit
import UniformTypeIdentifiers

/// Putting dropped files away: into a folder (moved, or copied with ⌥), with an Undo that puts them back.
/// Shared by the menu bar drop panel and the Drop Shelf.
enum FileDrop {
    struct Done {
        var moves: [(from: URL, to: URL)] = []
        var copied = false
        var folderName = ""
        var count: Int { moves.count }

        /// "Moved brand-board-v3.jpg to Design", "Copied 3 files to Design"
        var message: String {
            let what = moves.count == 1 ? moves[0].to.lastPathComponent : Fmt.plural(moves.count, "file")
            return "\(copied ? "Copied" : "Moved") \(what) to \(folderName)"
        }
    }

    /// The folders a drop can go into: the ones pinned in OrcaFind, or Desktop and Documents until something is pinned.
    @MainActor static var targets: [URL] {
        let pinned = AppState.shared.pinnedFolders.map { URL(fileURLWithPath: $0) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if !pinned.isEmpty { return pinned }
        let fm = FileManager.default
        return [fm.urls(for: .desktopDirectory, in: .userDomainMask)[0], fm.urls(for: .documentDirectory, in: .userDomainMask)[0]]
    }

    static var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    /// Moves (or copies) each file into `folder`, never overwriting: a clash becomes "name 2.ext".
    static func put(_ urls: [URL], in folder: URL, copy: Bool) -> Done {
        let fm = FileManager.default
        var done = Done(copied: copy, folderName: fm.displayName(atPath: folder.path))
        for src in urls {
            let src = src.standardizedFileURL
            // Already in that folder, or the folder itself: nothing to do.
            if src.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path && !copy { continue }
            if src.path == folder.standardizedFileURL.path || folder.standardizedFileURL.path.hasPrefix(src.path + "/") { continue }
            let dest = freeName(for: src.lastPathComponent, in: folder)
            do {
                if copy { try fm.copyItem(at: src, to: dest) } else { try fm.moveItem(at: src, to: dest) }
                done.moves.append((src, dest))
            } catch {
                NSLog("OrcaFind: could not \(copy ? "copy" : "move") \(src.path): \(error.localizedDescription)")
            }
        }
        return done
    }

    /// Undo: moved files go back where they were; copies go to the Trash.
    @discardableResult
    static func undo(_ done: Done) -> Int {
        let fm = FileManager.default
        var n = 0
        for m in done.moves.reversed() {
            do {
                if done.copied {
                    try fm.trashItem(at: m.to, resultingItemURL: nil)
                } else {
                    let back = fm.fileExists(atPath: m.from.path) ? freeName(for: m.from.lastPathComponent, in: m.from.deletingLastPathComponent()) : m.from
                    try fm.moveItem(at: m.to, to: back)
                }
                n += 1
            } catch {
                NSLog("OrcaFind: could not undo \(m.to.path): \(error.localizedDescription)")
            }
        }
        return n
    }

    static func freeName(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var i = 2
        repeat {
            dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        } while fm.fileExists(atPath: dest.path)
        return dest
    }

    /// File URLs out of a SwiftUI drop.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
            }
            if let url { out.append(url) }
        }
        return out
    }
}
