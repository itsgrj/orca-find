import SwiftUI
import AppKit
import PDFKit
import Translation

// MARK: - Stage: the PDF, with the page rail on the right

struct PDFStage: View {
    @Bindable var ws: PDFWorkspace

    var body: some View {
        ZStack {
            if ws.doc == nil {
                EmptyState(symbol: "doc.richtext", tag: "PDF", title: "Can’t open this PDF", message: "It may be damaged, or not really a PDF.")
            } else if ws.locked {
                EmptyState(symbol: "lock", tag: "PDF", title: "This PDF is locked", message: "Type its password to open it. It stays on this Mac.",
                           actions: AnyView(UnlockField(ws: ws).frame(width: 260)))
            } else if ws.active == .reorderPages {
                ReorderGrid(ws: ws)
            } else {
                HStack(spacing: 0) {
                    PDFKitView(ws: ws)
                    Rectangle().fill(DS.border).frame(width: 1)
                    PageRail(ws: ws).frame(width: 120)
                }
            }
            if let b = ws.busy {
                VStack {
                    DarkPill {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(b).font(DS.bodySM)
                        Text("on this Mac").font(DS.caption).foregroundStyle(DS.onDark2)
                    }
                    .padding(.top, 18)
                    Spacer()
                }
            }
        }
    }
}

/// PDFKit's own view: scrolling, text selection, form fields. Clicks for text boxes and signatures
/// are picked off before PDFKit sees them.
final class OrcaPDFView: PDFView {
    weak var ws: PDFWorkspace?
    /// Shows a whole page until the user zooms; then their zoom wins.
    var fitsPage = true

    override func layout() {
        super.layout()
        fitPage()
    }

    func fitPage() {
        guard fitsPage, let page = currentPage ?? document?.page(at: 0), bounds.width > 50, bounds.height > 50 else { return }
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let w = turned ? box.height : box.width, h = turned ? box.width : box.height
        guard w > 0, h > 0 else { return }
        let s = max(0.1, min((bounds.width - 48) / w, (bounds.height - 32) / h, 2.5))
        guard abs(scaleFactor - s) > 0.001 else { return }
        scaleFactor = s
    }

    // Only the user's own zooming stops the fit.
    override func magnify(with event: NSEvent) { fitsPage = false; super.magnify(with: event) }
    override func zoomIn(_ sender: Any?) { fitsPage = false; super.zoomIn(sender) }
    override func zoomOut(_ sender: Any?) { fitsPage = false; super.zoomOut(sender) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let ws, let page = page(for: p, nearest: true), ws.click(on: page, at: convert(p, to: page)) { return }
        ws?.mouseDownInPDF()
        super.mouseDown(with: event)
        // PDFKit sometimes tracks the whole drag inside mouseDown, so look at the selection here too.
        ws?.mouseUpInPDF()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        ws?.mouseUpInPDF()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        switch ws?.active {
        case .textNote: NSCursor.iBeam.set()
        case .sign where !(ws?.strokes.isEmpty ?? true): NSCursor.crosshair.set()
        default: break
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let ws: PDFWorkspace

    func makeCoordinator() -> Coordinator { Coordinator(ws: ws) }

    func makeNSView(context: Context) -> OrcaPDFView {
        let v = OrcaPDFView()
        v.ws = ws
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.autoScales = false
        v.pageShadowsEnabled = true
        v.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x0E1116) : NSColor(hex: 0xF1F1F1)
        }
        v.document = ws.doc
        ws.view = v
        if ws.current > 0, let p = ws.doc?.page(at: ws.current) { v.go(to: p) }
        ws.applyGrayPreview()
        context.coordinator.watch(v)
        return v
    }

    func updateNSView(_ v: OrcaPDFView, context: Context) {
        if v.document !== ws.doc {
            v.document = ws.doc
            if let p = ws.doc?.page(at: ws.current) { v.go(to: p) }
            ws.applyGrayPreview()
        }
        if ws.view !== v { ws.view = v }
    }

    static func dismantleNSView(_ v: OrcaPDFView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        let ws: PDFWorkspace
        private var tokens: [NSObjectProtocol] = []
        init(ws: PDFWorkspace) { self.ws = ws }

        func watch(_ v: OrcaPDFView) {
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak self, weak v] _ in
                MainActor.assumeIsolated {
                    guard let v, let page = v.currentPage, let doc = v.document else { return }
                    self?.ws.pageChanged(to: doc.index(for: page))
                }
            })
            tokens.append(nc.addObserver(forName: .PDFViewSelectionChanged, object: v, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ws.selectionChanged() }
            })
            // Typing into a form field happens in a text view PDFKit puts inside the page.
            tokens.append(nc.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self, weak v] n in
                MainActor.assumeIsolated {
                    guard let v, let t = n.object as? NSView, t.isDescendant(of: v) else { return }
                    self?.ws.formTyped()
                }
            })
        }

        func stop() { tokens.forEach(NotificationCenter.default.removeObserver); tokens = [] }
    }
}

