import Foundation
import CoreGraphics
import AppKit

/// Developer hook: `OrcaFind --parse "pdfs from last week"` or `OrcaFind --search "screenshots with wifi"`.
/// Prints how the query was understood (and what it finds), then exits without showing UI.
enum DebugCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            // Transcribe a saved capture recording end to end: `OrcaFind --transcribe <file.m4a>`
            let url = URL(fileURLWithPath: args[i + 1])
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                guard await VoiceSearch.requestSpeechPermission() else { print("speech recognition not allowed"); sem.signal(); return }
                let locale = UserDefaults.standard.string(forKey: "voiceLocale") ?? Locale.current.identifier
                for onDevice in [true, false] {
                    CaptureRecorder.lastFileError = nil
                    print("onDevice=\(onDevice):", await CaptureRecorder.transcribeFile(url, locale: locale, onDevice: onDevice) ?? "(nothing)")
                    if let e = CaptureRecorder.lastFileError { print("  error: \(e)") }
                }
                print("locale: \(locale)")
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if args.contains("--joiner-selftest") {
            // On-device recognition restarting after pauses: every segment must survive.
            var j = SegmentJoiner()
            let partials = ["I", "I want", "I want this as a", "I want this as a reference for the", "I want this as a reference for the onboarding",
                            "Mostly", "Mostly the colours", "Mostly the colours and the spacing", "Curiosity"]
            var out = ""
            for p in partials { out = j.absorb(p) }
            out = j.commit()
            print(out)
            print(out == "I want this as a reference for the onboarding Mostly the colours and the spacing Curiosity" ? "PASS" : "FAIL")
            var k = SegmentJoiner()
            for p in ["Pricing thread", "Pricing thread for", "pricing thread for Friday's", "Pricing thread for Friday’s newsletter."] { out = k.absorb(p) }
            print(out == "Pricing thread for Friday’s newsletter." ? "PASS revisions" : "FAIL revisions: \(out)")
            exit(0)
        }
        if args.contains("--capture-selftest") {
            // Saves a throwaway capture, searches it like Claude would, then deletes it.
            var c = Capture(id: "selftest-" + UUID().uuidString, created: Date())
            c.note = "Pricing thread for Friday's newsletter. The forty percent bit is the hook."
            c.title = "Priya Shah on X"; c.pageURL = "https://x.com/priyabuilds/status/1855012"
            c.ocr = "We raised prices 40% last spring and lost almost no one"; c.collection = "Newsletter"
            let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            _ = CaptureStore.writePNG(ctx.makeImage()!, to: c.imageURL)
            CaptureStore.shared.save(c)
            for q in ["that pricing thread I saved for the newsletter", "forty percent", "lost almost", "x.com", "nothing like this"] {
                print("search “\(q)” →", CaptureStore.shared.search(q, matchAll: false).filter { $0.id == c.id }.count)
            }
            let r = MCPServer.getCapture(["id": c.id])
            print("get_capture blocks:", (r["content"] as? [[String: Any]])?.map { $0["type"] as? String ?? "?" } ?? [])
            print("collections:", CaptureStore.shared.collections().map { "\($0.name) \($0.count)" })
            CaptureStore.shared.delete(id: c.id)
            print("after delete:", CaptureStore.shared.get(c.id) == nil ? "gone" : "STILL THERE",
                  FileManager.default.fileExists(atPath: c.imageURL.path) ? "png left" : "png removed")
            exit(0)
        }
        if args.contains("--links-selftest") {
            // Feed links → the item they point at; YouTube moments.
            var ok = true
            func check(_ name: String, _ got: Any?, _ want: Any?) {
                let pass = "\(got ?? "nil")" == "\(want ?? "nil")"
                ok = ok && pass
                print(pass ? "PASS" : "FAIL", name, pass ? "" : "→ got \(got ?? "nil"), want \(want ?? "nil")")
            }
            check("pin", SourceLinks.item("https://www.pinterest.com/pin/123456789/")?.key, "pin:123456789")
            check("pin regional", SourceLinks.item("https://in.pinterest.com/pin/42/")?.kind, "pin")
            check("pinterest feed", SourceLinks.item("https://www.pinterest.com/search/pins/?q=chairs")?.kind, nil)
            check("x status", SourceLinks.item("https://x.com/priya/status/1855012/analytics")?.key, "x:1855012")
            check("x profile", SourceLinks.item("https://x.com/priya"), nil)
            check("yt watch", SourceLinks.item("https://www.youtube.com/watch?v=abc123&list=PL1")?.key, "yt:abc123")
            check("yt short", SourceLinks.item("https://youtube.com/shorts/xyz")?.key, "yt:xyz")
            check("yt home", SourceLinks.item("https://www.youtube.com/"), nil)
            check("ig reel", SourceLinks.item("https://www.instagram.com/reel/C1/")?.kind, "reel")
            check("reddit", SourceLinks.item("https://www.reddit.com/r/design/comments/abc/title/")?.key, "rd:abc")
            check("amazon", SourceLinks.item("https://www.amazon.in/Some-Thing/dp/B0ABC/ref=x")?.key, "az:B0ABC")
            check("same item", SourceLinks.same("https://www.youtube.com/watch?v=a&t=3s", "https://youtu.be/a"), true)
            check("same page", SourceLinks.same("https://ex.com/a/", "https://www.ex.com/a#top"), true)
            check("different", SourceLinks.same("https://ex.com/a", "https://ex.com/b"), false)
            check("moment", SourceLinks.atMoment("https://www.youtube.com/watch?v=abc&t=10s", seconds: 134.7), "https://www.youtube.com/watch?v=abc&t=134s")
            check("moment youtu.be", SourceLinks.atMoment("https://youtu.be/abc?si=x", seconds: 75), "https://youtu.be/abc?si=x&t=75s")
            check("no moment on shorts", SourceLinks.supportsMoment("https://www.youtube.com/shorts/xyz"), false)
            check("moment at 0", SourceLinks.atMoment("https://www.youtube.com/watch?v=abc", seconds: 0.4), "https://www.youtube.com/watch?v=abc")
            check("clock", SourceLinks.clock(3723), "1:02:03")
            check("parse", SourceLinks.parseClock("2:14 of 10:31"), 134.0)
            check("parse hours", SourceLinks.parseClock("1:02:03 of 2:00:00"), 3723.0)
            check("parse junk", SourceLinks.parseClock("Seek slider"), nil)
            var c = Capture(id: "x", created: Date())
            c.pageURL = "https://www.pinterest.com/"; c.itemURL = "https://www.pinterest.com/pin/9/"; c.pastedLinks = ["https://docs.example.com"]
            check("labels", c.linkItems.map(\.label), ["the pin you grabbed", "page you were on", "you pasted while talking"])
            c = Capture(id: "y", created: Date())
            c.pageURL = "https://www.youtube.com/watch?v=abc"; c.videoSeconds = 872
            check("moment label", c.linkItems.map(\.label), ["page it came from · at 14:32"])
            check("open link", c.links.first, "https://www.youtube.com/watch?v=abc&t=872s")
            print(ok ? "ALL PASS" : "SOME FAILED")
            exit(ok ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--page-probe"), i + 1 < args.count {
            // `OrcaFind --page-probe com.google.Chrome [x y w h]` → what Orca would keep for a box over that browser's page
            // (default: the middle of the page). Needs Accessibility for the process running it.
            print("Accessibility allowed:", PageInspector.isAllowed)
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 1]).first else { print("not running"); exit(1) }
            PageInspector.wake(pid: app.processIdentifier)
            Thread.sleep(forTimeInterval: 1)
            guard let page = PageInspector.pageFrame(pid: app.processIdentifier) else { print("no page found"); exit(1) }
            var box = page.insetBy(dx: page.width * 0.3, dy: page.height * 0.3)
            let nums = args.dropFirst(i + 2).prefix(4).compactMap { Double($0) }
            if nums.count == 4 { box = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]) }
            let t0 = Date()
            let f = PageInspector.inspect(pid: app.processIdentifier, box: box)
            print("app:", app.localizedName ?? "?", " page frame:", page, " box:", box)
            print("page:", f.pageURL ?? "nil")
            print("item:", f.itemURL ?? "nil")
            print("video:", f.videoSeconds.map { SourceLinks.clock($0) } ?? "nil")
            print(String(format: "took %.0f ms", Date().timeIntervalSince(t0) * 1000))
            exit(0)
        }
        if args.contains("--clip-selftest") {
            // Motion detector: still page, one hover change, then an animation.
            func page(_ v: UInt8, changed: Int = 0) -> [UInt8] {
                var a = [UInt8](repeating: 200, count: MotionDetector.grid * MotionDetector.grid)
                for k in 0..<changed { a[(k * 37) % a.count] = v }
                return a
            }
            var still = MotionDetector()
            for _ in 0..<20 { still.feed(samples: page(200)) }
            var hover = MotionDetector()
            for k in 0..<20 { hover.feed(samples: k < 8 ? page(200) : page(120, changed: 30)) }
            var caret = MotionDetector()
            for k in 0..<20 { caret.feed(samples: page(k % 2 == 0 ? 200 : 20, changed: 2)) }
            var anim = MotionDetector()
            for k in 0..<20 { anim.feed(samples: page(k % 2 == 0 ? 40 : 220, changed: 60)) }
            print("still page  changes=\(still.changes) moving=\(still.changes >= ClipRecorder.movingAfter)  (want false)")
            print("one hover   changes=\(hover.changes) moving=\(hover.changes >= ClipRecorder.movingAfter)  (want false)")
            print("caret blink changes=\(caret.changes) moving=\(caret.changes >= ClipRecorder.movingAfter)  (want false)")
            print("animation   changes=\(anim.changes) moving=\(anim.changes >= ClipRecorder.movingAfter)  (want true)")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("orca-clip-selftest.mov")
            let ok = Snapshot.makeSampleClip(url, size: CGSize(width: 600, height: 420), draw: { c, s in
                c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(origin: .zero, size: s))
            }, barsChart: true)
            let frames = ClipFrames.framesSync(url)
            print("sample clip written: \(ok)  key frames: \(frames.map { String(format: "%.2f", $0.time) }.joined(separator: ", "))  sizes: \(frames.map { "\($0.image.width)x\($0.image.height)" })")
            for t in ["Tag it design and pricing.", "hashtag motion", "The price tag is high", "#onboarding flow here", "tagged as to read", "label this inspiration please"] {
                print("“\(t)” → \(CaptureTags.spoken(in: t).map { "#" + $0.tag })")
            }
            print("normalize: \(["#Landing Page!", "Designs", "it", "how-to", "  Gift idea "].map { CaptureTags.normalize($0) ?? "nil" })")
            print("same(design, Designs)=\(CaptureTags.same("design", "Designs"))  same(landing page, landing-page)=\(CaptureTags.same("landing page", "landing-page"))")
            print("parse AI: \(CaptureTags.parseSuggestion("```json\n{\"tags\": [\"Designs\", \"SigmaFlow\", \"color palette inspiration\"]}\n```", collection: "SigmaFlow", existing: ["design"]))")
            exit(0)
        }
        if let i = args.firstIndex(of: "--intent"), i + 1 < args.count {
            // How a spoken capture note gets filed: `OrcaFind --intent "for the newsletter. remind me thursday"`
            let existing = CaptureStore.shared.collections().map(\.name)
            let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
            for t in args[(i + 1)...] {
                let r = SpokenIntent.parse(t, existing: existing)
                print("“\(t)”")
                print("  collection: \(r.collection ?? "-")  (from \(r.collectionPhrase ?? "-"))")
                print("  reminder:   \(r.reminderDate.map(f.string) ?? "-")  (from \(r.reminderPhrase ?? "-"))  task: \(r.reminderTask ?? "-")")
                print("  tags:       \(r.tags.isEmpty ? "-" : r.tags.map { "#" + $0 + " (from \(r.tagPhrases[$0] ?? "?"))" }.joined(separator: ", "))")
            }
            exit(0)
        }
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
