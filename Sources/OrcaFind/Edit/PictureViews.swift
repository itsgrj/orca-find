import SwiftUI
import AppKit
import Translation

// MARK: - The picture and everything drawn over it

struct PictureStage: View {
    @Bindable var ws: PictureWorkspace
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(in: CGSize(width: max(50, geo.size.width - 48), height: max(50, geo.size.height - 40)))
            let size = CGSize(width: fit.width * ws.zoom, height: fit.height * ws.zoom)
            ZStack {
                if ws.zoom > 1 {
                    ScrollView([.horizontal, .vertical]) { canvas(size).padding(24) }
                } else {
                    canvas(size).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if ws.original == nil {
                    EmptyState(symbol: "photo", tag: "Picture", title: "Can’t open this picture", message: "It may be damaged or in a format this Mac can’t read.")
                }
            }
        }
    }

    private func fitted(in avail: CGSize) -> CGSize {
        let px = ws.pixelSize
        guard px.width > 0, px.height > 0 else { return avail }
        let s = min(avail.width / px.width, avail.height / px.height, 2.5)
        return CGSize(width: (px.width * s).rounded(), height: (px.height * s).rounded())
    }

    private var pointerTools: Set<ToolID> { [.pen, .highlighter, .arrow, .shape, .redact, .selectArea, .text, .pipette, .removeBackground, .zoom] }

    @ViewBuilder
    private func canvas(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if ws.showsCheckerboard { Checkerboard().frame(width: size.width, height: size.height) }
            Group {
                if ws.usesLiveText {
                    LiveTextImage(url: ws.item.url, selectable: ws.active == .copyText || ws.active == nil, inset: 0)
                } else if let d = ws.display {
                    Image(nsImage: d).resizable().interpolation(.high)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(ws.showsCheckerboard ? 0 : 0.12), radius: 8, y: 2)
            overlays(size)
            if let a = ws.active, pointerTools.contains(a) {
                Color.clear.contentShape(Rectangle())
                    .frame(width: size.width, height: size.height)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { g in
                            let p = norm(g.location, size)
                            if dragStart == nil { dragStart = norm(g.startLocation, size); ws.beginDrag(at: dragStart!) }
                            ws.moveDrag(from: dragStart!, to: p)
                        }
                        .onEnded { g in
                            ws.endDrag(at: norm(g.location, size)); dragStart = nil
                        })
                    .onContinuousHover { phase in
                        if case .active = phase { cursor(for: a).set() } else { NSCursor.arrow.set() }
                    }
            }
            if ws.active == .crop { CropOverlay(ws: ws, size: size) }
            if let d = ws.textDraft { TextDraftField(ws: ws, size: size, point: d.point) }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func overlays(_ size: CGSize) -> some View {
        if let m = ws.liveMark {
            Canvas { ctx, sz in ctx.withCGContext { cg in ImageEngine.render([m], in: sz, ctx: cg) } }
                .frame(width: size.width, height: size.height).allowsHitTesting(false)
        }
        if let r = ws.dragRect ?? (ws.active == .selectArea ? ws.selection : nil) {
            let rect = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
            Rectangle().fill(ws.active == .redact ? Color.black.opacity(0.25) : Color.clear)
                .overlay(Rectangle().strokeBorder(DS.focus, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func norm(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }

    private func cursor(for t: ToolID) -> NSCursor {
        switch t {
        case .text: return .iBeam
        case .removeBackground, .zoom: return .pointingHand
        default: return .crosshair
        }
    }
}

struct Checkerboard: View {
    var dark = false
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            let a = Color(hex: 0xFFFFFF), b = Color(hex: 0xE4E4E7)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(a))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? s : 0
                while x < size.width { ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(b)); x += 2 * s }
                y += s; row += 1
            }
        }
    }
}

struct CropOverlay: View {
    @Bindable var ws: PictureWorkspace
    let size: CGSize
    @State private var start: CGRect?