// MARK: - Page rail

struct PageRail: View {
    @Bindable var ws: PDFWorkspace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(ws.pages.enumerated()), id: \.element) { i, page in
                        PageThumb(ws: ws, page: page, index: i, width: 78, selected: ws.selected.contains(i), current: ws.current == i)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let f = NSEvent.modifierFlags
                                ws.tapPage(i, command: f.contains(.command), shift: f.contains(.shift))
                            }
                            .handCursor()
                            .help("Page \(i + 1) · ⌘-click to pick more")
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onChange(of: ws.current) { _, c in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(c) } }
        }
        .background(DS.surface)
    }
}

struct PageThumb: View {
    let ws: PDFWorkspace
    let page: PDFPage
    let index: Int
    let width: CGFloat
    let selected: Bool
    let current: Bool
    @State private var image: NSImage?

    var body: some View {
        let height = (width * ws.aspect(page)).rounded()
        VStack(spacing: 5) {
            ZStack {
                Color.white
                if let image { Image(nsImage: image).resizable().interpolation(.high) }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(current && !selected ? DS.borderStrong : DS.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? DS.focus : .clear, lineWidth: 2))
            Text("\(index + 1)").font(DS.caption)
                .foregroundStyle(selected ? DS.focus : current ? DS.text : DS.text2)
        }
        .task(id: "\(ws.revision)-\(ObjectIdentifier(page).hashValue)-\(Int(width))") {
            await Task.yield()
            guard !Task.isCancelled else { return }
            image = ws.thumbnail(page, width: width)
        }
    }
}

// MARK: - Reorder: every page in a grid you drag around

struct ReorderGrid: View {
    @Bindable var ws: PDFWorkspace
    @State private var dragging: PDFPage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    PixelLabel("Drag pages to change the order")
                    Spacer()
                    Text(Fmt.plural(ws.order.count, "page")).font(DS.caption).foregroundStyle(DS.text2)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126, maximum: 150), spacing: 20)], spacing: 20) {
                    ForEach(Array(ws.order.enumerated()), id: \.element) { i, page in
                        PageThumb(ws: ws, page: page, index: i, width: 112, selected: dragging == page, current: false)
                            .opacity(dragging == page ? 0.45 : 1)
                            .onDrag {
                                dragging = page
                                return NSItemProvider(object: "\(i)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDrop(page: page, ws: ws, dragging: $dragging))
                            .handCursor()
                    }
                }
            }
            .padding(28)
        }
        .onDrop(of: [.text], delegate: ReorderDrop(page: nil, ws: ws, dragging: $dragging))
        .onChange(of: ws.revision) { _, _ in dragging = nil }
    }
}

private struct ReorderDrop: DropDelegate {
    let page: PDFPage?
    let ws: PDFWorkspace
    @Binding var dragging: PDFPage?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, let page, d != page else { return }
        withAnimation(.snappy(duration: 0.22)) { ws.movePage(d, before: page) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        ws.commitOrder()
        return true
    }
}

// MARK: - Sidebar options box

