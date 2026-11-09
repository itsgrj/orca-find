import AppKit
import PDFKit
import Quartz
import CoreImage
import UniformTypeIdentifiers

/// How hard Compress squeezes. Smaller keeps every page as it is and shrinks the pictures inside;
/// Smallest also turns scanned pages (pages with no text) into lighter pictures.
enum PDFSqueeze: String, CaseIterable, Sendable {
    case smaller = "Smaller", smallest = "Smallest"
}

/// What happens to the password when a copy is written.
enum PDFPasswordPlan: Sendable {
    /// Leave it as the file had it (re-applied with the password it was opened with, if any).
    case keep(String?)
    case set(String)
    case remove
}

struct PDFSavePlan: Sendable {
    var squeeze: PDFSqueeze?
    var grayscale = false
    var password: PDFPasswordPlan = .keep(nil)
    /// Password that opens the in-memory copy (encrypted files stay encrypted in memory).
    var unlock: String?
}

/// The PDF work that doesn't need the screen. Every function works on the document it is given,
/// so background work opens its own copy from `Data` (a PDFDocument must stay on one thread).
enum PDFEngine {

    // MARK: Opening

    static func open(_ data: Data, password: String?) -> PDFDocument? {
        guard let d = PDFDocument(data: data) else { return nil }
        if d.isLocked, let password { _ = d.unlock(withPassword: password) }
        return d.isLocked ? nil : d
    }

    /// A new, unencrypted document holding copies of the given pages.
    static func subset(_ doc: PDFDocument, _ indices: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for i in indices {
            if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
        }
        return out
    }

    /// Copies every page of `src` into `doc`, starting at `index`. Returns how many went in.
    @discardableResult
    static func insert(_ src: PDFDocument, into doc: PDFDocument, at index: Int) -> Int {
        var at = min(max(0, index), doc.pageCount)
        var n = 0
        for i in 0..<src.pageCount {
            guard let p = src.page(at: i)?.copy() as? PDFPage else { continue }
            doc.insert(p, at: at); at += 1; n += 1
        }
        return n
    }

    /// An empty page the same size as `like` (Letter if there's nothing to copy).
    static func blankPage(like page: PDFPage?) -> PDFPage {
        let p = PDFPage()
        let box = page?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        p.setBounds(CGRect(origin: .zero, size: box.size), for: .mediaBox)
        if let page { p.rotation = page.rotation }
        return p
    }

