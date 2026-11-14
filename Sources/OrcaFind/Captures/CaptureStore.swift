import Foundation
import SQLite3
import ImageIO
import UniformTypeIdentifiers

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One smart capture: a picture of part of the screen plus why it was saved.
struct Capture: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var created: Date
    /// What the person said (or typed) while capturing.
    var note: String = ""
    var noteTyped = false
    var title: String = ""
    var sourceApp: String?
    var sourceBundle: String?
    var windowTitle: String?
    /// The page the grab came from (taken from the browser automatically).
    var pageURL: String?
    /// The pin / post / video under the box when the page was a feed, or the link a grabbed card points to.
    var itemURL: String?
    /// Where the video on the page was when it was grabbed (YouTube), in seconds.
    var videoSeconds: Double?
    /// Links pasted with ⌘V while talking.
    var pastedLinks: [String] = []
    /// Text Orca read in the picture.
    var ocr: String = ""
    var collection: String?
    /// The words that put it in the collection, e.g. "for Friday's newsletter".
    var collectionPhrase: String?
    var reminderDate: Date?
    var reminderPhrase: String?
    var reminderID: String?
    var width: Int = 0
    var height: Int = 0
    var audioSeconds: Double = 0
    /// What it's about, across collections: ["design", "pricing"]. Optional so older captures still decode.
    var tags: [String]?
    /// Where each tag came from: "said" (“tag it design”), "orca" (suggested from the words and picture), "you" (added by hand).
    var tagOrigins: [String: String]?
    /// Length of the clip kept when what was grabbed was moving.
    var clipSeconds: Double?
    /// Who last listened to the recording to write `note`: nil = live words only, "apple" = Apple's recognizer
    /// over the whole recording, "model" = the downloaded English model. Never shown in the UI.
    var noteSource: String?

    /// Shared from Finder: where the file is (Orca remembers it, it doesn't keep a copy).
    var filePath: String?

    var tagList: [String] { tags ?? [] }
    var clipURL: URL { CaptureStore.folder.appendingPathComponent("\(id).mov") }
    var hasClip: Bool { (clipSeconds ?? 0) > 0 && FileManager.default.fileExists(atPath: clipURL.path) }

    mutating func addTag(_ raw: String, origin: String) {
        guard let t = CaptureTags.normalize(raw) else { return }
        var list = tagList
        guard !list.contains(where: { CaptureTags.same($0, t) }) else { return }
        list.append(t)
        tags = list
        var o = tagOrigins ?? [:]; o[t] = origin; tagOrigins = o
    }

    mutating func removeTag(_ t: String) {
        tags = tagList.filter { !CaptureTags.same($0, t) }
        tagOrigins?[t] = nil
    }

    func hasTag(_ t: String) -> Bool { tagList.contains { CaptureTags.same($0, t) } }

    var imageURL: URL { CaptureStore.folder.appendingPathComponent("\(id).png") }
    var audioURL: URL { CaptureStore.folder.appendingPathComponent("\(id).m4a") }
    var hasAudio: Bool { audioSeconds > 0.5 && FileManager.default.fileExists(atPath: audioURL.path) }
    var links: [String] { linkItems.map(\.url) }

    /// The page link, opening at the moment the video was at when it was grabbed.
    var pageLink: String? {
        guard let p = pageURL else { return nil }
        return videoSeconds.map { SourceLinks.atMoment(p, seconds: $0) } ?? p
    }

    struct Link: Hashable { let url: String; let label: String; let pasted: Bool }

    /// Every link with where it came from; the thing itself first, then the page, then what was pasted.
    var linkItems: [Link] {
        var out: [Link] = []
        if let item = itemURL {
            let kind = SourceLinks.item(item)?.kind
            let host = { (u: String?) in u.flatMap { URL(string: $0)?.host?.replacingOccurrences(of: "www.", with: "") } }
            let label = kind.map { "the \($0) you grabbed" }
                ?? (host(item) != host(pageURL) ? "where it links to" : "the link you grabbed")
            out.append(Link(url: item, label: label, pasted: false))
        }
        if let page = pageLink {
            let label = videoSeconds.map { "page it came from · at \(SourceLinks.clock($0))" }
                ?? (itemURL == nil ? "page it came from" : "page you were on")
            out.append(Link(url: page, label: label, pasted: false))
        }
        out += pastedLinks.map { Link(url: $0, label: "you pasted while talking", pasted: true) }
        return out
    }
    var deepLink: URL { URL(string: "orcafind://capture/\(id)")! }

    /// "X", "YouTube", "nytimes.com" or the app name.
    var sourceLabel: String {
        if let host = pageURL.flatMap({ URL(string: $0)?.host }) { return Capture.siteName(host) }
        return sourceApp ?? "Screen"
    }

    static func siteName(_ rawHost: String) -> String {
        let host = rawHost.lowercased().replacingOccurrences(of: "www.", with: "")
        let known: [(String, String)] = [
            ("x.com", "X"), ("twitter.com", "X"), ("instagram.com", "Instagram"), ("youtube.com", "YouTube"),
            ("youtu.be", "YouTube"), ("tiktok.com", "TikTok"), ("linkedin.com", "LinkedIn"), ("reddit.com", "Reddit"),
            ("threads.net", "Threads"), ("bsky.app", "Bluesky"), ("pinterest.com", "Pinterest"), ("github.com", "GitHub"),
            ("medium.com", "Medium"), ("substack.com", "Substack"), ("amazon.", "Amazon"), ("etsy.com", "Etsy"),
            ("figma.com", "Figma"), ("dribbble.com", "Dribbble"), ("behance.net", "Behance"), ("notion.so", "Notion"),
            ("docs.google.com", "Google Docs"), ("mail.google.com", "Gmail"), ("news.ycombinator.com", "Hacker News"),
            ("apps.apple.com", "App Store"), ("maps.google.com", "Google Maps"), ("spotify.com", "Spotify")
        ]
        for (k, v) in known where host == k || host.hasSuffix("." + k) || (k.hasSuffix(".") && host.contains(k)) { return v }
        return host
    }

    /// "Today", "Yesterday", "Mon", "6 Nov".
    static func shortDate(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    /// "Thu 9:00" for this week, "27 Nov" otherwise.
    static func reminderShort(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        let days = Calendar.current.dateComponents([.day], from: now, to: d).day ?? 99
        f.dateFormat = (0...6).contains(days) ? "EEE H:mm" : "d MMM"
        return f.string(from: d)
    }

    /// Plain-text version for AI tools and "Copy for AI".
    var asText: String {
        var lines = ["# \(title.isEmpty ? "Capture" : title)"]
        let df = ISO8601DateFormatter()
        lines.append("id: \(id)")
        lines.append("saved: \(df.string(from: created))")
        lines.append("source: \(sourceLabel)\(sourceApp.map { " (via \($0))" } ?? "")")
        if let c = collection { lines.append("collection: \(c)") }
        if !tagList.isEmpty { lines.append("tags: " + tagList.map { "#" + $0 }.joined(separator: " ")) }
        if let s = clipSeconds, s > 0 { lines.append("clip: \(Int(s.rounded())) s of video (the picture is its first frame)") }
        if let r = reminderDate { lines.append("reminder: \(df.string(from: r))") }
        if !links.isEmpty { lines.append("links: " + links.joined(separator: " , ")) }
        if let t = videoSeconds { lines.append("video moment: \(SourceLinks.clock(t)) (the page link opens there)") }
        lines.append("")
        lines.append("Why it was saved (\(noteTyped ? "typed" : "said out loud")):")
        lines.append(note.isEmpty ? "(no note)" : note)
        if !ocr.isEmpty {
            lines.append("")
            lines.append("Text in the picture:")
            lines.append(String(ocr.prefix(2000)))
        }
        return lines.joined(separator: "\n")
    }
}