struct PDFOptions: View {
    @Bindable var ws: PDFWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if ws.doc == nil {
                OptTitle(ws.item.name)
                OptHint("This PDF can’t be opened. It may be damaged.")
            } else if ws.locked {
                OptTitle("Locked PDF")
                OptHint("Type the password to open it.")
                UnlockField(ws: ws)
            } else {
                switch ws.active {
                case nil: about
                case .reorderPages: reorder
                case .splitPDF: split
                case .cropMargins: crop
                case .pdfCopyText: copyText
                case .findInPDF: PDFFindOptions(ws: ws)
                case .highlight: highlight
                case .textNote: textBox
                case .fillForms: forms
                case .sign: sign
                case .pdfTranslate: translate
                case .compressPDF: compress
                case .pdfToImages: images
                case .password: password
                default: OptHint(ws.active!.hint)
                }
            }
        }
    }

    // About the file

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            OptTitle(ws.item.name)
            OptRow("Pages", Fmt.count(ws.pageCount))
            OptRow("File", Fmt.size(ws.item.size))
            if let s = pageSize { OptRow("Page size", s) }
            OptRow("Text", looksScanned ? "None, looks scanned" : "Selectable")
            if ws.formFields > 0 { OptRow("Form", Fmt.plural(ws.formFields, "field")) }
            if ws.wasEncrypted { OptRow("Password", "Yes") }
            if !ws.selected.isEmpty {
                Divider().padding(.vertical, 2)
                HStack {
                    Text("\(Fmt.plural(ws.selected.count, "page")) picked").font(DS.caption).foregroundStyle(DS.focus)
                    Spacer()
                    Button("Clear") { ws.clearSelection() }.buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.text2).handCursor()
                }
                OptHint("Rotate, Delete and Extract work on the picked pages.")
            } else {
                OptHint("Click a page on the right to pick it; ⌘-click or ⇧-click for more.")
            }
        }
    }

    private var pageSize: String? {
        guard let p = ws.pages.first else { return nil }
        let b = p.bounds(for: .mediaBox).size
        let w = min(b.width, b.height), h = max(b.width, b.height)
        if abs(w - 612) < 3 && abs(h - 792) < 3 { return "Letter" }
        if abs(w - 595) < 3 && abs(h - 842) < 3 { return "A4" }
        if abs(w - 612) < 3 && abs(h - 1008) < 3 { return "Legal" }
        return String(format: "%.0f × %.0f mm", b.width / 72 * 25.4, b.height / 72 * 25.4)
    }

    private var looksScanned: Bool {
        let first = ws.pages.prefix(3)
        return !first.isEmpty && first.allSatisfy(PDFEngine.isImageOnly)
    }

    // Pages

    private var reorder: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Reorder pages")
            OptHint("Drag pages to change the order")
            HStack(spacing: 6) {
                OptButton("Done", symbol: "checkmark", primary: true) { ws.select(.reorderPages) }
                if ws.order != ws.pages { OptButton("Put back", symbol: "arrow.uturn.backward") { ws.undo() } }
            }
        }
    }

    private var split: some View {
        let runs = PDFEngine.runs(pageCount: ws.pageCount, every: ws.splitEvery)
        return VStack(alignment: .leading, spacing: 9) {
            OptTitle("Split")
            OptChoice(options: ["Every page", "Every few"], selection: ws.splitEvery == 1 ? "Every page" : "Every few") {
                ws.splitEvery = $0 == "Every page" ? 1 : max(2, min(ws.splitEvery, ws.pageCount))
            }
            if ws.splitEvery > 1 {
                Stepper(value: $ws.splitEvery, in: 2...max(2, ws.pageCount)) {
                    Text("Every \(ws.splitEvery) pages").font(DS.caption).foregroundStyle(DS.text)
                }
                .controlSize(.small)
            }
            OptHint(runs.count > 1 ? "Makes \(Fmt.plural(runs.count, "PDF")) in a folder next to the original." : "That keeps every page in one file.")
            OptButton("Split into \(runs.count) files", symbol: "scissors", primary: true) { ws.split(every: ws.splitEvery) }
                .disabled(runs.count < 2).opacity(runs.count < 2 ? 0.5 : 1)
        }
    }

    private var crop: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Crop margins")
            OptChoice(options: ["All pages", "Picked"], selection: ws.cropAll ? "All pages" : "Picked") { ws.cropAll = $0 == "All pages" }
            if !ws.cropAll {
                OptCaption(ws.selected.isEmpty ? "Page \(ws.current + 1), the one on screen" : Fmt.plural(ws.selected.count, "picked page"))
            }
            OptHint("Trims the empty space around what’s on each page. Nothing is thrown away; ⌘Z puts it back.")
            OptButton("Crop margins", symbol: "crop", primary: true) {
                ws.cropMargins(ws.cropAll ? Array(0..<ws.pageCount) : ws.targets)
            }
        }
    }

    // Text & marks

    private var copyText: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Copy text")
            if !ws.hasText {
                OptHint("No text in this PDF. It may be a scan; making scans searchable is coming later.")
            } else {
                OptButton("Copy all text", symbol: "doc.on.doc", primary: true) { ws.copyAllText() }
                OptButton("Copy selected text", symbol: "text.cursor") { ws.copySelectedText() }
                    .disabled(ws.selectionText.isEmpty).opacity(ws.selectionText.isEmpty ? 0.5 : 1)
                OptHint(ws.selectionText.isEmpty ? "Select words on the page, then copy them here or press ⌘C." : "\(Fmt.plural(ws.selectionText.count, "character")) selected.")
            }
        }
    }

    private var highlight: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Highlight")
            HStack(spacing: 8) {
                ForEach(PDFWorkspace.Marker.allCases, id: \.self) { m in
                    Button { ws.marker = m } label: {
                        Circle().fill(Color(nsColor: m.color.withAlphaComponent(1))).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(DS.borderStrong, lineWidth: 1))
                            .padding(2)
                            .overlay(Circle().strokeBorder(ws.marker == m ? DS.focus : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain).handCursor().help(m.rawValue)
                }
            }
            if ws.hasText {
                OptHint("Select text on the page. It’s marked as soon as you let go.")
            } else {
                OptHint("This PDF has no selectable text, so there’s nothing to highlight. It may be a scan.")
            }
            if ws.highlightCount > 0 { OptCaption("\(Fmt.plural(ws.highlightCount, "mark")) so far · ⌘Z to undo") }
        }
    }

    private var textBox: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Text box")
            if ws.editingNote {
                TextField("Type here", text: $ws.noteText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5).font(.system(size: 12))
                OptChoice(options: ["Small", "Medium", "Large"], selection: ws.noteSize < 12 ? "Small" : ws.noteSize < 18 ? "Medium" : "Large") {
                    ws.noteSize = $0 == "Small" ? 10 : $0 == "Medium" ? 14 : 20
                }
                HStack(spacing: 6) {
                    OptButton("Done", symbol: "checkmark", primary: true) { ws.finishNote() }
                    OptButton("Delete", symbol: "trash") { ws.deleteNote() }
                }
                OptHint("Click another spot for a new box, or an old box to change it.")
            } else {
                OptHint("Click the page where the text should go, then type here.")
            }
        }
    }

    private var forms: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Fill in forms")
            if ws.formFields == 0 {
                OptHint("No form fields in this PDF. Use Text box to type on it anyway.")
                OptButton("Use Text box", symbol: ToolID.textNote.symbol) { ws.select(.textNote) }
            } else {
                OptRow("Fields", Fmt.count(ws.formFields))
                OptHint("Click a field on the page and type. Tab moves to the next one. What you fill in goes into the copy.")
            }
        }
    }

    private var sign: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Sign")
            SignaturePad(ws: ws)
            HStack(spacing: 6) {
                OptButton("Place", symbol: "signature", primary: true) { ws.placeSignature() }
                    .disabled(ws.strokes.isEmpty).opacity(ws.strokes.isEmpty ? 0.5 : 1)
                OptButton("Clear", symbol: "eraser") { ws.strokes = []; ws.liveStroke = [] }
            }
            OptHint(ws.strokes.isEmpty ? "Draw your signature in the box with the trackpad or mouse."
                                       : "Click the page where it goes, or Place puts it low on page \(ws.current + 1).")
        }
    }

    @ViewBuilder
    private var translate: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Translate")
            if !ws.hasText && ws.selectionText.isEmpty {
                OptHint("No text to translate. It may be a scan.")
            } else if #available(macOS 14.4, *) {
                OptButton(ws.selectionText.isEmpty ? "Translate the text" : "Translate the selection", symbol: "translate", primary: true) { ws.showTranslation = true }
                    .translationPresentation(isPresented: $ws.showTranslation, text: ws.translationSource)
                OptHint(ws.selectionText.isEmpty ? "Select words on the page to translate just those. Otherwise it’s the start of the document."
                                                 : "Uses Apple’s translation. Languages download once, then it works offline.")
            } else {
                OptHint("Translation needs macOS 14.4 or later.")
            }
        }
    }

    // Save as

    private var compress: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Compress")
            OptChoice(options: PDFSqueeze.allCases.map(\.rawValue), selection: (ws.squeeze ?? .smaller).rawValue) { ws.squeeze = PDFSqueeze(rawValue: $0) }
            OptHint(ws.squeeze == .smallest ? "Also turns scanned pages into lighter pictures. Text pages stay sharp."
                                            : "Shrinks the pictures inside. Text stays sharp and selectable.")
            Divider()
            Text(ws.estimate.map { "About \(Fmt.size($0))" } ?? "Working it out…").font(DS.headingSM).foregroundStyle(DS.text)
            OptCaption("was \(Fmt.size(ws.item.size)) · Save copy in the top bar")
            if let e = ws.estimate, Double(e) > Double(ws.item.size) * 0.95 {
                OptHint("This PDF is already about as small as it gets.")
            }
        }
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Save as images")
            OptChoice(options: PDFEngine.ImageKind.allCases.map(\.rawValue), selection: ws.imageKind.rawValue) { ws.imageKind = PDFEngine.ImageKind(rawValue: $0)! }
            OptCaption("Sharpness")
            OptChoice(options: ["72", "150", "300"], selection: "\(ws.imageDPI)") { ws.imageDPI = Int($0) ?? 150 }
            OptHint(ws.imageDPI == 72 ? "Screen size, small files." : ws.imageDPI == 150 ? "Sharp on screen, fine to print." : "For print. Big files.")
            OptButton("Save \(Fmt.plural(ws.pageCount, "picture"))", symbol: "photo.stack", primary: true) { ws.saveImages() }
                .disabled(ws.busy != nil)
            OptCaption("Into a folder next to the original")
        }
    }

    private var password: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Password")
            if ws.wasEncrypted {
                Toggle(isOn: $ws.removePassword) { Text("Remove the password").font(DS.bodySM) }
                    .toggleStyle(.switch).controlSize(.mini)
            }
            if !ws.removePassword {
                SecureField(ws.wasEncrypted ? "New password" : "Password", text: $ws.newPassword).textFieldStyle(.roundedBorder).controlSize(.small)
                SecureField("Type it again", text: $ws.confirmPassword).textFieldStyle(.roundedBorder).controlSize(.small)
                if ws.passwordMismatch {
                    Text("The two don’t match").font(DS.caption).foregroundStyle(DS.critical)
                } else if !ws.newPassword.isEmpty && ws.newPassword == ws.confirmPassword {
                    OptCaption("Save copy in the top bar to lock it")
                }
                OptHint("Anyone opening the copy will need it. Orca can’t get it back if you forget it.")
            } else {
                OptHint("The copy opens without a password. The original keeps its lock.")
            }
        }
    }
}