    var body: some View {
        let r = ws.cropRect
        let rect = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(rect) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            // Thirds
            Path { p in
                for k in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(k) / 3, y = rect.minY + rect.height * CGFloat(k) / 3
                    p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 1).allowsHitTesting(false)
            Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .gesture(drag(-1))
                .onHover { $0 ? NSCursor.openHand.set() : NSCursor.arrow.set() }
            ForEach(0..<4, id: \.self) { h in
                let x = h % 2 == 0 ? rect.minX : rect.maxX, y = h < 2 ? rect.minY : rect.maxY
                CornerHandle(corner: h)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .offset(x: x - 13, y: y - 13)
                    .gesture(drag(h))
                    .onHover { $0 ? NSCursor.crosshair.set() : NSCursor.arrow.set() }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func drag(_ handle: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                if start == nil { start = ws.cropRect }
                ws.dragCrop(handle: handle, from: start!, by: CGSize(width: g.translation.width / size.width, height: g.translation.height / size.height))
            }
            .onEnded { _ in start = nil }
    }
}

private struct CornerHandle: View {
    let corner: Int
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let dx: CGFloat = corner % 2 == 0 ? 1 : -1, dy: CGFloat = corner < 2 ? 1 : -1
            var p = Path()
            p.move(to: CGPoint(x: c.x + dx * 14, y: c.y - dy * 2)); p.addLine(to: CGPoint(x: c.x - dx * 2, y: c.y - dy * 2)); p.addLine(to: CGPoint(x: c.x - dx * 2, y: c.y + dy * 14))
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .square))
        }
        .shadow(color: .black.opacity(0.35), radius: 1)
    }
}

private struct TextDraftField: View {
    @Bindable var ws: PictureWorkspace
    let size: CGSize
    let point: CGPoint
    @FocusState private var focused: Bool
    var body: some View {
        let font = max(11, ws.textSize * max(size.width, size.height))
        TextField("Type, then Return", text: Binding(get: { ws.textDraft?.text ?? "" }, set: { ws.textDraft?.text = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(Color(nsColor: ws.penColor))
            .frame(width: min(420, max(160, size.width - point.x * size.width - 8)), alignment: .leading)
            .padding(2)
            .overlay(Rectangle().strokeBorder(DS.focus, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .offset(x: point.x * size.width, y: point.y * size.height)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { ws.commitText() }
            .onExitCommand { ws.textDraft = nil }
    }
}

// MARK: - Sidebar options box

struct PictureOptions: View {
    @Bindable var ws: PictureWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch ws.active {
            case nil: about
            case .removeBackground: removeBackground
            case .crop: crop
            case .adjust: adjust
            case .pen, .highlighter, .arrow, .shape: drawing
            case .text: textOpts
            case .redact: redact
            case .selectArea: selectArea
            case .pipette: OptHint("Click anywhere on the picture to take its colour for the pen.")
            case .zoom: zoomOpts
            case .copyText: copyText
            case .translate: translate
            case .convert, .resize, .compress, .stripLocation: ExportOptions(ws: ws, tool: ws.active!)
            default: OptHint(ws.active!.hint)
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            OptTitle(ws.item.name)
            OptRow("Size", ws.pixelSize == .zero ? "—" : "\(Int(ws.pixelSize.width)) × \(Int(ws.pixelSize.height))")
            OptRow("File", Fmt.size(ws.item.size))
            if let cam = ws.item.camera { OptRow("Taken on", cam) }
            if ImageEngine.hasLocation(ws.sourceProps) { OptRow("Location", "Saved in the file") }
            OptHint("Pick a tool here, or use the bar for the usual four.")
        }
    }

    private var removeBackground: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Remove background")
            if ws.busy != nil {
                OptHint("Vision is finding the subject…")
            } else {
                OptCaption("Behind the subject")
                HStack(spacing: 7) {
                    BehindSwatch(selected: ws.behind == .clear, label: "See-through") { Checkerboard() } action: { ws.behind = .clear }
                    BehindSwatch(selected: ws.behind == .white, label: "White") { Color.white } action: { ws.behind = .white }
                    BehindSwatch(selected: ws.behind == .black, label: "Black") { Color.black } action: { ws.behind = .black }
                    BehindSwatch(selected: { if case .color = ws.behind { return true }; return false }(), label: "Second colour") { Color(nsColor: ws.backColor) } action: { ws.behind = .color(ws.backColor) }
                    BehindSwatch(selected: ws.behind == .blurred, label: "Blurred original") { Image(systemName: "drop.halffull").font(.system(size: 10)).foregroundStyle(DS.text2) } action: { ws.behind = .blurred }
                }
                HStack(spacing: 6) {
                    OptButton("Copy", symbol: "doc.on.doc") { ws.copyCutout(sticker: false) }
                    OptButton("Sticker", symbol: "seal") { ws.copyCutout(sticker: true) }
                }
                if ws.subjectCount > 1 { OptHint("\(ws.subjectCount) subjects found. Click one to keep only it.") }
                else { OptHint("Saved as a PNG so the background stays see-through.") }
            }
        }
    }

    private var crop: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Crop")
            OptChoice(options: PictureWorkspace.Aspect.allCases.map(\.rawValue), selection: ws.aspect.rawValue) { ws.aspect = PictureWorkspace.Aspect(rawValue: $0)! }
            OptSlider(label: "Straighten", value: $ws.straighten, range: -15...15, format: { String(format: "%+.0f°", $0) })
            HStack(spacing: 6) {
                OptButton("Rotate", symbol: "rotate.left") { ws.select(.rotate) }
                OptButton("Flip", symbol: ToolID.flip.symbol) { ws.select(.flip) }
            }
            HStack(spacing: 6) {
                OptButton("Reset", symbol: "arrow.counterclockwise") { ws.resetCrop() }
                OptButton("Apply", symbol: "checkmark", primary: true) { ws.applyCropNow() }
            }
        }
    }

