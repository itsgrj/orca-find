import Foundation

/// Developer hook: `OrcaFind --parse "pdfs from last week"` or `OrcaFind --search "screenshots with wifi"`.
/// Prints how the query was understood (and what it finds), then exits without showing UI.
enum DebugCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--parse"), i + 1 < args.count {
            for q in args[(i + 1)...] { printParse(q) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
            var queries = Array(args[(i + 1)...])
            var roots: [FileScanner.Root]
            if let r = queries.firstIndex(of: "--root"), r + 1 < queries.count {
                let url = URL(fileURLWithPath: queries[r + 1])
                roots = [FileScanner.Root(url: url, name: "Downloads", maxDepth: 8)]
                queries.removeSubrange(r...(r + 1))
            } else {
                roots = FileScanner.roots(extraFolders: UserDefaults.standard.stringArray(forKey: "extraFolders") ?? [], disabledDefaults: [])
            }
            let start = Date()
            var items = FileScanner.scan(roots: roots)
            print("Scanned \(items.count) files in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
            if let o = queries.firstIndex(of: "--ocr") {
                queries.remove(at: o)
                let t0 = Date()
                var n = 0
                for item in items where TextExtractor.wantsText(item, ocrEnabled: true) {
                    let body = TextExtractor.extract(item)
                    Database.shared.saveText(item.path, mtime: item.modifiedStamp, body: body)
                    n += 1
                }
                print("Extracted text from \(n) files in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            }
            let meta = Database.shared.loadMeta()
            let texts = Database.shared.loadTextState()
            if let v = queries.firstIndex(of: "--visual") {
                // Look at every picture / PDF cover now (normally done in the background by the app).
                queries.remove(at: v)
                let t0 = Date()
                let todo = items.filter(VisualAnalyzer.wants)
                let embed = MobileCLIP.isAvailable
                DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                    guard let seen = VisualAnalyzer.look(todo[i], labels: true, embed: embed) else { return }
                    if let info = seen.info { Database.shared.saveVisual(todo[i].path, mtime: todo[i].modifiedStamp, info) }
                    if embed { Database.shared.saveEmbedding(todo[i].path, mtime: todo[i].modifiedStamp, model: MobileCLIP.modelID, seen.vector) }
                }
                print("Looked at \(todo.count) pictures in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s (MobileCLIP \(embed ? "on" : "unavailable"))")
            }
            VisualStore.shared.replaceAll(Database.shared.loadVisual().mapValues(\.info))
            EmbeddingStore.shared.replaceAll(Database.shared.loadEmbeddings(model: MobileCLIP.modelID).compactMapValues(\.vector))
            print("Embeddings: \(EmbeddingStore.shared.count) pictures")
            let useAI = queries.contains("--ai"); queries.removeAll { $0 == "--ai" }
            for j in items.indices {
                if let m = meta[items[j].path], m.mtime == items[j].modifiedStamp { FileIndex.applyMeta(m, to: &items[j]) }
                if let t = texts[items[j].path] { items[j].hasText = t.hasText }
                if items[j].category == .images, items[j].camera == nil {
                    let m = MetadataReader.imageMeta(items[j].url)
                    items[j].camera = m.camera; items[j].pixelWidth = m.width; items[j].pixelHeight = m.height
                }
            }
            if args.contains("--dupes") {
                let groups = DuplicateFinder.identical(items) { _ in }
                print("Identical groups: \(groups.count) → " + groups.map { $0.items.map(\.name).joined(separator: " = ") }.joined(separator: " | "))
            }
            queries.removeAll { $0 == "--dupes" }
            for q in queries {
                var parsed = QueryParser.parse(q)
                if useAI {
                    let sem = DispatchSemaphore(value: 0)
                    var refined: SentenceRefinement?
                    let t1 = Date()
                    Task.detached { refined = await SentenceUnderstanding.refine(q); sem.signal() }
                    sem.wait()
                    if let refined { parsed = QueryParser.merge(parsed, refined, dismissed: []) }
                    print("  (Apple Intelligence: \(refined == nil ? "unavailable" : "\(Int(Date().timeIntervalSince(t1) * 1000)) ms"))")
                }
                print("“\(q)”")
                print("  chips: " + parsed.chips.map { "[\($0.kind.rawValue)\($0.isGuess ? "✦" : ""): \($0.label)]" }.joined(separator: " "))
                if !parsed.terms.isEmpty { print("  terms: \(parsed.terms)") }
                for l in parsed.looks { print("  looks: \(l.word) → \(l.labels)") }
                if let sc = parsed.scene { print("  scene: “\(sc)”") }
                let t0 = Date()
                let results = SearchEngine.run(parsed, in: items)
                print("  → \(results.count) results in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
                for r in results.prefix(8) {
                    print("    • \(r.name)  [\(r.category.rawValue), \(Fmt.size(r.size)), \(Fmt.relative(r.activityDate))\(r.source.map { ", from " + $0.name } ?? "")]\(SearchEngine.reason(for: r, parsed).map { "  " + $0 } ?? "")")
                }
            }
            exit(0)
        }
    }

    private static func printParse(_ q: String) {
        let p = QueryParser.parse(q)
        print("“\(q)”")
        print("  chips: " + p.chips.map { "[\($0.kind.rawValue): \($0.label)]" }.joined(separator: " "))
        if !p.terms.isEmpty { print("  terms: \(p.terms)") }
        for l in p.looks { print("  looks: \(l.word) → \(l.labels)") }
        if let sc = p.scene { print("  scene: “\(sc)”") }
        if !p.coverColours.isEmpty { print("  colours: \(p.coverColours)") }
    }
}
