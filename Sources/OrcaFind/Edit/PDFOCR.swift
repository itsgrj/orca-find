import AppKit
import PDFKit
import Vision
import CoreText
import SwiftUI

/// Make searchable: Vision reads pages that are only pictures of text, and each such page is
/// rebuilt with the original drawing plus an invisible text layer, so it can be searched,
/// selected and copied while looking exactly the same. Apple frameworks only.
enum PDFOCR {
    /// A page counts as "picture only" when it has next to no real text.
    static func needsText(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 8
    }

    struct Word { let text: String; let box: CGRect }   // box: 0…1, bottom-left origin, as the page is shown

    /// Reads the given pages and returns a one-page PDF (as data) for each page that had text.
    /// Runs on its own copy of the document, off the main thread.
    static func searchablePages(data: Data, password: String?, indices: [Int],
                                progress: @escaping @Sendable (Int) -> Void) async -> [Int: Data] {
        await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(data: data) else { return [:] }
            if doc.isLocked, let p = password { _ = doc.unlock(withPassword: p) }
            var out: [Int: Data] = [:]
            for (n, i) in indices.enumerated() {
                if Task.isCancelled { break }
                progress(n)
                guard let page = doc.page(at: i), let ref = page.pageRef else { continue }
                let crop = page.bounds(for: .cropBox)
                let r = ((page.rotation % 360) + 360) % 360
                let shown = r % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
                guard shown.width > 0, shown.height > 0 else { continue }
                let scale = 2600 / max(shown.width, shown.height)
                let thumb = page.thumbnail(of: CGSize(width: shown.width * scale, height: shown.height * scale), for: .cropBox)
                guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let words = read(cg)
                guard !words.isEmpty, let built = build(ref: ref, crop: crop, rotation: r, shown: shown, words: words) else { continue }
                out[i] = built
            }
            return out
        }.value
    }

    /// Word boxes from Vision (falls back to whole lines when a word box isn't available).
    static func read(_ cg: CGImage) -> [Word] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { req.automaticallyDetectsLanguage = true }
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        var words: [Word] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            var placed = false
            for token in s.split(separator: " ") {
                let range = token.startIndex..<token.endIndex
                if let b = try? cand.boundingBox(for: range)?.boundingBox, b.width > 0, b.height > 0 {
                    words.append(Word(text: String(token), box: b)); placed = true
                }
            }
            if !placed { words.append(Word(text: s, box: obs.boundingBox)) }
        }
        return words
    }

    /// The original page content plus invisible words, as a one-page PDF. The page keeps its
    /// unrotated size so annotations can move across unchanged; the caller sets the rotation back.
    static func build(ref: CGPDFPage, crop: CGRect, rotation r: Int, shown: CGSize, words: [Word]) -> Data? {
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: crop.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        ctx.drawPDFPage(ref)
        ctx.restoreGState()

        // Words are measured on the page as shown; map them back onto the unrotated page.
        let W = crop.width, H = crop.height
        let shownFromPage: CGAffineTransform
        switch r {
        case 90: shownFromPage = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)
        case 180: shownFromPage = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case 270: shownFromPage = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)
        default: shownFromPage = .identity
        }
        ctx.concatenate(shownFromPage.inverted())
        ctx.setTextDrawingMode(.invisible)
        for w in words {
            let box = CGRect(x: w.box.minX * shown.width, y: w.box.minY * shown.height,
                             width: w.box.width * shown.width, height: w.box.height * shown.height)
            guard box.width > 1, box.height > 1 else { continue }
            let size = box.height * 0.82
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: w.text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
            ctx.scaleBy(x: box.width / CGFloat(width), y: 1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}

// MARK: - Scan from iPhone (Continuity Camera)

/// An invisible view that sits in the responder chain and accepts what an iPhone or iPad sends:
/// AppKit fills its "Import from iPhone" menu item with nearby devices (Take Photo, Scan Documents).
final class ScanReceiverView: NSView, NSServicesMenuRequestor {
    weak var ws: PDFWorkspace?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ws?.scanReceiver = self
        if window != nil, ws?.wantsScanMenu == true {
            ws?.wantsScanMenu = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.popUp() }
        }
    }

    /// Opens the device menu now if this view is already on screen; otherwise it opens when it appears.
    func popUpIfVisible(wanted: inout Bool) {
        guard window != nil else { return }
        wanted = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.popUp() }
    }

    func popUp() {
        guard let window else { return }
        window.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Scan from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let r = returnType, r == .pdf || NSImage.imageTypes.contains(r.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        MainActor.assumeIsolated { ws?.receiveScan(pboard) ?? false }
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}

struct ScanReceiver: NSViewRepresentable {
    let ws: PDFWorkspace
    func makeNSView(context: Context) -> ScanReceiverView { let v = ScanReceiverView(); v.ws = ws; return v }
    func updateNSView(_ v: ScanReceiverView, context: Context) { v.ws = ws }
}

// MARK: - Options boxes

struct PDFScanOptions: View {
    let ws: PDFWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Scan from iPhone")
            OptButton("Scan with iPhone…", symbol: "iphone", primary: true) { ws.scanReceiver?.popUp() }
                .background(ScanReceiver(ws: ws))
            OptHint("Pick your iPhone, then Scan Documents or Take Photo. The pages land after page \(ws.current + 1).")
            OptHint("Needs an iPhone or iPad near this Mac, signed in to the same Apple ID, with Wi-Fi and Bluetooth on.")
        }
    }
}

struct PDFSearchableOptions: View {
    let ws: PDFWorkspace
    var body: some View {
        let missing = ws.textlessPages.count
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Make searchable")
            if ws.busy != nil {
                OptHint("Reading the pages on this Mac…")
            } else if missing == 0 {
                if let n = ws.ocrPages { OptHint("Done: \(Fmt.plural(n, "page")) can now be searched and copied. Save copy keeps it.") }
                else { OptHint("Every page already has text you can search and copy.") }
            } else {
                OptRow("Pages that are pictures", "\(missing) of \(ws.pageCount)")
                OptButton("Make searchable", symbol: "doc.text.magnifyingglass", primary: true) { ws.makeSearchable() }
                OptHint("Vision reads them on this Mac, about a second a page. Pages look the same; their words become searchable and copyable.")
            }
        }
    }
}