    private var adjust: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { ws.applyEnhanceInAdjust() } label: {
                    Label("Enhance", systemImage: "wand.and.stars").font(DS.bodySM)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(DS.Tone.magic.fg)
                        .background(RoundedRectangle(cornerRadius: 7).fill(DS.Tone.magic.bg))
                }.buttonStyle(.plain).handCursor().help("One tap: light and colour fixed for you")
                Spacer()
            }
            OptSlider(label: "Light", value: $ws.adj.light, range: -100...100)
            OptSlider(label: "Colour", value: $ws.adj.colour, range: -100...100)
            OptSlider(label: "Warmth", value: $ws.adj.warmth, range: -100...100)
            OptSlider(label: "Sharpness", value: $ws.adj.sharpness, range: 0...100)
            OptCaption("Looks")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 4), spacing: 6) {
                ForEach(ImageEngine.looks, id: \.name) { look in
                    let on = ws.adj.look == look.filter
                    Button { ws.adj.look = look.filter } label: {
                        VStack(spacing: 2) {
                            Group {
                                if let t = ws.lookThumbs[look.name] { Image(nsImage: t).resizable().scaledToFill() } else { DS.tertiary }
                            }
                            .frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? DS.focus : .clear, lineWidth: 2))
                            Text(look.name).font(.system(size: 8.5)).foregroundStyle(on ? DS.text : DS.text2).lineLimit(1)
                        }
                    }.buttonStyle(.plain).handCursor()
                }
            }
        }
    }

    private var drawing: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle(ws.active!.title)
            OptChoice(options: ["Thin", "Medium", "Thick"], selection: ws.penWidth < 0.004 ? "Thin" : ws.penWidth < 0.008 ? "Medium" : "Thick") {
                ws.penWidth = $0 == "Thin" ? 0.0025 : $0 == "Medium" ? 0.005 : 0.01
            }
            OptHint(ws.active == .highlighter ? "Drag over what matters. The colour comes from the palette below." : "Drag on the picture. Colour comes from the palette below. Each mark can be undone with ⌘Z.")
        }
    }

    private var textOpts: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Text")
            OptChoice(options: ["Small", "Medium", "Large"], selection: ws.textSize < 0.03 ? "Small" : ws.textSize < 0.045 ? "Medium" : "Large") {
                ws.textSize = $0 == "Small" ? 0.022 : $0 == "Medium" ? 0.035 : 0.055
            }
            OptHint("Click the picture where the note should go, type, then press Return.")
        }
    }

    private var redact: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Redact")
            OptChoice(options: ImageEngine.RedactStyle.allCases.map(\.rawValue), selection: ws.redactStyle.rawValue) { ws.redactStyle = ImageEngine.RedactStyle(rawValue: $0)! }
            if ws.redactStyle == .pixelate { OptSlider(label: "Block size", value: $ws.redactBlock, range: 6...30, format: { "\(Int($0))" }) }
            OptHint("Drag over anything private. In the saved copy it can’t be undone.")
        }
    }

    private var selectArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Select area")
            if ws.selection == nil {
                OptHint("Drag a box on the picture.")
            } else {
                OptButton("Crop to it", symbol: "crop") { ws.cropToSelection() }
                OptButton("Copy it", symbol: "doc.on.doc") { ws.copySelection() }
                OptButton("Redact it", symbol: ToolID.redact.symbol) { ws.redactSelection() }
            }
        }
    }

    private var zoomOpts: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Zoom")
            OptChoice(options: ["Fit", "2×", "4×"], selection: ws.zoom <= 1 ? "Fit" : ws.zoom <= 2 ? "2×" : "4×") { ws.zoom = $0 == "Fit" ? 1 : $0 == "2×" ? 2 : 4 }
            OptHint("Click the picture to zoom in; it goes back to fit after 4×.")
        }
    }

    private var copyText: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Copy text")
            if ws.busy != nil { OptHint("Reading the text…") }
            else if ws.lineCount == 0 { OptHint("No text found in this picture.") }
            else {
                OptButton("Copy all text", symbol: "doc.on.doc", primary: true) { ws.copyAllText() }
                OptHint("\(Fmt.plural(ws.lineCount, "line")) found. Or select words right on the picture.")
            }
        }
    }

    @ViewBuilder
    private var translate: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Translate")
            if ws.busy != nil { OptHint("Reading the text…") }
            else if ws.lineCount == 0 { OptHint("No text found to translate.") }
            else if #available(macOS 14.4, *) {
                OptButton("Translate the text", symbol: "translate", primary: true) { ws.showTranslation = true }
                    .translationPresentation(isPresented: $ws.showTranslation, text: ws.recognized ?? "")
                OptHint("Uses Apple’s translation. Languages download once, then it works offline.")
            } else {
                OptHint("Translation needs macOS 14.4 or later.")
            }
        }
    }
}

