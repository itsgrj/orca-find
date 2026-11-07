import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct CachedMeta {
    var mtime: Double
    var camera: String?
    var width: Int?
    var height: Int?
    var duration: Double?
    var bundleSize: Int64?
}

/// Small, thread-safe SQLite cache: enrichment metadata, extracted text (FTS5), hashes and feature prints.
final class Database: @unchecked Sendable {
    static let shared = Database()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrcaFind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        let path = Database.directory.appendingPathComponent("index.sqlite").path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            NSLog("OrcaFind: could not open database at \(path)")
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
        exec("""
        CREATE TABLE IF NOT EXISTS meta(path TEXT PRIMARY KEY, mtime REAL, camera TEXT, width INTEGER, height INTEGER, duration REAL, bundle_size INTEGER);
        CREATE TABLE IF NOT EXISTS hashes(path TEXT PRIMARY KEY, mtime REAL, size INTEGER, sha TEXT);
        CREATE TABLE IF NOT EXISTS prints(path TEXT PRIMARY KEY, mtime REAL, data BLOB);
        CREATE TABLE IF NOT EXISTS visual(path TEXT PRIMARY KEY, mtime REAL, labels TEXT, colours TEXT);
        CREATE TABLE IF NOT EXISTS embeddings(path TEXT PRIMARY KEY, mtime REAL, model TEXT, vec BLOB);
        CREATE TABLE IF NOT EXISTS texts(id INTEGER PRIMARY KEY, path TEXT UNIQUE, mtime REAL, body TEXT);
        CREATE VIRTUAL TABLE IF NOT EXISTS texts_fts USING fts5(body, content='texts', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS texts_ai AFTER INSERT ON texts BEGIN
          INSERT INTO texts_fts(rowid, body) VALUES (new.id, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS texts_ad AFTER DELETE ON texts BEGIN
          INSERT INTO texts_fts(texts_fts, rowid, body) VALUES('delete', old.id, old.body);
        END;
        CREATE TRIGGER IF NOT EXISTS texts_au AFTER UPDATE ON texts BEGIN
          INSERT INTO texts_fts(texts_fts, rowid, body) VALUES('delete', old.id, old.body);
          INSERT INTO texts_fts(rowid, body) VALUES (new.id, new.body);
        END;
        """)
    }

    // MARK: - Low level

    @discardableResult
    func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK, let err {
            NSLog("OrcaFind SQL error: \(String(cString: err))")
            sqlite3_free(err)
        }
        return rc == SQLITE_OK
    }

    private func bind(_ s: OpaquePointer, _ i: Int32, _ value: Any?) {
        guard let value else { sqlite3_bind_null(s, i); return }
        switch value {
        case let x as Int: sqlite3_bind_int64(s, i, Int64(x))
        case let x as Int64: sqlite3_bind_int64(s, i, x)
        case let x as Double: sqlite3_bind_double(s, i, x)
        case let x as String: sqlite3_bind_text(s, i, x, -1, SQLITE_TRANSIENT)
        case let x as Data:
            _ = x.withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32(x.count), SQLITE_TRANSIENT) }
        default: sqlite3_bind_null(s, i)
        }
    }

    private func statement(_ sql: String, _ args: [Any?], _ body: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            if let db { NSLog("OrcaFind SQL prepare error: \(String(cString: sqlite3_errmsg(db)))") }
            return
        }
        defer { sqlite3_finalize(s) }
        for (i, a) in args.enumerated() { bind(s, Int32(i + 1), a) }
        body(s)
    }

    private func run(_ sql: String, _ args: [Any?] = []) {
        statement(sql, args) { s in _ = sqlite3_step(s) }
    }

    private func rows(_ sql: String, _ args: [Any?] = [], _ each: (OpaquePointer) -> Void) {
        statement(sql, args) { s in
            while sqlite3_step(s) == SQLITE_ROW { each(s) }
        }
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
    private func int(_ s: OpaquePointer, _ i: Int32) -> Int64? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_int64(s, i)
    }
    private func double(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }
    private func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }

    func transaction(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        body()
        exec("COMMIT")
    }

    // MARK: - Metadata

    func loadMeta() -> [String: CachedMeta] {
        var out: [String: CachedMeta] = [:]
        rows("SELECT path, mtime, camera, width, height, duration, bundle_size FROM meta") { s in
            guard let p = text(s, 0) else { return }
            out[p] = CachedMeta(mtime: double(s, 1) ?? 0, camera: text(s, 2),
                                width: int(s, 3).map(Int.init), height: int(s, 4).map(Int.init),
                                duration: double(s, 5), bundleSize: int(s, 6))
        }
        return out
    }

    func saveMeta(_ path: String, _ m: CachedMeta) {
        run("INSERT OR REPLACE INTO meta(path, mtime, camera, width, height, duration, bundle_size) VALUES(?,?,?,?,?,?,?)",
            [path, m.mtime, m.camera, m.width, m.height, m.duration, m.bundleSize])
    }

    // MARK: - Visual (image labels + colours)

    func loadVisual() -> [String: (mtime: Double, info: VisualInfo)] {
        var out: [String: (Double, VisualInfo)] = [:]
        rows("SELECT path, mtime, labels, colours FROM visual") { s in
            guard let p = text(s, 0) else { return }
            out[p] = (double(s, 1) ?? 0, VisualInfo(labels: VisualInfo.decode(text(s, 2)), colours: VisualInfo.decode(text(s, 3))))
        }
        return out
    }

    func saveVisual(_ path: String, mtime: Double, _ v: VisualInfo) {
        run("INSERT OR REPLACE INTO visual(path, mtime, labels, colours) VALUES(?,?,?,?)",
            [path, mtime, VisualInfo.encode(v.labels), VisualInfo.encode(v.colours)])
    }

    func resetVisual() { exec("DELETE FROM visual; DELETE FROM embeddings;") }

    // MARK: - Image embeddings (MobileCLIP)

    /// Rows for the current model only; a vector from another model would be meaningless.
    func loadEmbeddings(model: String) -> [String: (mtime: Double, vector: [Float]?)] {
        var out: [String: (Double, [Float]?)] = [:]
        rows("SELECT path, mtime, vec FROM embeddings WHERE model = ?", [model]) { s in
            guard let p = text(s, 0) else { return }
            out[p] = (double(s, 1) ?? 0, blob(s, 2).flatMap(MobileCLIP.decode))
        }
        return out
    }

    /// `vector == nil` records "looked, nothing to embed" so the file isn't retried every launch.
    func saveEmbedding(_ path: String, mtime: Double, model: String, _ vector: [Float]?) {
        run("INSERT OR REPLACE INTO embeddings(path, mtime, model, vec) VALUES(?,?,?,?)",
            [path, mtime, model, vector.map(MobileCLIP.encode)])
    }

    // MARK: - Text

    /// path -> (mtime the text was extracted at, whether any meaningful text was found)
    func loadTextState() -> [String: (mtime: Double, hasText: Bool)] {
        var out: [String: (Double, Bool)] = [:]
        rows("SELECT path, mtime, length(body) FROM texts") { s in
            guard let p = text(s, 0) else { return }
            out[p] = (double(s, 1) ?? 0, (int(s, 2) ?? 0) > 2)
        }
        return out
    }

    func saveText(_ path: String, mtime: Double, body: String) {
        let trimmed = String(body.prefix(120_000))
        run("INSERT INTO texts(path, mtime, body) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, body=excluded.body",
            [path, mtime, trimmed])
    }

    func text(for path: String) -> String? {
        var out: String?
        rows("SELECT body FROM texts WHERE path = ?", [path]) { s in out = text(s, 0) }
        return out
    }

    static func ftsQuery(_ term: String) -> String? {
        let words = term.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        if words.count == 1 { return "\"\(words[0])\"*" }
        return "\"" + words.joined(separator: " ") + "\""
    }

    /// Paths whose extracted text contains the term (prefix match for single words, phrase match otherwise).
    func paths(matching term: String) -> Set<String> {
        guard let q = Database.ftsQuery(term) else { return [] }
        var out = Set<String>()
        rows("SELECT texts.path FROM texts_fts JOIN texts ON texts.id = texts_fts.rowid WHERE texts_fts MATCH ?", [q]) { s in
            if let p = text(s, 0) { out.insert(p) }
        }
        return out
    }

    // MARK: - Hashes & feature prints

    func hash(for path: String, mtime: Double, size: Int64) -> String? {
        var out: String?
        rows("SELECT sha FROM hashes WHERE path = ? AND mtime = ? AND size = ?", [path, mtime, size]) { s in out = text(s, 0) }
        return out
    }

    func saveHash(_ path: String, mtime: Double, size: Int64, sha: String) {
        run("INSERT OR REPLACE INTO hashes(path, mtime, size, sha) VALUES(?,?,?,?)", [path, mtime, size, sha])
    }

    func featurePrint(for path: String, mtime: Double) -> Data? {
        var out: Data?
        rows("SELECT data FROM prints WHERE path = ? AND mtime = ?", [path, mtime]) { s in out = blob(s, 0) }
        return out
    }

    func saveFeaturePrint(_ path: String, mtime: Double, data: Data) {
        run("INSERT OR REPLACE INTO prints(path, mtime, data) VALUES(?,?,?)", [path, mtime, data])
    }

    // MARK: - Maintenance

    func remove(paths: [String]) {
        guard !paths.isEmpty else { return }
        transaction {
            for p in paths {
                run("DELETE FROM meta WHERE path = ?", [p])
                run("DELETE FROM texts WHERE path = ?", [p])
                run("DELETE FROM hashes WHERE path = ?", [p])
                run("DELETE FROM prints WHERE path = ?", [p])
                run("DELETE FROM visual WHERE path = ?", [p])
                run("DELETE FROM embeddings WHERE path = ?", [p])
            }
        }
    }

    func resetText() {
        exec("DELETE FROM texts;")
    }

    func resetAll() {
        exec("DELETE FROM meta; DELETE FROM texts; DELETE FROM hashes; DELETE FROM prints;")
    }

    var fileSize: Int64 {
        let url = Database.directory.appendingPathComponent("index.sqlite")
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}
