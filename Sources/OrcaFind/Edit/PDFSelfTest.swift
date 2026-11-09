import AppKit
import PDFKit

/// `OrcaFind --edit-selftest <file.pdf> <outdir>`: runs every PDF tool through the real workspace
/// on a copy of the file inside <outdir>, so every "next to the original" file lands there too.
@MainActor
enum PDFSelfTest {
    static func run(_ original: FileItem, out: URL) async -> Bool {
        var ok = true
        func check(_ cond: Bool, _ what: String) {
            print(cond ? "ok   \(what)" : "FAIL \(what)")
            if !cond { ok = false }
        }
        func size(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        func types(_ d: PDFDocument) -> [String: Int] {
            var t: [String: Int] = [:]
            for i in 0..<d.pageCount { for a in d.page(at: i)?.annotations ?? [] { t[a.type ?? "?", default: 0] += 1 } }
            return t
        }

        // Work on a copy so the test's files sit together.
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil) { old.forEach { try? fm.removeItem(at: $0) } }
        let src = out.appendingPathComponent("source.pdf")
        do { try fm.copyItem(at: original.url, to: src) } catch { print("FAIL copy: \(error.localizedDescription)"); return false }
        guard let item = FileScanner.makeItem(url: src, rootName: "Test") else { print("FAIL can’t read the copy"); return false }

        let ws = PDFWorkspace(item: item)
        guard ws.doc != nil else { print("FAIL open"); return false }
        if ws.locked { print("FAIL the PDF is locked; test needs an unlocked file"); return false }
        let n0 = ws.pageCount
        print("pages: \(n0) · text: \(ws.hasText ? "yes" : "no (scanned)") · \(Fmt.size(item.size))")
        check(ws.groups.flatMap(\.tools).count == 25, "25 tools in 4 groups")
        check(ws.isAvailable(.scanFromIPhone) && ws.isAvailable(.makeSearchable), "scan from iPhone & make searchable available")

        // Scan from iPhone: hand the workspace what Continuity Camera puts on the pasteboard.
        do {
            let w2 = PDFWorkspace(item: item)
            let before = w2.pageCount
            let pb = NSPasteboard(name: NSPasteboard.Name("orca-scan-selftest"))
            pb.clearContents()
            let one = PDFDocument()
            if let p = w2.pages.first?.copy() as? PDFPage { one.insert(p, at: 0) }
            pb.setData(one.dataRepresentation(), forType: .pdf)
            check(w2.receiveScan(pb) && w2.pageCount == before + 1 && w2.current == 1, "scan from iPhone: scanned page lands after page 1")
            pb.clearContents()
            let photo = NSImage(size: NSSize(width: 600, height: 800), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
            pb.writeObjects([photo])
            check(w2.receiveScan(pb) && w2.pageCount == before + 2, "scan from iPhone: a photo becomes a page")
            pb.releaseGlobally()
        }

        // Make searchable: picture-only pages get an invisible text layer.
        do {
            let w3 = PDFWorkspace(item: item)
            let missing = w3.textlessPages
            if missing.isEmpty {
                print("note make searchable: every page already has text")
            } else {
                let t0 = Date()
                w3.makeSearchable()
                var waited = 0
                while w3.busy != nil && waited < 1200 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
                let left = w3.textlessPages.count
                check(left < missing.count, String(format: "make searchable: %d picture pages → %d left (%.1fs)", missing.count, left, Date().timeIntervalSince(t0)))
                if let url = try? await w3.save(), let saved = PDFDocument(url: url), let pg = saved.page(at: missing[0]) {
                    let text = (pg.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    check(text.count > 20, "saved copy has text on page \(missing[0] + 1): “\(text.prefix(60).replacingOccurrences(of: "\n", with: " "))…”")
                    let word = text.split(separator: " ").first(where: { $0.count > 4 }).map(String.init) ?? ""
                    check(!word.isEmpty && !(saved.findString(word, withOptions: .caseInsensitive).isEmpty), "find “\(word)” in the saved copy")
                    check(pg.rotation == w3.pages[missing[0]].rotation, "page rotation kept")
                } else { check(false, "save searchable copy") }
            }
        }

        // Pages
        ws.rotate([0])
        check(ws.pages[0].rotation == 90, "rotate page 1")
        ws.undo()
        check(ws.pages[0].rotation == 0 && !ws.hasEdits, "undo rotate")
        ws.rotate([0])

        ws.delete(Array(0..<ws.pageCount))
        check(ws.pageCount == n0, "won’t delete every page")
        if n0 > 2 {
            ws.delete([n0 - 1])
            check(ws.pageCount == n0 - 1, "delete last page")
        }

        if n0 > 1 {
            let before = ws.pages
            var moved = before; moved.append(moved.removeFirst())
            ws.reorder(moved)
            check(ws.pages.first === before.dropFirst().first && ws.pages.last === before.first, "reorder (page 1 to the end)")
        }

        ws.go(to: 0)
        let c1 = ws.pageCount
        ws.insertBlank()
        check(ws.pageCount == c1 + 1 && PDFEngine.isImageOnly(ws.pages[1]) && ws.pages[1].bounds(for: .mediaBox).size == ws.pages[0].bounds(for: .mediaBox).size,
              "blank page after page 1, same size")

        let c2 = ws.pageCount
        ws.merge(urls: [src])
        check(ws.pageCount == c2 + n0, "merge with itself (+\(n0) pages)")
        ws.go(to: 0)
        ws.insert(urls: [src])
        check(ws.pageCount == c2 + 2 * n0, "insert pages after page 1")

        let cropped = ws.cropMarginsNow(Array(0..<ws.pageCount))
        let cb = ws.pages[0].bounds(for: .cropBox), mb = ws.pages[0].bounds(for: .mediaBox)
        check(cropped > 0 && cb.width < mb.width, "crop margins on \(cropped) pages (page 1: \(Int(mb.width))×\(Int(mb.height)) → \(Int(cb.width))×\(Int(cb.height)))")

        // Marks
        if ws.hasText, let doc = ws.doc {
            let word = ws.fullText.split(whereSeparator: { !$0.isLetter }).first { $0.count >= 4 }.map(String.init) ?? "the"
            if let sel = doc.findString(word, withOptions: .caseInsensitive).first {
                ws.highlight(sel)
                check((sel.pages.first?.annotations.contains { $0.type == "Highlight" }) == true, "highlight “\(word)”")
            } else { check(false, "find “\(word)”") }
            ws.query = word
            ws.runFind(word)
            check(ws.hitCount > 0 && ws.hits.first.map { $0.context.localizedCaseInsensitiveContains(word) } == true, "find “\(word)”: \(ws.hitCount) matches")
        } else {
            print("skip highlight & find (no text)")
        }

        ws.select(.textNote)
        ws.addNote(on: ws.pages[0], at: CGPoint(x: ws.pages[0].bounds(for: .cropBox).minX + 20, y: ws.pages[0].bounds(for: .cropBox).maxY - 30), text: "Checked by Orca")
        ws.noteText = "Checked by Orca ✓"
        ws.finishNote()
        check(ws.pages[0].annotations.contains { $0.type == "FreeText" && $0.contents == "Checked by Orca ✓" }, "text box")

        ws.select(.sign)
        ws.strokes = [[CGPoint(x: 0, y: 40), CGPoint(x: 15, y: 5), CGPoint(x: 30, y: 40), CGPoint(x: 45, y: 8), CGPoint(x: 60, y: 38)],
                      [CGPoint(x: 70, y: 30), CGPoint(x: 140, y: 26)]]
        ws.placeSignature()
        check(ws.pages[ws.current].annotations.contains { $0.type == "Ink" }, "signature on page \(ws.current + 1)")
        ws.select(.sign)

        let hadDetails = !ws.details.isEmpty
        ws.removeDetails()
        check(!hadDetails || ws.details.isEmpty, hadDetails ? "remove details" : "remove details (none saved)")

        ws.toggleGray()
        check(ws.grayscale, "black & white on")
        print("status: \(ws.status ?? "—")")

        do {
            let saved = try await ws.save()
            guard let back = PDFDocument(url: saved) else { check(false, "reopen \(saved.lastPathComponent)"); return false }
            let t = types(back)
            print("     annotations in copy: \(t.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            check(back.pageCount == ws.pageCount, "saved \(saved.lastPathComponent): \(back.pageCount) pages, \(Fmt.size(size(saved)))")
            check((back.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? "").isEmpty, "copy has no author")
            let hasWidgets = (0..<back.pageCount).contains { back.page(at: $0)?.annotations.contains { $0.type == "Widget" } == true }
            if hasWidgets { print("note form fields keep their own tint in black & white") }
            else if let p = back.page(at: 0), let cg = PDFEngine.render(p, dpi: 40) {
                check(maxColour(cg) < 16, "copy is black & white (max colour spread \(maxColour(cg)))")
            }
            check((0..<back.pageCount).contains { back.page(at: $0)?.rotation == 90 }, "rotation kept in the copy")
            check(back.page(at: 0)?.bounds(for: .cropBox).width ?? 0 < back.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, "crop kept in the copy")
        } catch { check(false, "save: \(error.localizedDescription)") }

        // Files made straight away (from the untouched file)
        let w2 = PDFWorkspace(item: item)
        w2.extract([0, min(1, n0 - 1)])
        let ex = out.appendingPathComponent(n0 > 1 ? "source (pages 1-2).pdf" : "source (page 1).pdf")
        check(PDFDocument(url: ex)?.pageCount == min(2, n0), "extract → \(ex.lastPathComponent)")

        if let folder = w2.split(every: 2) {
            let files = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".pdf") } ?? []
            check(files.count == (n0 + 1) / 2, "split every 2 pages → \(files.count) files in “\(folder.lastPathComponent)”")
        } else { check(n0 < 3, "split") }

        w2.saveText()
        let txt = out.appendingPathComponent("source.txt")
        if w2.hasText { check(((try? String(contentsOf: txt, encoding: .utf8)) ?? "").count > 20, "save as text → \(Fmt.size(size(txt)))") }
        else { print("skip save as text (no text)") }

        w2.imageKind = .jpeg; w2.imageDPI = 72
        w2.saveImages()
        var waited = 0
        while w2.busy != nil && waited < 600 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        let imgs = (try? fm.contentsOfDirectory(atPath: out.appendingPathComponent("source pages").path)) ?? []
        check(imgs.count == n0, "save as images → \(imgs.count) JPEGs (\(imgs.sorted().first ?? "—"))")

        // Compress
        for s in PDFSqueeze.allCases {
            let w = PDFWorkspace(item: item)
            w.squeeze = s
            do {
                let url = try await w.save()
                let renamed = out.appendingPathComponent("compressed-\(s.rawValue.lowercased()).pdf")
                try? fm.removeItem(at: renamed); try fm.moveItem(at: url, to: renamed)
                let est = PDFEngine.estimate(try Data(contentsOf: src), plan: PDFSavePlan(squeeze: s))
                check(PDFDocument(url: renamed)?.pageCount == n0, "compress \(s.rawValue): \(Fmt.size(item.size)) → \(Fmt.size(size(renamed))) (estimate \(est.map { Fmt.size($0) } ?? "—"))")
            } catch { check(false, "compress \(s.rawValue): \(error.localizedDescription)") }
        }

        // Password: lock, reopen, unlock, edit, keep, remove
        let w3 = PDFWorkspace(item: item)
        w3.select(.password)
        w3.newPassword = "orca"; w3.confirmPassword = "orca"
        check(w3.hasEdits, "password set → Save copy shows")
        do {
            let lockedURL = try await w3.save()
            let l = PDFDocument(url: lockedURL)
            check(l?.isLocked == true && l?.isEncrypted == true, "copy is locked")
            check(l?.unlock(withPassword: "nope") == false && l?.unlock(withPassword: "orca") == true, "wrong password refused, right one opens it")
            if let li = FileScanner.makeItem(url: lockedURL, rootName: "Test") {
                let w4 = PDFWorkspace(item: li)
                check(w4.locked, "workspace opens it locked")
                w4.select(.rotatePages)
                check(w4.active == .password && !w4.hasEdits, "tools wait for the password")
                w4.unlockText = "wrong"; w4.unlock()
                check(w4.locked && w4.unlockFailed, "wrong password says so")
                w4.unlockText = "orca"; w4.unlock()
                check(!w4.locked && w4.pageCount == n0, "unlocked in the workspace")
                w4.rotate([0])
                w4.undo(); w4.rotate([0])
                let kept = try await w4.save()
                let k = PDFDocument(url: kept)
                check(k?.isLocked == true && k?.unlock(withPassword: "orca") == true && k?.page(at: 0)?.rotation == 90, "edited copy keeps the password")
                w4.select(.password)
                w4.removePassword = true
                let open = try await w4.save()
                let o = PDFDocument(url: open)
                check(o?.isLocked == false && o?.isEncrypted == false && o?.pageCount == n0, "remove password → opens freely")
            }
        } catch { check(false, "password: \(error.localizedDescription)") }

        // Forms
        let w5 = PDFWorkspace(item: item)
        print("form fields: \(w5.formFields)")
        if w5.formFields > 0, let field = w5.pages.flatMap({ $0.annotations }).first(where: { $0.type == "Widget" && $0.widgetFieldType == .text }) {
            w5.mouseDownInPDF()
            field.widgetStringValue = "Orca"
            w5.formsMaybeChanged()
            check(w5.hasEdits, "typing in a form field counts as an edit")
            if let url = try? await w5.save(), let f = PDFDocument(url: url) {
                let v = f.page(at: 0)?.annotations.first { $0.type == "Widget" && $0.widgetFieldType == .text }?.widgetStringValue
                check(v == "Orca", "form value saved (\(v ?? "nil"))")
            }
        }

        let made = (try? fm.contentsOfDirectory(atPath: out.path))?.sorted() ?? []
        print("files: \(made.joined(separator: " | "))")
        return ok
    }

    /// Largest difference between colour channels anywhere in the picture (0 = pure greys).
    private static func maxColour(_ cg: CGImage) -> Int {
        let W = cg.width, H = cg.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let _ = Optional(ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))),
              let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 255 }
        var m = 0
        for i in 0..<(W * H) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            m = max(m, abs(r - g), abs(g - b), abs(r - b))
        }
        return m
    }
}