private struct BehindSwatch<Fill: View>: View {
    let selected: Bool
    let label: String
    @ViewBuilder let fill: Fill
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            fill.frame(width: 22, height: 22).clipShape(Circle())
                .overlay(Circle().strokeBorder(DS.borderStrong, lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? DS.focus : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain).handCursor().help(label)
    }
}

/// Convert, Resize, Compress and Remove location all set up the same copy; each shows its part.
struct ExportOptions: View {
    @Bindable var ws: PictureWorkspace
    let tool: ToolID
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle(tool.title)
            switch tool {
            case .convert:
                OptChoice(options: ["JPEG", "PNG", "HEIC", "TIFF", "PDF"], selection: ws.export.format.rawValue) { ws.export.format = ImageEngine.Format(rawValue: $0)! }
                if ws.hasTransparency && !ws.export.format.keepsTransparency {
                    OptHint("\(ws.export.format.rawValue) can’t keep a see-through background; it will be white.")
                } else {
                    OptHint("JPEG opens everywhere. PNG keeps see-through backgrounds. WebP isn’t possible on macOS yet.")
                }
                sizeChoice
            case .resize:
                sizeChoice
            case .compress:
                OptChoice(options: ["JPEG", "HEIC"], selection: ws.export.format == .heic ? "HEIC" : "JPEG") { ws.export.format = $0 == "HEIC" ? .heic : .jpeg }
                OptSlider(label: "Quality", value: $ws.export.quality, range: 0.3...1, format: { "\(Int($0 * 100))%" })
            default:
                Toggle(isOn: $ws.export.stripLocation) { Text("Remove location & camera info").font(DS.bodySM) }
                    .toggleStyle(.switch).controlSize(.mini)
                OptHint(ImageEngine.hasLocation(ws.sourceProps) ? "This picture knows where it was taken." : "No location saved in this picture.")
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(ws.estimate.map { "About \($0)" } ?? "Working it out…").font(DS.headingSM).foregroundStyle(DS.text)
                Spacer()
            }
            OptCaption("was \(Fmt.size(ws.item.size)) · Save copy in the top bar")
        }
    }

    private var sizeChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            OptCaption("Size")
            OptChoice(options: ["Original", "2048", "1024", "512"], selection: ws.export.maxSide.map(String.init) ?? "Original") {
                ws.export.maxSide = $0 == "Original" ? nil : Int($0)
            }
            OptCaption("\(Int(ws.outputPixels.width)) × \(Int(ws.outputPixels.height)) px")
        }
    }
}