struct UnlockField: View {
    @Bindable var ws: PDFWorkspace
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SecureField("Password", text: $ws.unlockText).textFieldStyle(.roundedBorder).controlSize(.small)
                    .focused($focused).onSubmit { ws.unlock() }
                OptButton("Unlock", symbol: "lock.open", primary: true) { ws.unlock() }
            }
            if ws.unlockFailed { Text("That’s not it. Try again.").font(DS.caption).foregroundStyle(DS.critical) }
        }
        .onAppear { focused = true }
    }
}

struct PDFFindOptions: View {
    @Bindable var ws: PDFWorkspace
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Find")
            TextField("Find in this PDF", text: $ws.query)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .focused($focused)
                .onSubmit { if let h = ws.hits.first(where: { $0.id > (ws.focusedHit ?? -1) }) ?? ws.hits.first { ws.showHit(h) } }
            if ws.query.trimmingCharacters(in: .whitespaces).isEmpty {
                OptHint("Every match is marked on the pages. Click one to jump to it.")
            } else if ws.hitCount == 0 {
                OptHint("No matches")
            } else {
                HStack {
                    OptCaption(ws.hitCount > ws.hits.count ? "\(Fmt.count(ws.hitCount)) matches · first \(ws.hits.count)" : Fmt.plural(ws.hitCount, "match", "matches"))
                    Spacer()
                    Button { ws.highlightAllHits() } label: {
                        Label("Highlight all", systemImage: "highlighter").font(DS.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(DS.link).handCursor()
                    .help("Mark every match in the file")
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ws.hits.prefix(60)) { h in
                        Button { ws.showHit(h) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("p.\(h.page + 1)").font(DS.caption).foregroundStyle(DS.text2).frame(width: 34, alignment: .leading)
                                Text(h.context).font(.system(size: 11)).foregroundStyle(DS.text).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(ws.focusedHit == h.id ? DS.tertiary : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).handCursor()
                    }
                }
            }
        }
        .onAppear { focused = true }
    }
}

/// A small pad to draw a signature on.
struct SignaturePad: View {
    @Bindable var ws: PDFWorkspace

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white)
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1).padding(.horizontal, 14).offset(y: 22)
            if ws.strokes.isEmpty && ws.liveStroke.isEmpty {
                Text("Sign here").font(DS.caption).foregroundStyle(Color.black.opacity(0.3))
            }
            Canvas { ctx, _ in
                for s in ws.strokes + [ws.liveStroke] where !s.isEmpty {
                    var p = Path()
                    p.move(to: s[0])
                    if s.count == 1 { p.addLine(to: CGPoint(x: s[0].x + 0.5, y: s[0].y)) }
                    for pt in s.dropFirst() { p.addLine(to: pt) }
                    ctx.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 84)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in ws.liveStroke.append(g.location) }
            .onEnded { _ in
                if !ws.liveStroke.isEmpty { ws.strokes.append(ws.liveStroke) }
                ws.liveStroke = []
            })
        .onHover { $0 ? NSCursor.crosshair.set() : NSCursor.arrow.set() }
    }
}
