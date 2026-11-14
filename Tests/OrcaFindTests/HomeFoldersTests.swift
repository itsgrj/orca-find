import Foundation
import Testing
@testable import OrcaFind

/// "Everything else in your home folder": own folders are searched, Library and the usual folders are not
/// walked twice, loose home files are found without opening any subfolder, and clean-up never sees them.
@Suite("Home folder search")
struct HomeFoldersTests {
    let home: URL

    init() throws {
        // macOS lists /var/folders/… as /private/var/folders/…, so start from the real path.
        let tmp = realpath(NSTemporaryDirectory(), nil).map { p in defer { free(p) }; return String(cString: p) } ?? NSTemporaryDirectory()
        home = URL(fileURLWithPath: tmp).appendingPathComponent("orca-home-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for d in ["Desktop", "Library/Caches", "SigmaFlow/Docs", "Claude", "miniconda3/pkgs", ".config", "Orca-key-backup"] {
            try fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        for f in ["notes.txt", "Desktop/on-desktop.txt", "Library/Caches/cache.txt", "SigmaFlow/Docs/plan.md",
                  "Claude/chat.md", "miniconda3/pkgs/tool.txt", ".config/secret.txt", "Orca-key-backup/orca-update-key.txt"] {
            try Data("x".utf8).write(to: home.appendingPathComponent(f))
        }
    }

    @Test func ownFoldersBecomeSearchOnlyRoots() {
        let roots = FileScanner.homeRoots(home: home, skipping: Set(FileScanner.defaultFolderNames()))
        #expect(roots.map(\.name) == ["Home", "Claude", "Orca-key-backup", "SigmaFlow"])
        let searchOnly = roots.filter { $0.searchOnly }.count, watched = roots.filter { $0.watched }.map(\.name)
        #expect(searchOnly == roots.count)
        #expect(watched == ["Claude", "Orca-key-backup", "SigmaFlow"])
    }

    @Test func scanFindsOwnFilesOnly() {
        let roots = FileScanner.homeRoots(home: home, skipping: Set(FileScanner.defaultFolderNames()))
        let found = Set(FileScanner.scan(roots: roots).map { String($0.path.dropFirst(home.path.count + 1)) })
        #expect(found == ["notes.txt", "SigmaFlow/Docs/plan.md", "Claude/chat.md", "Orca-key-backup/orca-update-key.txt"])
    }

    @Test func mostSpecificRootWins() {
        let roots = FileScanner.homeRoots(home: home, skipping: []) + [
            FileScanner.Root(url: home.appendingPathComponent("SigmaFlow/Docs"), name: "Docs", maxDepth: 14)
        ]
        #expect(FileScanner.root(for: home.appendingPathComponent("SigmaFlow/Docs/plan.md").path, in: roots)?.name == "Docs")
        #expect(FileScanner.root(for: home.appendingPathComponent("SigmaFlow/x.md").path, in: roots)?.name == "SigmaFlow")
        #expect(FileScanner.root(for: home.appendingPathComponent("notes.txt").path, in: roots)?.name == "Home")
        // The home folder's own root only covers loose files, never files deeper down.
        let homeRoot = roots.first { $0.name == "Home" }!
        let coversLibrary = homeRoot.covers(home.appendingPathComponent("Library/Caches/cache.txt").path)
        #expect(!coversLibrary)
    }

    /// On this Mac: every own folder in the home folder shows up, nothing is listed twice, Library never.
    @Test func realHomeRootsListing() {
        let roots = FileScanner.roots(extraFolders: [], disabledDefaults: [])
        print("ROOTS:", roots.map { "\($0.name)\($0.searchOnly ? "*" : "")" })
        let names = roots.map(\.name)
        #expect(names.contains("Home"))
        #expect(!names.contains("Library"))
        #expect(Set(names.filter { $0 != "Applications" }).count == names.filter { $0 != "Applications" }.count)
        let own = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory())) ?? []
        for name in ["SigmaFlow", "Claude"] where own.contains(name) { #expect(names.contains(name)) }
    }
}