// MARK: - Colour palette (pen colour in front; the back colour goes behind cut-outs)

struct PaletteStrip: View {
    @Bindable var ws: PictureWorkspace
    static let colors: [UInt32] = [0x141416, 0x7A7A80, 0xFFFFFF, 0xE5484D, 0xF5A524, 0xF7D64A, 0x30A46C, 0x2F6FED,
                                   0x6E56CF, 0xE93D82, 0x8A5A3C, 0xA7D8F0, 0xC9C9CF, 0xFFD6A5, 0xB8E6C9, 0xD7C9FF]
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: ws.backColor))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DS.borderStrong))
                    .frame(width: 22, height: 22).offset(x: 14, y: 14)
                    .help("Second colour: goes behind cut-outs. Option-click a swatch to set it.")
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: ws.penColor))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 1)
                    .frame(width: 22, height: 22)
                    .help("Pen colour")
            }
            .frame(width: 36, height: 36, alignment: .topLeading)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(13), spacing: 3), count: 8), spacing: 3) {
                ForEach(Self.colors, id: \.self) { hex in
                    let c = NSColor(hex: hex)
                    Button {
                        if NSEvent.modifierFlags.contains(.option) {
                            ws.backColor = c
                            if case .color = ws.behind { ws.behind = .color(c) }
                        } else { ws.penColor = c }
                    } label: {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: c)).frame(width: 13, height: 13)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ws.penColor == c ? DS.focus : DS.border, lineWidth: ws.penColor == c ? 2 : 1))
                    }.buttonStyle(.plain).handCursor()
                }
            }
        }
    }
}

// MARK: - Small controls shared by every options box

struct OptTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(DS.body).foregroundStyle(DS.text).lineLimit(2) }
}

struct OptCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(DS.caption).foregroundStyle(DS.text2) }
}

struct OptHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(DS.caption).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true) }
}

struct OptRow: View {
    let key: String, value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
    var body: some View {
        HStack { Text(key).foregroundStyle(DS.text2); Spacer(); Text(value).foregroundStyle(DS.text).lineLimit(1) }.font(DS.caption)
    }
}

struct OptButton: View {
    let title: String
    var symbol: String?
    var primary = false
    let action: () -> Void
    init(_ title: String, symbol: String? = nil, primary: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.primary = primary; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)) }
                Text(title).font(DS.caption).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(primary ? DS.onBrand : DS.text)
            .background(RoundedRectangle(cornerRadius: 7).fill(primary ? DS.brand : DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? .clear : DS.border))
        }
        .buttonStyle(.plain).handCursor()
    }
}

struct OptChoice: View {
    let options: [String]
    let selection: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { pick(o) } label: {
                    Text(o).font(DS.caption).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(o == selection ? DS.text : DS.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(o == selection ? DS.surface : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(o == selection ? DS.border : .clear))
                }.buttonStyle(.plain).handCursor()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(DS.tertiary.opacity(0.6)))
    }
}

struct OptSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { v in v == 0 ? "0" : String(format: "%+.0f", v) }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(label).font(DS.caption).foregroundStyle(DS.text); Spacer(); Text(format(value)).font(DS.caption).foregroundStyle(DS.text2) }
            Slider(value: $value, in: range).controlSize(.mini)
        }
    }
}
