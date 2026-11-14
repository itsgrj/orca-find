import Foundation
import Testing
@testable import OrcaFind

/// Recently removed: Put back in every state, kept captures, and look-alike names. Everything happens in a
/// temporary folder (ORCA_CAPTURES_DIR points the log and the captures there); the real Trash is never used.
@MainActor
@Suite("Recently removed", .serialized)
struct RemovalLogTests {
    let root: URL
    let downloads: URL
    let trash: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orca-removed-\(UUID().uuidString)", isDirectory: true)
        downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        trash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        for d in [downloads, trash] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        setenv("ORCA_CAPTURES_DIR", root.appendingPathComponent("Orca").path, 1)
    }

    private func write(_ url: URL, _ text: String = "hello") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A file "moved to the Trash" (into the fake Trash) and recorded like Trash.move does.
    private func trashed(_ name: String, from folder: URL? = nil) throws -> Removal {
        let original = (folder ?? downloads).appendingPathComponent(name)
        let now = trash.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try write(now)
        let e = Removal(batch: UUID(), date: Date(), kind: .trashed, automatic: false, name: name,
                        originalPath: original.path, nowPath: now.path, size: 5)
        RemovalLog.shared.record([e])
        return e
    }

    @Test func putsBackWhereItWas() throws {
        let e = try trashed("a.txt")
        #expect(RemovalLog.shared.state(e) == .ready)
        let landed = try RemovalLog.shared.putBack(e.id)
        #expect(landed?.path == downloads.appendingPathComponent("a.txt").path)
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("a.txt").path))
        let after = try #require(RemovalLog.shared.entries.first { $0.id == e.id })
        if case .done = RemovalLog.shared.state(after) {} else { Issue.record("expected done, got \(RemovalLog.shared.state(after))") }
    }

    @Test func neverOverwritesATakenName() throws {
        let e = try trashed("b.txt")
        try write(downloads.appendingPathComponent("b.txt"), "the new one")
        #expect(RemovalLog.shared.state(e) == .nameTaken(newName: "b 2.txt"))
        try RemovalLog.shared.putBack(e.id)
        #expect(try String(contentsOf: downloads.appendingPathComponent("b.txt"), encoding: .utf8) == "the new one")
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("b 2.txt").path))
    }

    @Test func missingFolderGoesToTheClosestFolderStillThere() throws {
        let e = try trashed("c.txt", from: downloads.appendingPathComponent("Old reports/2024"))
        if case .folderGone = RemovalLog.shared.state(e) {} else { Issue.record("expected folderGone") }
        let landed = try RemovalLog.shared.putBack(e.id)
        #expect(landed?.path == downloads.appendingPathComponent("c.txt").path)
    }

    @Test func emptiedTrashSaysSoAndDoesNothing() throws {
        let e = try trashed("d.txt")
        try FileManager.default.removeItem(atPath: e.nowPath!)
        #expect(RemovalLog.shared.state(e) == .trashEmptied)
        #expect(throws: (any Error).self) { try RemovalLog.shared.putBack(e.id) }
        #expect(!FileManager.default.fileExists(atPath: e.originalPath))
    }

    @Test func noticesWhenYouPutItBackYourself() throws {
        let e = try trashed("e.txt")
        try FileManager.default.moveItem(atPath: e.nowPath!, toPath: e.originalPath)
        #expect(RemovalLog.shared.state(e) == .alreadyBack)
    }

    @Test func undoMarksRowsPutBack() throws {
        let e = try trashed("f.txt")
        RemovalLog.shared.markRestored(trashedPaths: [e.nowPath!])
        let after = try #require(RemovalLog.shared.entries.first { $0.id == e.id })
        #expect(after.restored != nil)
    }

    @Test func deletedCaptureComesBack() throws {
        let c = Capture(id: "test-\(UUID().uuidString)", created: Date(), note: "pricing thread", title: "Pricing thread")
        try write(c.imageURL, "png")
        CaptureStore.shared.save(c)
        let id = try #require(RemovalLog.shared.removeCapture(c))
        CaptureStore.shared.delete(id: c.id)
        #expect(CaptureStore.shared.get(c.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: c.imageURL.path))
        let e = try #require(RemovalLog.shared.entries.first { $0.id == id })
        #expect(RemovalLog.shared.state(e) == .ready)
        try RemovalLog.shared.putBack(id)
        #expect(CaptureStore.shared.get(c.id)?.title == "Pricing thread")
        #expect(FileManager.default.fileExists(atPath: c.imageURL.path))
    }

    @Test func capturesAreErasedAfterThirtyDays() throws {
        let c = Capture(id: "old-\(UUID().uuidString)", created: Date(), title: "Old")
        try write(c.imageURL, "png")
        let id = try #require(RemovalLog.shared.removeCapture(c))
        let kept = RemovalLog.capturesFolder.appendingPathComponent("\(c.id).png")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        // Pretend it was deleted 31 days ago.
        var e = try #require(RemovalLog.shared.entries.first { $0.id == id })
        e.id = UUID(); e.date = Date().addingTimeInterval(-31 * 86_400)
        RemovalLog.shared.record([e])
        RemovalLog.shared.purge()
        #expect(!FileManager.default.fileExists(atPath: kept.path))
        #expect(!RemovalLog.shared.entries.contains { $0.id == e.id })
    }

    @Test func lookAlikeNames() throws {
        #expect(LookAlike.key("[ SIGMAFLOW ] ") == LookAlike.key("[ SIGMAFLOW ]"))
        #expect(LookAlike.key("Re\u{200B}port") == LookAlike.key("report"))
        let desk = root.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desk.appendingPathComponent("[ SIGMAFLOW ]"), withIntermediateDirectories: true)
        try write(desk.appendingPathComponent("[ SIGMAFLOW ] ").appendingPathComponent("plan.md"))
        try write(desk.appendingPathComponent("Notes").appendingPathComponent("x.md"))
        let groups = LookAlike.find(matching: "sigmaflow", roots: [desk])
        #expect(groups.count == 1)
        let g = try #require(groups.first)
        #expect(g.difference == "One name ends with a space")
        #expect(g.keeper?.name == "[ SIGMAFLOW ] ")
        #expect(LookAlike.find(matching: "notes", roots: [desk]).isEmpty)
    }
}
