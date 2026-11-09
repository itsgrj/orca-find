import SwiftUI
import AppKit
import CoreImage

/// Photos and screenshots. Works like Paint: each tool changes the current picture, with ⌘Z to step back.
/// Tools with settings (remove background, adjust, crop) show a live result and are applied when you
/// pick another tool or save.
@MainActor
@Observable
final class PictureWorkspace: EditWorkspace {
    let item: FileItem
    let kind: EditKind
    let sourceProps: [String: Any]

    private(set) var original: CIImage?
    private(set) var working: CIImage?
    private struct Step { let image: CIImage; let label: String; let transparent: Bool }
    private var steps: [Step] = []
    private(set) var active: ToolID?
    private(set) var busy: String?

    // What's on screen
    private(set) var display: NSImage?
    @ObservationIgnored private(set) var displayCG: CGImage?
    @ObservationIgnored private var renderGen = 0
    private(set) var hasTransparency = false

    // Remove background
    private(set) var subjects: ImageEngine.Subjects?
    private(set) var chosen = IndexSet()
    private var mask: CIImage?
    var behind: ImageEngine.Behind = .clear { didSet { refresh() } }

    // Adjust
    var adj = ImageEngine.Adjustments() { didSet { refresh() } }
    private(set) var lookThumbs: [String: NSImage] = [:]

    // Crop
    enum Aspect: String, CaseIterable { case free = "Free", original = "Same", square = "1:1", fourThree = "4:3", sixteenNine = "16:9" }
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var aspect: Aspect = .free { didSet { applyAspect() } }
    var straighten: Double = 0 { didSet { refresh() } }

    // Select, draw, redact
    var selection: CGRect?
    var penColor = NSColor(hex: 0xE5484D)
    var backColor = NSColor.white
    var penWidth: CGFloat = 0.005
    var textSize: CGFloat = 0.035
    var liveMark: ImageEngine.Mark?
    var dragRect: CGRect?
    var textDraft: (point: CGPoint, text: String)?
    var redactStyle: ImageEngine.RedactStyle = .pixelate
    var redactBlock: Double = 12
    var zoom: Double = 1

    // Erase an object
    var eraseModel: Eraser.Model = Eraser.available.first ?? .best
    var eraseBrush: Double = 0.045
    private(set) var eraseLive: [CGPoint] = []

    // Saving
    var export = ImageEngine.ExportSettings() { didSet { exportTouched = true; scheduleEstimate() } }
    private(set) var exportTouched = false
    private(set) var estimate: String?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?

    // Text
    private(set) var recognized: String?
    var showTranslation = false

    init(item: FileItem, kind: EditKind) {
        self.item = item
        self.kind = kind
        self.sourceProps = ImageEngine.properties(item.url)
        if let img = ImageEngine.load(item.url) {
            let n = ImageEngine.normalize(img)
            original = n; working = n
        }
        export = ImageEngine.ExportSettings()
        exportTouched = false
        refresh()
    }

    // MARK: Tool lists

    var bar: [ToolID] {
        kind == .screenshot ? [.copyText, .redact, .pen, .crop] : [.removeBackground, .crop, .adjust, .convert]
    }

    var groups: [ToolGroup] {
        if kind == .screenshot {
            return [ToolGroup(title: "Text", tools: [.copyText, .translate, .zoom]),
                    ToolGroup(title: "Draw", tools: [.pen, .highlighter, .text, .arrow, .shape, .redact, .pipette]),
                    ToolGroup(title: "Cut", tools: [.crop, .selectArea, .removeBackground, .rotate]),
                    ToolGroup(title: "Save as", tools: [.convert, .resize, .compress, .stripLocation])]
        }
        return [ToolGroup(title: "Cut & select", tools: [.removeBackground, .selectArea, .crop, .eraseObject]),
                ToolGroup(title: "Draw", tools: [.pen, .highlighter, .text, .arrow, .shape, .redact, .pipette, .zoom]),
                ToolGroup(title: "Fix", tools: [.enhance, .adjust, .rotate, .flip]),
                ToolGroup(title: "Save as", tools: [.convert, .resize, .compress, .stripLocation])]
    }

    func barTitle(_ tool: ToolID) -> String {
        switch tool {
        case .pen where kind == .screenshot: return "Mark up"
        case .convert: return "Convert & resize"
        default: return tool.title
        }
    }

    func isAvailable(_ tool: ToolID) -> Bool { original != nil && (tool != .eraseObject || !Eraser.available.isEmpty) }

    // MARK: State

    var canUndo: Bool { !steps.isEmpty || hasPending }