    /// A page made from a photo, fitted to `pageSize` turned to match the photo.
    static func imagePage(_ image: NSImage, pageSize: CGSize?) -> PDFPage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        var opts: [PDFPage.ImageInitializationOption: Any] = [.compressionQuality: 0.85]
        if let s = pageSize {
            let landscape = image.size.width > image.size.height
            let w = landscape ? max(s.width, s.height) : min(s.width, s.height)
            let h = landscape ? min(s.width, s.height) : max(s.width, s.height)
            opts[.mediaBox] = NSValue(rect: CGRect(x: 0, y: 0, width: w, height: h))
            opts[.upscaleIfSmaller] = true
        }
        return PDFPage(image: image, options: opts)
    }

    // MARK: Text

    /// True when a page has no text you could select (usually a scan).
    static func isImageOnly(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One highlight per line of the selection. Returns how many marks were added.
    @discardableResult
    static func highlight(_ selection: PDFSelection, color: NSColor) -> Int {
        var n = 0
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                let a = PDFAnnotation(bounds: r, forType: .highlight, withProperties: nil)
                a.color = color
                a.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: r.height)), NSValue(point: CGPoint(x: r.width, y: r.height)),
                                         NSValue(point: .zero), NSValue(point: CGPoint(x: r.width, y: 0))]
                page.addAnnotation(a)
                n += 1
            }
        }
        return n
    }

    /// Turns a direction seen on screen (x right, y up) into page space for a page turned `rotation` degrees.
    static func pageVector(_ v: CGPoint, rotation: Int) -> CGPoint {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGPoint(x: -v.y, y: v.x)
        case 180: return CGPoint(x: -v.x, y: -v.y)
        case 270: return CGPoint(x: v.y, y: -v.x)
        default: return v
        }
    }

    /// A text box with `text`, its top-left corner (as seen on screen) at `anchor` (page space).
    static func textBox(_ text: String, anchor: CGPoint, size: CGFloat, rotation: Int, color: NSColor = .black) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: .zero, forType: .freeText, withProperties: nil)
        a.font = NSFont.systemFont(ofSize: size)
        a.fontColor = color
        a.color = .clear
        let b = PDFBorder(); b.lineWidth = 0; a.border = b
        a.contents = text
        a.bounds = textBoxBounds(text, anchor: anchor, size: size, rotation: rotation)
        return a
    }

    /// PDFKit draws a text box upright on a turned page, so its box is turned with the page.
    static func textBoxBounds(_ text: String, anchor: CGPoint, size: CGFloat, rotation: Int) -> CGRect {
        let shown = text.isEmpty ? " " : text
        let s = (shown as NSString).boundingRect(with: CGSize(width: 420, height: 10_000), options: [.usesLineFragmentOrigin],
                                                 attributes: [.font: NSFont.systemFont(ofSize: size)])
        let w = max(40, ceil(s.width) + 14), h = ceil(s.height) + 8
        let a = anchor
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGRect(x: a.x, y: a.y, width: h, height: w)
        case 180: return CGRect(x: a.x - w, y: a.y, width: w, height: h)
        case 270: return CGRect(x: a.x - h, y: a.y - w, width: h, height: w)
        default: return CGRect(x: a.x, y: a.y - h, width: w, height: h)
        }
    }

    /// The on-screen top-left corner of an existing text box.
    static func textBoxAnchor(_ r: CGRect, rotation: Int) -> CGPoint {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return CGPoint(x: r.minX, y: r.minY)
        case 180: return CGPoint(x: r.maxX, y: r.minY)
        case 270: return CGPoint(x: r.maxX, y: r.maxY)
        default: return CGPoint(x: r.minX, y: r.maxY)
        }
    }

    /// Ink signature from strokes drawn on a pad (y grows downwards), centred on `center`, `width` wide
    /// as seen on screen, upright even on a turned page.
    static func signature(_ strokes: [[CGPoint]], center: CGPoint, width: CGFloat, rotation: Int = 0, color: NSColor = .black) -> PDFAnnotation? {
        let pts = strokes.flatMap { $0 }
        guard pts.count > 1 else { return nil }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let bw = max(maxX - minX, 1)
        let k = width / bw
        let line: CGFloat = max(1.2, width / 110)
        let pad = line * 2
        // Upright (y up) on screen, then turned into page space.
        let turned = strokes.filter { !$0.isEmpty }.map { s in
            s.map { p in pageVector(CGPoint(x: (p.x - minX) * k, y: (maxY - p.y) * k), rotation: rotation) }
        }
        let all = turned.flatMap { $0 }
        let lx = all.map(\.x).min()!, hx = all.map(\.x).max()!
        let ly = all.map(\.y).min()!, hy = all.map(\.y).max()!
        let w = max(hx - lx, 1), h = max(hy - ly, 1)
        let rect = CGRect(x: center.x - w / 2 - pad, y: center.y - h / 2 - pad, width: w + 2 * pad, height: h + 2 * pad)
        let a = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
        for s in turned {
            let path = NSBezierPath()
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.lineWidth = line
            func local(_ p: CGPoint) -> CGPoint { CGPoint(x: pad + p.x - lx, y: pad + p.y - ly) }
            path.move(to: local(s[0]))
            if s.count == 1 { path.line(to: local(s[0]).applying(.init(translationX: 0.5, y: 0))) }
            for p in s.dropFirst() { path.line(to: local(p)) }
            a.add(path)
        }
        a.color = color
        let b = PDFBorder(); b.lineWidth = line; a.border = b
        return a
    }

    // MARK: Rendering

    /// The page as it is seen (turned, cropped) at `dpi`.
    static func render(_ page: PDFPage, dpi: CGFloat, gray: Bool = false, maxPixels: CGFloat = 60_000_000) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        var size = turned ? CGSize(width: box.height, height: box.width) : box.size
        var scale = dpi / 72
        if size.width * size.height * scale * scale > maxPixels { scale = sqrt(maxPixels / (size.width * size.height)) }
        size = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let cs = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Where the ink is on a page, in page space, or nil for an empty page.
    static func contentBounds(_ page: PDFPage) -> CGRect? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let turn = page.rotation
        page.rotation = 0
        defer { page.rotation = turn }
        let s = 260 / max(box.width, box.height)
        let W = max(1, Int(box.width * s)), H = max(1, Int(box.height * s))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.scaleBy(x: s, y: s)
        page.draw(with: .cropBox, to: ctx)
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = W, minR = H, maxX = -1, maxR = -1
        for r in 0..<H {
            let row = r * W * 4
            for x in 0..<W {
                let o = row + x * 4
                if px[o] < 232 || px[o + 1] < 232 || px[o + 2] < 232 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if r < minR { minR = r }; if r > maxR { maxR = r }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run top-down; page space runs bottom-up.
        let x0 = box.minX + CGFloat(minX) / s, x1 = box.minX + CGFloat(maxX + 1) / s
        let y0 = box.minY + CGFloat(H - 1 - maxR) / s, y1 = box.minY + CGFloat(H - minR) / s
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// New crop boxes that trim the empty margins, keyed by page index. Pages that wouldn't change are left out.
    static func marginCrops(_ doc: PDFDocument, indices: [Int], margin: CGFloat = 14) -> [Int: CGRect] {
        var out: [Int: CGRect] = [:]
        for i in indices {
            guard let page = doc.page(at: i), let ink = contentBounds(page) else { continue }
            let box = page.bounds(for: .cropBox)
            let r = ink.insetBy(dx: -margin, dy: -margin).intersection(box)
            guard !r.isNull, r.width * r.height < box.width * box.height * 0.97 else { continue }
            out[i] = r.integral
        }
        return out
    }

    // MARK: Writing copies

    static func grayFilter() -> QuartzFilter? {
        // "Gray Tone" keeps coloured text and pictures as greys; "Black & White" turns light colours white.
        for name in ["Gray Tone", "Black & White"] {
            let url = URL(fileURLWithPath: "/System/Library/Filters/\(name).qfilter")
            if FileManager.default.fileExists(atPath: url.path), let f = QuartzFilter(url: url) { return f }
        }
        return nil
    }

    /// The Quartz filter only greys the page itself; marks on top (highlights, notes, ink) are turned grey here.
    static func grayAnnotations(_ doc: PDFDocument) {
        func gray(_ c: NSColor?) -> NSColor? {
            guard let c, let rgb = c.usingColorSpace(.sRGB) else { return c }
            let l = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            return NSColor(white: l, alpha: rgb.alphaComponent)
        }
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)?.annotations ?? [] {
                if let c = gray(a.color) { a.color = c }
                if a.type == "FreeText", let c = gray(a.fontColor) { a.fontColor = c }
                if a.type == "Widget", let c = gray(a.backgroundColor) { a.backgroundColor = c }
            }
        }
    }

    /// Swaps pages for pictures of themselves. `onlyScans` leaves pages with real text alone.
    static func rasterize(_ doc: PDFDocument, dpi: CGFloat, quality: CGFloat, gray: Bool, onlyScans: Bool) {
        for i in 0..<doc.pageCount {
            autoreleasepool {
                guard let page = doc.page(at: i), !onlyScans || isImageOnly(page) else { return }
                guard let cg = render(page, dpi: dpi, gray: gray) else { return }
                let box = page.bounds(for: .cropBox)
                let turned = page.rotation % 180 != 0
                let size = turned ? CGSize(width: box.height, height: box.width) : box.size
                let image = NSImage(cgImage: cg, size: size)
                // JPEG-encode first so the page keeps the small version.
                let rep = NSBitmapImageRep(cgImage: cg)
                let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]).flatMap(NSImage.init(data:)) ?? image
                jpeg.size = size
                guard let fresh = PDFPage(image: jpeg, options: [.mediaBox: NSValue(rect: CGRect(origin: .zero, size: size)),
                                                                .compressionQuality: quality]) else { return }
                doc.removePage(at: i)
                doc.insert(fresh, at: i)
            }
        }
    }

    /// Writes a copy of `data` with the plan's squeeze, colour and password.
    static func write(_ data: Data, plan: PDFSavePlan, to url: URL) throws {
        guard var doc = open(data, password: plan.unlock) else { throw EditError.message("Couldn’t read this PDF") }
        if case .remove = plan.password, doc.isEncrypted {
            // PDFKit keeps the lock on anything it opened locked, so the pages move to a fresh document.
            let attrs = doc.documentAttributes
            doc = subset(doc, Array(0..<doc.pageCount))
            doc.documentAttributes = attrs
        }
        var opts: [PDFDocumentWriteOption: Any] = [:]
        if let s = plan.squeeze {
            opts[.saveImagesAsJPEGOption] = true
            opts[.optimizeImagesForScreenOption] = true
            if s == .smallest { rasterize(doc, dpi: 110, quality: 0.5, gray: false, onlyScans: true) }
        }
        if plan.grayscale {
            grayAnnotations(doc)
            if let f = grayFilter() { opts[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = f }
            else { rasterize(doc, dpi: 150, quality: 0.75, gray: true, onlyScans: false) }
        }
        switch plan.password {
        case .set(let p), .keep(.some(let p)):
            opts[.userPasswordOption] = p
            opts[.ownerPasswordOption] = p
        default: break
        }
        guard doc.write(to: url, withOptions: opts) else { throw EditError.message("Couldn’t write the PDF") }
    }

    /// Size the plan would produce, written to a temporary file.
    static func estimate(_ data: Data, plan: PDFSavePlan) -> Int64? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orca-estimate-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? write(data, plan: plan, to: tmp)) != nil else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? nil
    }

    enum ImageKind: String, CaseIterable, Sendable { case png = "PNG", jpeg = "JPEG" }

    /// One picture per page into `folder`. `progress` is called with each page number as it's done.
    static func writeImages(_ doc: PDFDocument, to folder: URL, kind: ImageKind, dpi: CGFloat,
                            progress: (Int) -> Void = { _ in }) throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = max(2, String(doc.pageCount).count)
        var n = 0
        for i in 0..<doc.pageCount {
            try autoreleasepool {
                guard let page = doc.page(at: i), let cg = render(page, dpi: dpi) else { return }
                let name = "Page " + String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
                let url = folder.appendingPathComponent(name).appendingPathExtension(kind == .png ? "png" : "jpg")
                let type = (kind == .png ? UTType.png : UTType.jpeg).identifier as CFString
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { throw EditError.message("Couldn’t write \(name)") }
                let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85,
                                              kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw EditError.message("Couldn’t write \(name)") }
                n += 1
                progress(i + 1)
            }
        }
        return n
    }

    /// Splits pages into runs of `every` pages: [[0,1],[2,3],[4]].
    static func runs(pageCount: Int, every: Int) -> [[Int]] {
        let k = max(1, every)
        return stride(from: 0, to: pageCount, by: k).map { Array($0..<min($0 + k, pageCount)) }
    }

    /// "page 3" or "pages 2-5" (for file names).
    static func pagesLabel(_ indices: [Int]) -> String {
        let s = indices.sorted()
        guard let a = s.first, let b = s.last else { return "pages" }
        if s.count == 1 { return "page \(a + 1)" }
        if b - a + 1 == s.count { return "pages \(a + 1)-\(b + 1)" }
        return Fmt.plural(s.count, "page")
    }

    /// "Report pages" next to the original, never over an existing folder.
    @MainActor
    static func uniqueFolder(near original: URL, name: String) -> URL {
        let dir = CopySaver.folder(near: original)
        var url = dir.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1
        }
        return url
    }
}
