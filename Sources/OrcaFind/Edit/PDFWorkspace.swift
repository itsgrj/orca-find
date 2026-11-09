import SwiftUI
import AppKit
import PDFKit

@MainActor
enum PDFWorkspaceFactory {
    static func make(_ item: FileItem) -> EditWorkspace { PDFWorkspace(item: item) }
    static func selfTest(_ item: FileItem, out: URL) async -> Bool { await PDFSelfTest.run(item, out: out) }
}

/// PDFs. The file is opened into memory; page and mark edits change that copy, with ⌘Z stepping back
/// through snapshots. Save copy writes it next to the original. Tools that make other files
/// (extract, split, images, text) write them straight away.
@MainActor
@Observable
final class PDFWorkspace: EditWorkspace {
    let item: FileItem
    var kind: EditKind { .pdf }

    private(set) var doc: PDFDocument?
    /// Pages in order, refreshed after every change (PDFDocument itself isn't observable).
    private(set) var pages: [PDFPage] = []
    /// Bumps on every change so thumbnails redraw.
    private(set) var revision = 0
    private(set) var active: ToolID?
    private(set) var busy: String?

    // Locked files
    private(set) var locked = false
    private(set) var wasEncrypted = false
    @ObservationIgnored private(set) var openPassword: String?
    var unlockText = ""
    private(set) var unlockFailed = false

    // Pages picked in the rail (indices) and the page on screen
    private(set) var selected: Set<Int> = []
    @ObservationIgnored private var anchor: Int?
    private(set) var current = 0

    // Undo: the document as it was before each change
    enum Change: Hashable {
        case rotate, delete, reorder, insert, blank, crop, merge, photos, highlight, note, forms, sign, details, gray, scan, searchable
    }
    private struct Step { let data: Data; let change: Change; let count: Int; let gray: Bool }
    private var steps: [Step] = []
    private(set) var grayscale = false

    // Compress
    var squeeze: PDFSqueeze? { didSet { scheduleEstimate() } }
    private(set) var estimate: Int64?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?

    // Password
    var newPassword = ""
    var confirmPassword = ""
    var removePassword = false

    // Highlight
    enum Marker: String, CaseIterable {
        case yellow = "Yellow", green = "Green", pink = "Pink", blue = "Blue"
        var color: NSColor {
            switch self {
            case .yellow: return NSColor(hex: 0xFFE14D).withAlphaComponent(0.55)
            case .green: return NSColor(hex: 0x7EE08A).withAlphaComponent(0.55)
            case .pink: return NSColor(hex: 0xFF8FC7).withAlphaComponent(0.55)
            case .blue: return NSColor(hex: 0x86C5FF).withAlphaComponent(0.55)
            }
        }
    }
    var marker: Marker = .yellow
    private(set) var highlightCount = 0

    // Text box
    @ObservationIgnored private weak var note: PDFAnnotation?
    private(set) var editingNote = false
    var noteText = "" { didSet { if noteText != oldValue { updateNote() } } }
    var noteSize: CGFloat = 14 { didSet { if noteSize != oldValue { updateNote() } } }

    // Find
    struct Hit: Identifiable {
        let id: Int
        let selection: PDFSelection
        let page: Int
        let context: String
    }
    var query = "" { didSet { if query != oldValue { scheduleFind() } } }
    private(set) var hits: [Hit] = []
    private(set) var hitCount = 0
    private(set) var focusedHit: Int?
    @ObservationIgnored private var findTask: Task<Void, Never>?

    // Copy text / translate
    private(set) var selectionText = ""
    var showTranslation = false
    @ObservationIgnored private var textCache: String?

    // Forms
    private(set) var formFields = 0
    @ObservationIgnored private var widgets: [PDFAnnotation] = []
    @ObservationIgnored private var formBaseline: Data?
    @ObservationIgnored private var formSignature = ""

    // Sign
    var strokes: [[CGPoint]] = []
    var liveStroke: [CGPoint] = []

    // Split, images, crop
    var splitEvery = 1
    var imageKind: PDFEngine.ImageKind = .png
    var imageDPI = 150
    var cropAll = true

    // Reorder: the order on screen while dragging
    var order: [PDFPage] = []

    @ObservationIgnored weak var view: PDFView?

    init(item: FileItem) {
        self.item = item
        load()
    }

    private func load() {
        guard let d = PDFDocument(url: item.url) else { doc = nil; pages = []; return }
        wasEncrypted = d.isEncrypted
        if d.isLocked, let p = openPassword { _ = d.unlock(withPassword: p) }
        locked = d.isLocked
        doc = d
        touched()
    }

    // MARK: Tool lists

    let bar: [ToolID] = [.pdfCopyText, .highlight, .reorderPages, .compressPDF]