    private var hasPending: Bool {
        switch active {
        case .removeBackground: return mask != nil
        case .adjust: return !adj.isNeutral
        case .crop: return cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) || straighten != 0
        default: return false
        }
    }

    var hasEdits: Bool { !steps.isEmpty || hasPending || exportTouched }

    private var labels: [String] {
        var l = steps.map(\.label)
        if hasPending, let a = active { l.append(pendingLabel(a)) }
        var seen = Set<String>()
        return l.filter { seen.insert($0).inserted }
    }

    private func pendingLabel(_ t: ToolID) -> String {
        switch t {
        case .removeBackground: return "no background"
        case .adjust: return "adjusted"
        case .crop: return "cropped"
        default: return "edited"
        }
    }

    var status: String? {
        guard hasEdits else { return nil }
        let (fmt, _) = outputFormat()
        let name = CopySaver.destination(near: item.url, suffix: suffix(), ext: fmt.ext).lastPathComponent
        let what = labels.isEmpty ? (exportTouched ? "Save a copy" : "") : labels.joined(separator: " · ").capitalizedFirst
        return "\(what) · will save as \(name)"
    }

    // MARK: Picking tools

    func select(_ tool: ToolID) {
        guard isAvailable(tool), working != nil else { return }
        switch tool {
        case .enhance:
            commitPending()
            apply("enhanced") { ImageEngine.autoEnhance($0) }
            EditToastCenter.shared.show("Enhanced · ⌘Z to undo")
            return
        case .rotate:
            commitPending(); apply("rotated") { ImageEngine.rotateLeft($0) }; return
        case .flip:
            commitPending(); apply("flipped") { ImageEngine.flip($0) }; return
        default: break
        }
        if active == tool { commitPending(); active = nil; refresh(); return }
        commitPending()
        active = tool
        enter(tool)
        refresh()
    }

    private func enter(_ tool: ToolID) {
        selection = nil; dragRect = nil; liveMark = nil; textDraft = nil
        switch tool {
        case .removeBackground: findSubjects()
        case .adjust: adj = ImageEngine.Adjustments(); makeLookThumbs()
        case .crop: cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); straighten = 0; aspect = .free
        case .copyText, .translate: readText()
        case .convert, .resize, .compress, .stripLocation:
            if export.format == .original { export.format = defaultFormat }
            exportTouched = true
            scheduleEstimate()
        default: break
        }
    }

    private var defaultFormat: ImageEngine.Format {
        if hasTransparency { return .png }
        return ImageEngine.Format.from(ext: item.ext) ?? .jpeg
    }

    /// Bakes whatever the active tool is showing into the picture.
    private func commitPending() {
        guard hasPending, let a = active, let w = working else { return }
        switch a {
        case .removeBackground:
            if let m = mask {
                let clear = behind == .clear
                push("no background")
                working = ImageEngine.cutOut(w, mask: m, behind: behind)
                hasTransparency = clear || hasTransparency
            }
            mask = nil; subjects = nil
        case .adjust:
            push("adjusted")
            working = ImageEngine.adjust(w, adj)
            adj = ImageEngine.Adjustments()
        case .crop:
            push("cropped")
            working = ImageEngine.crop(ImageEngine.straighten(w, degrees: straighten), to: cropRect)
            cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); straighten = 0
        default: break
        }
    }

    private func push(_ label: String) {
        guard let w = working else { return }
        steps.append(Step(image: w, label: label, transparent: hasTransparency))
    }

    private func apply(_ label: String, _ f: (CIImage) -> CIImage) {
        guard let w = working else { return }
        push(label)
        working = f(w)
        refresh()
    }

    func undo() {
        if hasPending {
            switch active {
            case .removeBackground: mask = nil; behind = .clear; if let s = subjects { chosen = s.all }
            case .adjust: adj = ImageEngine.Adjustments()
            case .crop: cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); straighten = 0
            default: break
            }
            if active == .removeBackground { active = nil }
            refresh(); return
        }
        guard let last = steps.popLast() else { return }
        working = last.image
        hasTransparency = last.transparent
        refresh()
    }

    func discard() {
        steps.removeAll(); working = original; active = nil; mask = nil; subjects = nil
        adj = ImageEngine.Adjustments(); hasTransparency = false; selection = nil
        export = ImageEngine.ExportSettings(); exportTouched = false; estimate = nil
        refresh()
    }

    // MARK: Rendering what's on screen

    /// The picture with the active tool's live settings.
    private func previewImage() -> CIImage? {
        guard let w = working else { return nil }
        switch active {
        case .removeBackground: if let m = mask { return ImageEngine.cutOut(w, mask: m, behind: behind) }
        case .adjust: return ImageEngine.adjust(w, adj)
        case .crop: return ImageEngine.straighten(w, degrees: straighten)
        default: break
        }
        return w
    }

    var showsCheckerboard: Bool { hasTransparency || (active == .removeBackground && mask != nil && behind == .clear) }

    /// Live Text works on the untouched file, so it's used until the first edit.
    var usesLiveText: Bool { steps.isEmpty && !hasPending && (active == nil || active == .copyText || active == .translate) }

    var pixelSize: CGSize { working?.extent.size ?? .zero }

    func refresh() {
        guard let img = previewImage() else { display = nil; return }
        renderGen += 1
        let gen = renderGen
        Task.detached(priority: .userInitiated) { [img] in
            let cg = ImageEngine.cgImage(img, maxSide: 2400)
            await MainActor.run {
                guard gen == self.renderGen, let cg else { return }
                self.displayCG = cg
                self.display = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    // MARK: Remove background

    private func findSubjects() {
        guard let w = working else { return }
        busy = "Finding the subject…"
        Task {
            do {
                let s = try await ImageEngine.findSubjects(w)
                guard active == .removeBackground else { busy = nil; return }
                subjects = s; chosen = s.all
                mask = s.mask(s.all)
                busy = nil
                refresh()
            } catch {
                busy = nil
                active = nil
                EditToastCenter.shared.show(error.localizedDescription)
                refresh()
            }
        }
    }

    /// Click a subject to keep only it; click again to bring the others back.
    func toggleSubject(at p: CGPoint) {
        guard let s = subjects, s.all.count > 1, let i = s.instance(at: p) else { return }
        if chosen == s.all { chosen = IndexSet(integer: i) }
        else if chosen.contains(i) { chosen.remove(i); if chosen.isEmpty { chosen = s.all } }
        else { chosen.insert(i) }
        mask = s.mask(chosen)
        refresh()
    }

    var subjectCount: Int { subjects?.all.count ?? 0 }

    func copyCutout(sticker: Bool) {
        guard let w = working, let m = mask else { return }
        var cut = ImageEngine.cutOut(w, mask: m, behind: .clear)
        if sticker { cut = ImageEngine.sticker(cut) }
        guard let png = ImageEngine.pngData(cut) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        EditToastCenter.shared.show(sticker ? "Sticker copied · paste it into Messages, Keynote or Figma" : "Subject copied · paste it anywhere")
    }

    // MARK: Adjust

    private func makeLookThumbs() {
        guard let w = working, lookThumbs.isEmpty else { return }
        Task.detached(priority: .utility) { [w] in
            let small = ImageEngine.scaled(w, maxSide: 160)
            var out: [String: NSImage] = [:]
            for l in ImageEngine.looks {
                let img = l.filter.map { ImageEngine.applyLook(small, $0) } ?? small
                if let ns = ImageEngine.nsImage(img) { out[l.name] = ns }
            }
            let thumbs = out
            await MainActor.run { self.lookThumbs = thumbs }
        }
    }

    func applyEnhanceInAdjust() {
        guard let w = working else { return }
        commitPending()
        push("enhanced")
        working = ImageEngine.autoEnhance(w)
        refresh()
    }

    // MARK: Crop

    private func ratio(_ a: Aspect) -> CGFloat? {
        let s = pixelSize
        switch a {
        case .free: return nil
        case .original: return s.height > 0 ? s.width / s.height : nil
        case .square: return 1
        case .fourThree: return s.width >= s.height ? 4.0 / 3.0 : 3.0 / 4.0
        case .sixteenNine: return s.width >= s.height ? 16.0 / 9.0 : 9.0 / 16.0
        }
    }

    /// Ratio expressed in 0…1 space (width / height of the normalised rect).
    private var normalizedRatio: CGFloat? {
        guard let r = ratio(aspect), pixelSize.width > 0 else { return nil }
        return r * pixelSize.height / pixelSize.width
    }

    private func applyAspect() {
        guard let nr = normalizedRatio else { return }
        var w: CGFloat = 1, h = 1 / nr
        if h > 1 { h = 1; w = nr }
        cropRect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Drag a corner (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right) or the middle (−1) of the crop box.
    func dragCrop(handle: Int, from start: CGRect, by d: CGSize) {
        var r = start
        let minSide: CGFloat = 0.05
        if handle == -1 {
            r.origin.x = min(max(0, start.minX + d.width), 1 - start.width)
            r.origin.y = min(max(0, start.minY + d.height), 1 - start.height)
            cropRect = r; return
        }
        let fixed = CGPoint(x: handle % 2 == 0 ? start.maxX : start.minX, y: handle < 2 ? start.maxY : start.minY)
        let moving = CGPoint(x: (handle % 2 == 0 ? start.minX : start.maxX) + d.width, y: (handle < 2 ? start.minY : start.maxY) + d.height)
        var x0 = min(max(0, min(fixed.x, moving.x)), 1), x1 = max(min(1, max(fixed.x, moving.x)), 0)
        var y0 = min(max(0, min(fixed.y, moving.y)), 1), y1 = max(min(1, max(fixed.y, moving.y)), 0)
        if x1 - x0 < minSide { if moving.x < fixed.x { x0 = x1 - minSide } else { x1 = x0 + minSide } }
        if y1 - y0 < minSide { if moving.y < fixed.y { y0 = y1 - minSide } else { y1 = y0 + minSide } }
        r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let nr = normalizedRatio {
            let h = r.width / nr
            if h <= 1 { r.size.height = h; if handle < 2 { r.origin.y = fixed.y - h } } else { r.size.height = 1; r.size.width = nr; r.origin.y = 0 }
            r.origin.y = min(max(0, r.origin.y), 1 - r.height)
            r.origin.x = min(max(0, r.origin.x), 1 - r.width)
        }
        cropRect = r
    }

    func resetCrop() { cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); straighten = 0; aspect = .free }

    func applyCropNow() { commitPending(); active = nil; refresh() }

    // MARK: Select area

    func cropToSelection() {
        guard let s = selection else { return }
        apply("cropped") { ImageEngine.crop($0, to: s) }
        selection = nil
    }

    func redactSelection() {
        guard let s = selection else { return }
        apply("redacted") { ImageEngine.redact($0, s, style: redactStyle, block: redactBlock) }
        selection = nil
    }

    func copySelection() {
        guard let s = selection, let w = working, let png = ImageEngine.pngData(ImageEngine.crop(w, to: s)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        EditToastCenter.shared.show("Copied the selected area")
    }

    // MARK: Drawing on the picture (each stroke is applied straight away, like Paint)

    func beginDrag(at p: CGPoint) {
        if active == .eraseObject { if busy == nil { eraseLive = [p] }; return }
        switch active {
        case .pen, .highlighter: liveMark = ImageEngine.Mark(kind: active == .pen ? .pen : .highlighter, points: [p], color: penColor, width: penWidth)
        case .arrow: liveMark = ImageEngine.Mark(kind: .arrow, points: [p, p], color: penColor, width: penWidth)
        case .shape: liveMark = ImageEngine.Mark(kind: .box, points: [p, p], color: penColor, width: penWidth)
        case .redact, .selectArea: dragRect = CGRect(origin: p, size: .zero)
        default: break
        }
    }

    func moveDrag(from start: CGPoint, to p: CGPoint) {
        let p = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        if active == .eraseObject { if !eraseLive.isEmpty { eraseLive.append(p) }; return }
        switch active {
        case .pen, .highlighter: liveMark?.points.append(p)
        case .arrow, .shape: if liveMark != nil { liveMark!.points[1] = p }
        case .redact, .selectArea: dragRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        default: break
        }
    }

    func endDrag(at p: CGPoint) {
        if active == .eraseObject { runErase(); return }
        switch active {
        case .pen, .highlighter, .arrow, .shape:
            if let m = liveMark {
                let tiny = (m.kind == .arrow || m.kind == .box) && hypot(m.points[0].x - m.points[1].x, m.points[0].y - m.points[1].y) < 0.01
                if !tiny { apply("marked up") { ImageEngine.draw([m], onto: $0) } }
            }
            liveMark = nil
        case .redact:
            if let r = dragRect, r.width > 0.005, r.height > 0.005 { apply("redacted") { ImageEngine.redact($0, r, style: redactStyle, block: redactBlock) } }
            dragRect = nil
        case .selectArea:
            if let r = dragRect, r.width > 0.005, r.height > 0.005 { selection = r } else { selection = nil }
            dragRect = nil
        case .text:
            textDraft = (p, "")
        case .pipette:
            if let cg = displayCG, let c = ImageEngine.color(at: p, in: cg) { penColor = c; active = .pen }
        case .removeBackground:
            toggleSubject(at: p)
        case .zoom:
            zoom = zoom >= 3 ? 1 : zoom * 2
        default: break
        }
    }

    func commitText() {
        guard let d = textDraft else { return }
        textDraft = nil
        let t = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let m = ImageEngine.Mark(kind: .text, points: [d.point], color: penColor, width: penWidth, text: t, fontSize: textSize)
        apply("marked up") { ImageEngine.draw([m], onto: $0) }
    }

    // MARK: Erase an object

    private func runErase() {
        let stroke = eraseLive
        if !Eraser.isAvailable(eraseModel) {
            eraseLive = []
            EditToastCenter.shared.show(eraseModel == .best ? "Unlock the Pro eraser first, or switch to Quick" : "The eraser isn’t installed")
            return
        }
        guard !stroke.isEmpty, busy == nil, let w = working,
              let mask = Eraser.mask(strokes: [(stroke, CGFloat(eraseBrush))], size: w.extent.size) else { eraseLive = []; return }
        let model = eraseModel
        busy = "Erasing…"
        Task {
            do {
                let flat = try await Task.detached(priority: .userInitiated) { [w] () -> CIImage in
                    let r = try Eraser.erase(w, mask: mask, using: model)
                    // Flatten so later edits don't run the model's recipe again.
                    guard let cg = ImageEngine.cgImage(r) else { throw EditError.message("Couldn’t draw the result") }
                    return CIImage(cgImage: cg)
                }.value
                push("erased")
                working = flat
                refresh()
            } catch {
                EditToastCenter.shared.show("Couldn’t erase: \(error.localizedDescription)")
            }
            eraseLive = []
            busy = nil
        }
    }

    // MARK: Text

    private func readText() {
        guard recognized == nil, let w = working else { return }
        busy = "Reading the text…"
        Task {
            let t = await ImageEngine.recognizeText(w)
            recognized = t
            busy = nil
        }
    }

    var lineCount: Int { recognized.map { $0.split(separator: "\n").count } ?? 0 }

    func copyAllText() {
        guard let t = recognized, !t.isEmpty else { EditToastCenter.shared.show("No text found in this picture"); return }
        FileActions.copyText(t)
        EditToastCenter.shared.show("Copied \(Fmt.plural(lineCount, "line")) of text")
    }

    // MARK: Saving

    private func outputFormat() -> (ImageEngine.Format, flattenOnWhite: Bool) {
        var f = export.format == .original ? defaultFormat : export.format
        if hasTransparency && !f.keepsTransparency && f != .pdf {
            if exportTouched && export.format != .original { return (f, true) }
            f = .png
        }
        return (f, false)
    }

    private func suffix() -> String? {
        let l = labels
        if l.isEmpty {
            let (fmt, _) = outputFormat()
            if fmt.ext != item.ext.lowercased() && !(fmt == .jpeg && item.ext.lowercased() == "jpeg") && export.maxSide == nil { return nil }
            if export.maxSide != nil || export.quality < 0.85 { return "smaller" }
            return export.stripLocation && ImageEngine.hasLocation(sourceProps) ? "no location" : "copy"
        }
        return l.count == 1 ? l[0] : "edited"
    }

    func save() async throws -> URL {
        commitPending()
        guard var img = working else { throw EditError.message("Nothing to save") }
        let (fmt, flatten) = outputFormat()
        if flatten { img = img.composited(over: CIImage(color: .white).cropped(to: img.extent)) }
        let dest = CopySaver.destination(near: item.url, suffix: suffix(), ext: fmt.ext)
        let settings = export, props = sourceProps
        let data = try await Task.detached(priority: .userInitiated) { [img] in
            try ImageEngine.encode(img, format: fmt, settings: settings, source: props)
        }.value
        try data.write(to: dest, options: .atomic)
        CopySaver.register(dest, like: item)
        return dest
    }

    func scheduleEstimate() {
        estimateTask?.cancel()
        guard let w = working else { return }
        let (fmt, _) = outputFormat()
        let settings = export, props = sourceProps
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .utility) { [w] in
                (try? ImageEngine.encode(w, format: fmt, settings: settings, source: props))?.count ?? 0
            }.value
            guard !Task.isCancelled else { return }
            estimate = bytes > 0 ? Fmt.size(Int64(bytes)) : nil
        }
    }

    var outputPixels: CGSize {
        let s = pixelSize
        guard let m = export.maxSide, max(s.width, s.height) > CGFloat(m) else { return s }
        let k = CGFloat(m) / max(s.width, s.height)
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    // MARK: Views

    func stage() -> AnyView { AnyView(PictureStage(ws: self)) }
    func options() -> AnyView { AnyView(PictureOptions(ws: self)) }
    func footer() -> AnyView? { AnyView(PaletteStrip(ws: self)) }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