/// SQLite store for captures (Application Support/OrcaFind/captures.sqlite + Captures/ folder).
/// Thread-safe and free of AppKit, so the MCP server (`OrcaFind --mcp`) can use it without the app running.
final class CaptureStore: @unchecked Sendable {
    static let shared = CaptureStore()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// Normally Application Support/OrcaFind; `ORCA_CAPTURES_DIR` points it elsewhere (snapshots, tests).
    static var baseDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["ORCA_CAPTURES_DIR"], !custom.isEmpty {
            let u = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        return Database.directory
    }

    static var folder: URL {
        let dir = baseDirectory.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        let path = CaptureStore.baseDirectory.appendingPathComponent("captures.sqlite").path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            NSLog("OrcaFind: could not open captures database at \(path)")
        }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS captures(
          rid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, created REAL NOT NULL, json TEXT NOT NULL,
          collection TEXT);
        CREATE INDEX IF NOT EXISTS captures_created ON captures(created);
        CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(note, title, ocr, links, collection, source,
          tokenize='unicode61 remove_diacritics 2');
        """)
    }

    // MARK: SQLite helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK, let err { NSLog("OrcaFind captures SQL error: \(String(cString: err))"); sqlite3_free(err) }
        return rc == SQLITE_OK
    }

    private func statement(_ sql: String, _ args: [Any?], _ body: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            if let db { NSLog("OrcaFind captures SQL prepare error: \(String(cString: sqlite3_errmsg(db)))") }
            return
        }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let x as Int: sqlite3_bind_int64(s, idx, Int64(x))
            case let x as Int64: sqlite3_bind_int64(s, idx, x)
            case let x as Double: sqlite3_bind_double(s, idx, x)
            case let x as String: sqlite3_bind_text(s, idx, x, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(s, idx)
            }
        }
        body(s)
    }

    private func run(_ sql: String, _ args: [Any?] = []) { statement(sql, args) { _ = sqlite3_step($0) } }

    private func rows(_ sql: String, _ args: [Any?] = [], _ each: (OpaquePointer) -> Void) {
        statement(sql, args) { s in while sqlite3_step(s) == SQLITE_ROW { each(s) } }
    }

    private func col(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    private func decode(_ s: OpaquePointer, _ i: Int32) -> Capture? {
        guard let json = col(s, i)?.data(using: .utf8) else { return nil }
        return try? CaptureStore.decoder.decode(Capture.self, from: json)
    }

    // MARK: Read / write

    func save(_ c: Capture) {
        guard let data = try? CaptureStore.encoder.encode(c), let json = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        run("""
            INSERT INTO captures(id, created, json, collection) VALUES(?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET json=excluded.json, collection=excluded.collection
            """, [c.id, c.created.timeIntervalSince1970, json, c.collection])
        var rid: Int64 = 0
        rows("SELECT rid FROM captures WHERE id = ?", [c.id]) { rid = sqlite3_column_int64($0, 0) }
        run("DELETE FROM captures_fts WHERE rowid = ?", [rid])
        run("INSERT INTO captures_fts(rowid, note, title, ocr, links, collection, source) VALUES(?,?,?,?,?,?,?)",
            [rid, c.note, c.title + " " + (c.windowTitle ?? ""), String(c.ocr.prefix(20_000)),
             c.links.joined(separator: " "), ([c.collection ?? ""] + c.tagList).joined(separator: " "), c.sourceLabel + " " + (c.sourceApp ?? "")])
        exec("COMMIT")
    }

    func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        var rid: Int64?
        rows("SELECT rid FROM captures WHERE id = ?", [id]) { rid = sqlite3_column_int64($0, 0) }
        if let rid { run("DELETE FROM captures_fts WHERE rowid = ?", [rid]) }
        run("DELETE FROM captures WHERE id = ?", [id])
        for ext in ["png", "m4a", "mov"] {
            try? FileManager.default.removeItem(at: CaptureStore.folder.appendingPathComponent("\(id).\(ext)"))
        }
    }

    func get(_ id: String) -> Capture? {
        var out: Capture?
        rows("SELECT json FROM captures WHERE id = ?", [id]) { out = decode($0, 0) }
        return out
    }

    /// Newest first.
    func all(limit: Int = 5000) -> [Capture] {
        var out: [Capture] = []
        rows("SELECT json FROM captures ORDER BY created DESC LIMIT ?", [limit]) { s in if let c = decode(s, 0) { out.append(c) } }
        return out
    }

    func collections() -> [(name: String, count: Int)] {
        var out: [(String, Int)] = []
        rows("SELECT collection, COUNT(*) FROM captures WHERE collection IS NOT NULL AND collection != '' GROUP BY collection COLLATE NOCASE ORDER BY MAX(created) DESC") { s in
            if let n = col(s, 0) { out.append((n, Int(sqlite3_column_int64(s, 1)))) }
        }
        return out
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "i", "me", "my", "we", "our", "you", "it", "this", "that", "these", "those", "is", "was", "were",
        "be", "to", "of", "in", "on", "at", "for", "from", "with", "and", "or", "but", "about", "saved", "save", "captured",
        "capture", "find", "show", "some", "something", "thing", "things", "any", "what", "which", "where", "when", "did",
        "do", "had", "have", "has", "there", "one", "ones", "please", "can", "could", "would", "all", "ago", "earlier"
    ]

    /// Full-text search over what was said, the title, the text in the picture, links and collection.
    /// `matchAll` = every word must appear (typing); otherwise best matches for any word (natural questions).
    func search(_ text: String, matchAll: Bool = true, limit: Int = 200) -> [Capture] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let useful = words.filter { !CaptureStore.stopwords.contains($0) }
        let terms = (useful.isEmpty ? words : useful).map { "\"\($0)\"*" }
        guard !terms.isEmpty else { return all(limit: limit) }
        let q = terms.joined(separator: matchAll ? " AND " : " OR ")
        var out: [Capture] = []
        rows("""
            SELECT c.json FROM captures_fts f JOIN captures c ON c.rid = f.rowid
            WHERE captures_fts MATCH ? ORDER BY bm25(captures_fts, 4.0, 3.0, 1.0, 1.0, 2.0, 1.5) LIMIT ?
            """, [q, limit]) { s in if let c = decode(s, 0) { out.append(c) } }
        return out
    }

    // MARK: Files

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// PNG bytes scaled so the longest side is at most `maxPixel` (for AI tools and thumbnails).
    static func pngData(_ url: URL, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