    var groups: [ToolGroup] {
        [ToolGroup(title: "Pages", tools: [.rotatePages, .deletePages, .reorderPages, .extractPages, .splitPDF, .insertPages, .insertBlank, .cropMargins]),
         ToolGroup(title: "Combine", tools: [.mergePDFs, .photosToPDF, .scanFromIPhone]),
         ToolGroup(title: "Text & marks", tools: [.pdfCopyText, .makeSearchable, .findInPDF, .highlight, .textNote, .fillForms, .sign, .pdfTranslate]),
         ToolGroup(title: "Save as", tools: [.compressPDF, .pdfToImages, .pdfToText, .password, .removeDetails, .blackAndWhite])]
    }

    func barTitle(_ tool: ToolID) -> String {
        switch tool {
        case .pdfCopyText: return "Copy text"
        case .highlight: return "Highlight"
        case .reorderPages: return "Reorder pages"
        case .compressPDF: return "Compress"
        default: return tool.title
        }
    }

    func isAvailable(_ tool: ToolID) -> Bool {
        switch tool {
        default: return doc != nil
        }
    }

    // MARK: State

    var pageCount: Int { pages.count }

    private var passwordPending: Bool { !newPassword.isEmpty && newPassword == confirmPassword }
    private var orderPending: Bool { active == .reorderPages && !order.isEmpty && order != pages }

    var canUndo: Bool { !steps.isEmpty || squeeze != nil || passwordPending || removePassword || orderPending }
    var hasEdits: Bool { canUndo }

    /// What changed, in plain words, oldest first.
    private var summaries: [(text: String, suffix: String)] {
        var order: [Change] = []
        var counts: [Change: Int] = [:]
        for s in steps {
            if counts[s.change] == nil { order.append(s.change) }
            counts[s.change, default: 0] += s.count
        }
        var out = order.map { c -> (String, String) in Self.describe(c, counts[c] ?? 1) }
        if orderPending, counts[.reorder] == nil { out.append(Self.describe(.reorder, 1)) }
        if let s = squeeze { out.append((s == .smallest ? "compressed (smallest)" : "compressed", "compressed")) }
        if passwordPending { out.append(("locked with a password", "locked")) }
        else if removePassword { out.append(("password removed", "unlocked")) }
        return out
    }

    private static func describe(_ c: Change, _ n: Int) -> (String, String) {
        switch c {
        case .rotate: return ("\(Fmt.plural(n, "page")) rotated", "rotated")
        case .delete: return ("\(Fmt.plural(n, "page")) deleted", "pages removed")
        case .reorder: return ("pages reordered", "reordered")
        case .insert: return ("\(Fmt.plural(n, "page")) inserted", "pages added")
        case .blank: return (n == 1 ? "blank page added" : "\(n) blank pages added", "pages added")
        case .crop: return ("margins cropped on \(Fmt.plural(n, "page"))", "cropped")
        case .merge: return ("\(Fmt.plural(n, "page")) merged in", "merged")
        case .photos: return ("\(Fmt.plural(n, "photo")) added", "pages added")
        case .highlight: return ("\(Fmt.plural(n, "highlight"))", "highlighted")
        case .note: return (n == 1 ? "text box added" : "\(n) text boxes added", "notes")
        case .forms: return ("form filled in", "filled")
        case .sign: return ("signed", "signed")
        case .details: return ("details removed", "no details")
        case .gray: return ("black & white", "black & white")
        case .scan: return ("\(Fmt.plural(n, "page")) scanned in", "scanned")
        case .searchable: return ("\(Fmt.plural(n, "page")) made searchable", "searchable")
        }
    }

    private func suffix() -> String {
        let s = Set(summaries.map(\.suffix))
        return s.count == 1 ? s.first! : "edited"
    }

    var status: String? {
        guard hasEdits else { return nil }
        let name = CopySaver.destination(near: item.url, suffix: suffix(), ext: "pdf").lastPathComponent
        let what = summaries.map(\.text).joined(separator: " · ").capitalizedFirst
        return "\(what) · will save as \(name)"
    }

    // MARK: Pages on screen

    /// Call after anything changes the document.
    private func touched() {
        guard let doc else { pages = []; return }
        pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        revision += 1
        textCache = nil
        selected = selected.filter { $0 < pages.count }
        current = min(current, max(0, pages.count - 1))
        widgets = locked ? [] : pages.flatMap { $0.annotations.filter { $0.type == "Widget" } }
        formFields = widgets.count
        formSignature = formState()
        if active == .findInPDF, !query.isEmpty { scheduleFind() }
        if squeeze != nil { scheduleEstimate() }
        view?.layoutDocumentView()
        (view as? OrcaPDFView)?.fitPage()
        view?.needsDisplay = true
    }

    /// The pages a page action works on: the ones picked in the rail, or the one on screen.
    var targets: [Int] {
        let s = selected.sorted()
        if !s.isEmpty { return s }
        return pages.isEmpty ? [] : [current]
    }

    func pageChanged(to index: Int) { if index != current { current = index } }

    /// Click, ⌘-click and ⇧-click in the page rail.
    func tapPage(_ i: Int, command: Bool, shift: Bool) {
        if shift, let a = anchor {
            selected = Set(min(a, i)...max(a, i))
        } else if command {
            if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
            anchor = i
        } else {
            selected = [i]; anchor = i
        }
        go(to: i)
    }

    func clearSelection() { selected = []; anchor = nil }

    func go(to i: Int) {
        guard let page = doc?.page(at: i) else { return }
        current = i
        view?.go(to: page)
    }

    @ObservationIgnored private var thumbs = NSCache<NSString, NSImage>()

    func thumbnail(_ page: PDFPage, width: CGFloat) -> NSImage {
        let key = "\(ObjectIdentifier(page).hashValue)-\(revision)-\(Int(width))" as NSString
        if let t = thumbs.object(forKey: key) { return t }
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let aspect = turned ? box.width / max(box.height, 1) : box.height / max(box.width, 1)
        let t = page.thumbnail(of: CGSize(width: width * 2, height: width * 2 * aspect), for: .cropBox)
        thumbs.setObject(t, forKey: key)
        return t
    }

    /// Height / width of a page as shown.
    func aspect(_ page: PDFPage) -> CGFloat {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return 1.294 }
        return page.rotation % 180 != 0 ? box.width / box.height : box.height / box.width
    }

    // MARK: Scan from iPhone and make searchable

    @ObservationIgnored weak var scanReceiver: ScanReceiverView?
    @ObservationIgnored var wantsScanMenu = false
    private(set) var ocrPages: Int?
    @ObservationIgnored private var ocrTask: Task<Void, Never>?

    /// Pages that are only pictures (no real text).
    var textlessPages: [Int] { locked ? [] : pages.indices.filter { PDFOCR.needsText(pages[$0]) } }

    /// What an iPhone sent: a scanned PDF or a photo. Goes in after the page on screen.
    @discardableResult
    func receiveScan(_ pb: NSPasteboard) -> Bool {
        guard let doc else { return false }
        var made: [PDFPage] = []
        if let d = pb.data(forType: .pdf), let src = PDFDocument(data: d) {
            made = (0..<src.pageCount).compactMap { src.page(at: $0) }
        } else if let img = NSImage(pasteboard: pb),
                  let p = PDFEngine.imagePage(img, pageSize: doc.page(at: 0)?.bounds(for: .mediaBox).size) {
            made = [p]
        }
        guard !made.isEmpty else { EditToastCenter.shared.show("Nothing came through from the iPhone"); return false }
        push(.scan, made.count)
        let at = doc.pageCount == 0 ? 0 : current + 1
        for (k, p) in made.enumerated() { doc.insert(p, at: at + k) }
        touched()
        go(to: at)
        EditToastCenter.shared.show("\(Fmt.plural(made.count, "page")) scanned in after page \(at)")
        return true
    }

    func makeSearchable() {
        guard let doc, busy == nil, !locked else { return }
        let targets = textlessPages
        guard !targets.isEmpty else { EditToastCenter.shared.show("Every page already has text"); return }
        guard let data = doc.dataRepresentation() else { return }
        let password = openPassword, startRevision = revision, total = targets.count
        busy = "Reading page 1 of \(total)…"
        ocrTask = Task {
            let results = await PDFOCR.searchablePages(data: data, password: password, indices: targets) { n in
                Task { @MainActor in if self.busy != nil { self.busy = "Reading page \(n + 1) of \(total)…" } }
            }
            busy = nil
            guard revision == startRevision, let doc = self.doc else {
                EditToastCenter.shared.show("The PDF changed while it was being read. Try again."); return
            }
            guard !results.isEmpty else { EditToastCenter.shared.show("No text found on those pages"); return }
            push(.searchable, results.count)
            for (i, pageData) in results.sorted(by: { $0.key < $1.key }) {
                guard let made = PDFDocument(data: pageData)?.page(at: 0), let old = doc.page(at: i) else { continue }
                made.rotation = old.rotation
                let crop = old.bounds(for: .cropBox)
                for a in old.annotations {
                    old.removeAnnotation(a)
                    a.bounds = a.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY)
                    made.addAnnotation(a)
                }
                doc.removePage(at: i)
                doc.insert(made, at: i)
            }
            touched()
            ocrPages = results.count
            EditToastCenter.shared.show("\(Fmt.plural(results.count, "page")) can now be searched and copied")
        }
    }

    // MARK: Undo

    private func push(_ change: Change, _ count: Int = 1) {
        guard let d = doc?.dataRepresentation() else { return }
        steps.append(Step(data: d, change: change, count: count, gray: grayscale))
        if steps.count > 40 { steps.removeFirst() }
    }

    func undo() {
        if orderPending { order = pages; return }
        if passwordPending || removePassword { newPassword = ""; confirmPassword = ""; removePassword = false; return }
        if squeeze != nil { squeeze = nil; estimate = nil; return }
        guard let last = steps.popLast() else { return }
        restore(last.data)
        grayscale = last.gray
        applyGrayPreview()
    }

    private func restore(_ data: Data) {
        guard let d = PDFDocument(data: data) else { return }
        if d.isLocked, let p = openPassword { _ = d.unlock(withPassword: p) }
        note = nil; editingNote = false
        hits = []; hitCount = 0; focusedHit = nil
        doc = d
        touched()
        if active == .reorderPages { order = pages }
    }

    func discard() {
        finishNote()
        steps.removeAll()
        grayscale = false
        squeeze = nil; estimate = nil
        newPassword = ""; confirmPassword = ""; removePassword = false
        strokes = []; liveStroke = []
        hits = []; hitCount = 0; query = ""
        active = nil
        selected = []
        load()
        applyGrayPreview()
    }

    // MARK: Picking tools

    func select(_ tool: ToolID) {
        guard isAvailable(tool), doc != nil else { return }
        if locked {
            active = .password
            if tool != .password { EditToastCenter.shared.show("Unlock this PDF first") }
            return
        }
        switch tool {
        case .rotatePages: leaveMode(); rotate(targets); return
        case .deletePages: leaveMode(); delete(targets); return
        case .extractPages: leaveMode(); extract(targets); return
        case .insertPages: leaveMode(); pickPDFs(multiple: false) { self.insert(urls: $0) }; return
        case .insertBlank: leaveMode(); insertBlank(); return
        case .mergePDFs: leaveMode(); pickPDFs(multiple: true) { self.merge(urls: $0) }; return
        case .photosToPDF: leaveMode(); pickPhotos { self.addPhotos(urls: $0) }; return
        case .pdfToText: leaveMode(); saveText(); return
        case .removeDetails: leaveMode(); removeDetails(); return
        case .blackAndWhite: leaveMode(); toggleGray(); return
        default: break
        }
        if active == tool { leaveMode(); return }
        leaveMode()
        active = tool
        enter(tool)
    }

    private func enter(_ tool: ToolID) {
        switch tool {
        case .reorderPages: order = pages
        case .compressPDF: if squeeze == nil { squeeze = .smaller }
        case .findInPDF:
            // Dev hook for --edit-snapshot: ORCA_PDF_FIND=word fills the search field.
            if query.isEmpty, let q = ProcessInfo.processInfo.environment["ORCA_PDF_FIND"] { query = q }
            if !query.isEmpty { scheduleFind() }
        case .scanFromIPhone: wantsScanMenu = true; scanReceiver?.popUpIfVisible(wanted: &wantsScanMenu)
        case .pdfCopyText, .pdfTranslate: selectionText = view?.currentSelection?.string ?? ""
        case .highlight: if let s = view?.currentSelection, !(s.string ?? "").isEmpty { highlight(s) }
        default: break
        }
    }

    /// Leaves the current mode, keeping what it did.
    private func leaveMode() {
        switch active {
        case .reorderPages: commitOrder()
        case .findInPDF: view?.highlightedSelections = nil
        case .textNote: finishNote()
        case .sign: liveStroke = []
        default: break
        }
        active = nil
    }

    // MARK: Page actions

    func rotate(_ indices: [Int], by degrees: Int = 90) {
        guard let doc, !indices.isEmpty else { return }
        push(.rotate, indices.count)
        for i in indices { if let p = doc.page(at: i) { p.rotation = ((p.rotation + degrees) % 360 + 360) % 360 } }
        touched()
    }

    func delete(_ indices: [Int]) {
        guard let doc, !indices.isEmpty else { return }
        guard indices.count < doc.pageCount else { EditToastCenter.shared.show("A PDF needs at least one page"); return }
        push(.delete, indices.count)
        for i in indices.sorted(by: >) { doc.removePage(at: i) }
        selected = []
        current = min(indices.min() ?? 0, doc.pageCount - 1)
        touched()
        EditToastCenter.shared.show("\(Fmt.plural(indices.count, "page")) deleted · ⌘Z to undo")
    }

    /// Puts the pages in `newOrder` (each page once).
    func reorder(_ newOrder: [PDFPage]) {
        guard let doc, newOrder.count == doc.pageCount, newOrder != pages else { return }
        push(.reorder)
        for i in (0..<doc.pageCount).reversed() { doc.removePage(at: i) }
        for (i, p) in newOrder.enumerated() { doc.insert(p, at: i) }
        selected = []
        touched()
    }

    func movePage(_ page: PDFPage, before target: PDFPage) {
        guard let from = order.firstIndex(of: page), let to = order.firstIndex(of: target), from != to else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func commitOrder() {
        guard !order.isEmpty, order != pages else { return }
        reorder(order)
        order = pages
    }

    func extract(_ picked: [Int]) {
        let indices = Array(Set(picked)).sorted()
        guard let doc, !indices.isEmpty else { return }
        let out = PDFEngine.subset(doc, indices)
        let dest = CopySaver.destination(near: item.url, suffix: PDFEngine.pagesLabel(indices), ext: "pdf")
        guard out.write(to: dest) else { EditToastCenter.shared.show("Couldn’t save those pages"); return }
        CopySaver.register(dest, like: item)
        EditToastCenter.shared.show(saved: .init(original: item, copy: dest))
    }

    /// Writes one PDF per run of pages into a folder next to the original.
    @discardableResult
    func split(every: Int) -> URL? {
        guard let doc else { return nil }
        let runs = PDFEngine.runs(pageCount: doc.pageCount, every: every)
        guard runs.count > 1 else { EditToastCenter.shared.show("Nothing to split: that’s every page in one file"); return nil }
        let base = item.url.deletingPathExtension().lastPathComponent
        let folder = PDFEngine.uniqueFolder(near: item.url, name: "\(base) split")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for r in runs {
                let file = folder.appendingPathComponent("\(base) (\(PDFEngine.pagesLabel(r))).pdf")
                guard PDFEngine.subset(doc, r).write(to: file) else { throw EditError.message("Couldn’t write \(file.lastPathComponent)") }
                CopySaver.register(file, like: item)
            }
        } catch {
            EditToastCenter.shared.show("Couldn’t split: \(error.localizedDescription)")
            return nil
        }
        EditToastCenter.shared.show(saved: .init(original: item, copy: folder))
        return folder
    }

    func insert(urls: [URL]) {
        guard let doc, let url = urls.first else { return }
        guard let src = openOther(url) else { return }
        push(.insert, src.pageCount)
        let n = PDFEngine.insert(src, into: doc, at: current + 1)
        touched()
        go(to: current + 1)
        EditToastCenter.shared.show("\(Fmt.plural(n, "page")) added after page \(current)")
    }

    func merge(urls: [URL]) {
        guard let doc, !urls.isEmpty else { return }
        let others = urls.compactMap(openOther)
        guard !others.isEmpty else { return }
        push(.merge, others.reduce(0) { $0 + $1.pageCount })
        let first = doc.pageCount
        var n = 0
        for o in others { n += PDFEngine.insert(o, into: doc, at: doc.pageCount) }
        touched()
        go(to: first)
        EditToastCenter.shared.show("\(Fmt.plural(n, "page")) added at the end")
    }

    func addPhotos(urls: [URL]) {
        guard let doc, !urls.isEmpty else { return }
        let size = doc.page(at: 0)?.bounds(for: .mediaBox).size
        let made = urls.compactMap { NSImage(contentsOf: $0) }.compactMap { PDFEngine.imagePage($0, pageSize: size) }
        guard !made.isEmpty else { EditToastCenter.shared.show("Couldn’t read those photos"); return }
        push(.photos, made.count)
        let first = doc.pageCount
        for p in made { doc.insert(p, at: doc.pageCount) }
        touched()
        go(to: first)
        EditToastCenter.shared.show("\(Fmt.plural(made.count, "photo")) added at the end")
    }

    private func openOther(_ url: URL) -> PDFDocument? {
        guard let d = PDFDocument(url: url) else { EditToastCenter.shared.show("Couldn’t open \(url.lastPathComponent)"); return nil }
        if d.isLocked { EditToastCenter.shared.show("\(url.lastPathComponent) is locked with a password"); return nil }
        return d
    }

    func insertBlank() {
        guard let doc else { return }
        push(.blank)
        let at = min(current + 1, doc.pageCount)
        doc.insert(PDFEngine.blankPage(like: doc.page(at: current)), at: at)
        touched()
        go(to: at)
    }

    func cropMargins(_ indices: [Int]) {
        guard let doc, !indices.isEmpty, let data = doc.dataRepresentation() else { return }
        let pw = openPassword
        busy = "Finding the margins…"
        Task {
            let crops = await Task.detached(priority: .userInitiated) { () -> [Int: CGRect] in
                guard let copy = PDFEngine.open(data, password: pw) else { return [:] }
                return PDFEngine.marginCrops(copy, indices: indices)
            }.value
            busy = nil
            guard !crops.isEmpty, self.doc === doc else { EditToastCenter.shared.show("No margins to trim"); return }
            push(.crop, crops.count)
            for (i, r) in crops { doc.page(at: i)?.setBounds(r, for: .cropBox) }
            touched()
            EditToastCenter.shared.show("Margins trimmed on \(Fmt.plural(crops.count, "page")) · ⌘Z to undo")
        }
    }

    /// Same as `cropMargins` but waits (for the self-test).
    func cropMarginsNow(_ indices: [Int]) -> Int {
        guard let doc else { return 0 }
        let crops = PDFEngine.marginCrops(doc, indices: indices)
        guard !crops.isEmpty else { return 0 }
        push(.crop, crops.count)
        for (i, r) in crops { doc.page(at: i)?.setBounds(r, for: .cropBox) }
        touched()
        return crops.count
    }

    private func pickPDFs(multiple: Bool, _ done: @escaping ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = multiple
        p.message = multiple ? "Pick the PDFs to add at the end" : "Pick a PDF to add after page \(current + 1)"
        p.prompt = multiple ? "Merge" : "Insert"
        p.directoryURL = item.url.deletingLastPathComponent()
        if p.runModal() == .OK { done(p.urls) }
    }

    private func pickPhotos(_ done: @escaping ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        p.message = "Pick photos to add as pages at the end"
        p.prompt = "Add"
        if p.runModal() == .OK { done(p.urls) }
    }

    // MARK: Text

    var fullText: String {
        if let t = textCache { return t }
        let t = locked ? "" : (doc?.string ?? "")
        textCache = t
        return t
    }

    var hasText: Bool { !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func selectionChanged() {
        selectionText = view?.currentSelection?.string ?? ""
    }

    func copyAllText() {
        guard hasText else { EditToastCenter.shared.show("No text in this PDF. It may be a scan."); return }
        FileActions.copyText(fullText)
        EditToastCenter.shared.show("Copied all the text · \(Fmt.plural(pages.count, "page"))")
    }

    func copySelectedText() {
        let t = view?.currentSelection?.string ?? selectionText
        guard !t.isEmpty else { EditToastCenter.shared.show("Select some text on the page first"); return }
        FileActions.copyText(t)
        EditToastCenter.shared.show("Copied the selected text")
    }

    /// What Translate shows: the selection, or the start of the document.
    var translationSource: String {
        if !selectionText.isEmpty { return selectionText }
        return String(fullText.prefix(4000))
    }

    func saveText() {
        guard hasText else { EditToastCenter.shared.show("No text in this PDF. It may be a scan."); return }
        let dest = CopySaver.destination(near: item.url, suffix: nil, ext: "txt")
        do {
            try fullText.write(to: dest, atomically: true, encoding: .utf8)
            CopySaver.register(dest, like: item)
            EditToastCenter.shared.show(saved: .init(original: item, copy: dest))
        } catch {
            EditToastCenter.shared.show("Couldn’t save the text: \(error.localizedDescription)")
        }
    }

    // MARK: Find

    private func scheduleFind() {
        findTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; hitCount = 0; focusedHit = nil; view?.highlightedSelections = nil; return }
        findTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            runFind(q)
        }
    }

    func runFind(_ q: String) {
        guard let doc else { return }
        let found = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        hitCount = found.count
        hits = found.prefix(300).enumerated().map { i, sel in
            let page = sel.pages.first.map { doc.index(for: $0) } ?? 0
            let wide = sel.copy() as! PDFSelection
            wide.extendForLineBoundaries()
            var ctx = (wide.string ?? sel.string ?? "").replacingOccurrences(of: "\n", with: " ")
            // Start a few words before the match so it shows in the two lines the list has room for.
            if let r = ctx.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                var start = ctx.index(r.lowerBound, offsetBy: -18, limitedBy: ctx.startIndex) ?? ctx.startIndex
                if start > ctx.startIndex, let space = ctx[start..<r.lowerBound].firstIndex(of: " ") { start = ctx.index(after: space) }
                ctx = (start > ctx.startIndex ? "…" : "") + String(ctx[start...].prefix(90))
            }
            return Hit(id: i, selection: sel, page: page, context: ctx.trimmingCharacters(in: .whitespaces))
        }
        focusedHit = nil
        for s in found { s.color = NSColor(hex: 0xFFE14D).withAlphaComponent(0.6) }
        view?.highlightedSelections = active == .findInPDF ? found : nil
    }

    func showHit(_ h: Hit) {
        focusedHit = h.id
        current = h.page
        view?.setCurrentSelection(h.selection, animate: true)
        view?.go(to: h.selection)
    }

    /// Highlights every hit as a real mark in the file.
    func highlightAllHits() {
        guard let doc, !query.isEmpty else { return }
        let found = doc.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        guard !found.isEmpty else { return }
        push(.highlight, found.count)
        for s in found { PDFEngine.highlight(s, color: marker.color) }
        touched()
        EditToastCenter.shared.show("\(Fmt.plural(found.count, "match", "matches")) highlighted · ⌘Z to undo")
    }

    // MARK: Highlight

    /// The user let go of the mouse in the PDF.
    func mouseUpInPDF() {
        if active == .highlight, let s = view?.currentSelection, !(s.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            highlight(s)
            view?.clearSelection()
        }
        formsMaybeChanged()
        selectionChanged()
    }

    func highlight(_ selection: PDFSelection) {
        guard doc != nil else { return }
        push(.highlight)
        let n = PDFEngine.highlight(selection, color: marker.color)
        if n == 0 { steps.removeLast(); return }
        highlightCount += 1
        touched()
        for p in selection.pages { view?.annotationsChanged(on: p) }
    }

    // MARK: Text box & signature (clicks on the page)

    /// A click on the page while a tool wants it. Returns true when the click was used.
    func click(on page: PDFPage, at p: CGPoint) -> Bool {
        switch active {
        case .textNote:
            if let a = page.annotation(at: p), a.type == "FreeText" {
                finishNote()
                note = a; editingNote = true
                noteText = a.contents ?? ""
                noteSize = a.font?.pointSize ?? 14
                return true
            }
            finishNote()
            addNote(on: page, at: p)
            return true
        case .sign:
            guard !strokes.isEmpty else { return false }
            placeSignature(on: page, center: p)
            return true
        default:
            return false
        }
    }

    func addNote(on page: PDFPage, at p: CGPoint, text: String = "Text") {
        push(.note)
        // The click lands on the first line of text, as it's seen on screen.
        let up = PDFEngine.pageVector(CGPoint(x: 0, y: noteSize * 0.7), rotation: page.rotation)
        let a = PDFEngine.textBox(text, anchor: CGPoint(x: p.x + up.x, y: p.y + up.y), size: noteSize, rotation: page.rotation)
        page.addAnnotation(a)
        note = a; editingNote = true
        noteText = text
        touched()
        view?.annotationsChanged(on: page)
    }

    private func updateNote() {
        guard let a = note, let page = a.page else { return }
        a.font = NSFont.systemFont(ofSize: noteSize)
        a.contents = noteText
        a.bounds = PDFEngine.textBoxBounds(noteText, anchor: PDFEngine.textBoxAnchor(a.bounds, rotation: page.rotation), size: noteSize, rotation: page.rotation)
        view?.annotationsChanged(on: page)
        view?.needsDisplay = true
    }

    /// Drops an empty text box, keeps a typed one.
    func finishNote() {
        defer { note = nil; editingNote = false }
        guard let a = note, let page = a.page else { return }
        if (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            page.removeAnnotation(a)
            if steps.last?.change == .note { steps.removeLast() }
            view?.annotationsChanged(on: page)
        }
        revision += 1
    }

    func deleteNote() {
        guard let a = note, let page = a.page else { return }
        page.removeAnnotation(a)
        note = nil; editingNote = false
        touched()
        view?.annotationsChanged(on: page)
    }

    func placeSignature(on page: PDFPage? = nil, center: CGPoint? = nil) {
        guard let page = page ?? doc?.page(at: current) else { return }
        let box = page.bounds(for: .cropBox)
        // Default: middle of the lower third, as the page is seen.
        let down = PDFEngine.pageVector(CGPoint(x: 0, y: -(page.rotation % 180 != 0 ? box.width : box.height) / 3), rotation: page.rotation)
        let c = center ?? CGPoint(x: box.midX + down.x, y: box.midY + down.y)
        let seenWidth = page.rotation % 180 != 0 ? box.height : box.width
        let width = min(180, seenWidth * 0.32)
        guard let a = PDFEngine.signature(strokes, center: c, width: width, rotation: page.rotation) else { EditToastCenter.shared.show("Draw your signature first"); return }
        push(.sign)
        page.addAnnotation(a)
        touched()
        view?.annotationsChanged(on: page)
        EditToastCenter.shared.show("Signature placed · ⌘Z to undo")
    }

    // MARK: Forms

    private func formState() -> String {
        widgets.map { "\($0.widgetStringValue ?? "")|\($0.buttonWidgetState.rawValue)" }.joined(separator: "¦")
    }

    /// Before a click lands in the PDF, remember the forms as they are.
    func mouseDownInPDF() {
        guard formFields > 0, formBaseline == nil else { return }
        formBaseline = doc?.dataRepresentation()
    }

    /// Something was typed into the PDF's form fields.
    func formTyped() {
        guard formFields > 0 else { return }
        if let base = formBaseline {
            steps.append(Step(data: base, change: .forms, count: 1, gray: grayscale))
            formBaseline = nil
        }
    }

    func formsMaybeChanged() {
        guard formFields > 0 else { return }
        let s = formState()
        guard s != formSignature else { return }
        formSignature = s
        if let base = formBaseline {
            steps.append(Step(data: base, change: .forms, count: 1, gray: grayscale))
            formBaseline = nil
        } else if !steps.contains(where: { $0.change == .forms }), let d = doc?.dataRepresentation() {
            steps.append(Step(data: d, change: .forms, count: 1, gray: grayscale))
        }
    }

    /// Ends typing in a form field so its value is in the document.
    private func endFieldEditing() {
        if let v = view, let w = v.window, let r = w.firstResponder as? NSView, r !== v, r.isDescendant(of: v) {
            w.makeFirstResponder(v)
        }
        formsMaybeChanged()
    }

    // MARK: Details, colour, password

    func removeDetails() {
        guard let doc else { return }
        let keys = [PDFDocumentAttribute.authorAttribute, .creatorAttribute, .producerAttribute, .titleAttribute,
                    .subjectAttribute, .keywordsAttribute]
        let attrs = doc.documentAttributes ?? [:]
        guard keys.contains(where: { attrs[$0] != nil }) else { EditToastCenter.shared.show("No details saved in this PDF"); return }
        push(.details)
        var clean = attrs
        for k in keys { clean.removeValue(forKey: k) }
        doc.documentAttributes = clean
        touched()
        EditToastCenter.shared.show("Author, title and app details removed")
    }

    var details: [(String, String)] {
        let a = doc?.documentAttributes ?? [:]
        let keys: [(PDFDocumentAttribute, String)] = [(.titleAttribute, "Title"), (.authorAttribute, "Author"), (.creatorAttribute, "Made with"), (.producerAttribute, "Producer")]
        return keys.compactMap { k, label in
            guard let v = a[k] as? String, !v.isEmpty else { return nil }
            return (label, v)
        }
    }

    func toggleGray() {
        if grayscale {
            // Undo the step that turned it on if it's the last one; otherwise just switch it back.
            if steps.last?.change == .gray { undo(); return }
            push(.gray); grayscale = false
        } else {
            push(.gray); grayscale = true
            EditToastCenter.shared.show("The copy will be black & white · ⌘Z to undo")
        }
        applyGrayPreview()
    }

    func applyGrayPreview() {
        guard let v = view else { return }
        v.wantsLayer = true
        if grayscale, let f = CIFilter(name: "CIColorControls") {
            f.setDefaults(); f.setValue(0, forKey: kCIInputSaturationKey)
            v.contentFilters = [f]
        } else {
            v.contentFilters = []
        }
    }

    func unlock() {
        guard let doc else { return }
        if doc.unlock(withPassword: unlockText) {
            openPassword = unlockText
            locked = false
            unlockFailed = false
            unlockText = ""
            active = nil
            touched()
            view?.document = nil
            view?.document = doc
        } else {
            unlockFailed = true
        }
    }

    var passwordMismatch: Bool { !newPassword.isEmpty && !confirmPassword.isEmpty && newPassword != confirmPassword }

    // MARK: Compress

    private var plan: PDFSavePlan {
        var p = PDFSavePlan(squeeze: squeeze, grayscale: grayscale, unlock: openPassword)
        if passwordPending { p.password = .set(newPassword) }
        else if removePassword { p.password = .remove }
        else { p.password = .keep(wasEncrypted ? openPassword : nil) }
        return p
    }

    func scheduleEstimate() {
        estimateTask?.cancel()
        estimate = nil
        guard squeeze != nil, let doc else { return }
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let data = doc.dataRepresentation() else { return }
            let p = plan
            let bytes = await Task.detached(priority: .utility) { PDFEngine.estimate(data, plan: p) }.value
            guard !Task.isCancelled else { return }
            estimate = bytes
        }
    }

    // MARK: Images

    func saveImages() {
        guard let doc, busy == nil, let data = doc.dataRepresentation() else { return }
        let base = item.url.deletingPathExtension().lastPathComponent
        let folder = PDFEngine.uniqueFolder(near: item.url, name: "\(base) pages")
        let kind = imageKind, dpi = CGFloat(imageDPI), pw = openPassword, total = doc.pageCount, original = item
        busy = "Saving \(Fmt.plural(total, "page")) as pictures…"
        Task {
            let result: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                guard let copy = PDFEngine.open(data, password: pw) else { return .failure(EditError.message("Couldn’t read this PDF")) }
                do { return .success(try PDFEngine.writeImages(copy, to: folder, kind: kind, dpi: dpi)) } catch { return .failure(error) }
            }.value
            busy = nil
            switch result {
            case .success:
                CopySaver.register(folder, like: original)
                EditToastCenter.shared.show(saved: .init(original: original, copy: folder))
            case .failure(let e):
                EditToastCenter.shared.show("Couldn’t save the pictures: \(e.localizedDescription)")
            }
        }
    }

    // MARK: Saving

    func save() async throws -> URL {
        endFieldEditing()
        if active == .reorderPages { commitOrder() }
        if active == .textNote { finishNote() }
        guard let doc, !locked, let data = doc.dataRepresentation() else { throw EditError.message("Nothing to save") }
        let dest = CopySaver.destination(near: item.url, suffix: suffix(), ext: "pdf")
        let p = plan
        busy = "Saving…"
        defer { busy = nil }
        try await Task.detached(priority: .userInitiated) { try PDFEngine.write(data, plan: p, to: dest) }.value
        CopySaver.register(dest, like: item)
        return dest
    }

    // MARK: Views

    func stage() -> AnyView { AnyView(PDFStage(ws: self)) }
    func options() -> AnyView { AnyView(PDFOptions(ws: self)) }
}
