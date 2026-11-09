import SwiftUI
import AppKit

// MARK: - Colour helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) { self.init(nsColor: NSColor(hex: hex, alpha: alpha)) }

    /// A colour that follows light / dark appearance.
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

// MARK: - Design system (Polaris tokens, Geist Pixel type)

enum DS {
    // Surfaces
    static let app = Color.dyn(0xF1F1F1, 0x0E1116)
    static let surface = Color.dyn(0xFFFFFF, 0x1B1F26)
    static let surface2 = Color.dyn(0xF7F7F7, 0x232832)
    static let hover = Color.dyn(0xF4F4F4, 0x252A33)
    static let nav = Color.dyn(0xEBEBEB, 0x161A20)
    static let tertiary = Color.dyn(0xE3E3E3, 0x2C313B)
    static let topbar = Color(hex: 0x1A1A1A)
    static let topbarHeight: CGFloat = 52
    static let topbarField = Color(hex: 0x303030)
    static let brand = Color.dyn(0x303030, 0xF1F1F1)
    static let onBrand = Color.dyn(0xFFFFFF, 0x1A1A1A)
    static let border = Color.dyn(0xE3E3E3, 0x2C313B)
    static let borderStrong = Color.dyn(0xCCCCCC, 0x3B414C)
    static let focus = Color(hex: 0x2E7BEA)
    static let critical = Color(hex: 0xC70A24)
    // Text
    static let text = Color.dyn(0x303030, 0xE9EAEC)
    static let text2 = Color.dyn(0x616161, 0x9AA1AC)
    static let text3 = Color.dyn(0x8A8A8A, 0x6E7580)
    static let onDark = Color(hex: 0xE3E3E3)
    static let onDark2 = Color(hex: 0x8A8A8A)
    static let link = Color.dyn(0x005BD3, 0x5AA2FF)

    enum Tone {
        case neutral, info, success, attention, critical, magic, emphasis
        var bg: Color {
            switch self {
            case .neutral: return DS.tertiary
            case .info: return .dyn(0xEAF4FF, 0x10304A)
            case .success: return .dyn(0xCDFEE1, 0x0E3A27)
            case .attention: return .dyn(0xFFF1E3, 0x3D2A10)
            case .critical: return .dyn(0xFEE9E8, 0x45141A)
            case .magic: return .dyn(0xF3EEFF, 0x2C1C55)
            case .emphasis: return .dyn(0xF0F2FF, 0x1F2752)
            }
        }
        var fg: Color {
            switch self {
            case .neutral: return DS.text
            case .info: return .dyn(0x00527C, 0x8CCBFF)
            case .success: return .dyn(0x0C5132, 0x7FE0B0)
            case .attention: return .dyn(0x5E4200, 0xFFCE7A)
            case .critical: return .dyn(0x8E0B21, 0xFF9AA5)
            case .magic: return .dyn(0x5700D1, 0xC6A8FF)
            case .emphasis: return .dyn(0x2E3A86, 0xAFB9FF)
            }
        }
    }

    // Type — everything in Geist Pixel (system font fills in missing glyphs like ⌘).
    static let pixelName = "GeistPixel-Square"
    static func px(_ size: CGFloat) -> Font { .custom(pixelName, fixedSize: size) }
    static let display = px(40)
    static let headingLG = px(28)
    static let headingMD = px(20)
    static let headingSM = px(16)
    static let stat = px(24)
    static let label = px(11)
    static let body = px(13)
    static let bodySM = px(12)
    static let caption = px(11)
    static let searchLG = px(18)

    static let radius: CGFloat = 12
}

// MARK: - Building blocks

struct PixelLabel: View {
    let text: String
    var color: Color = DS.text2
    init(_ text: String, color: Color = DS.text2) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(DS.label).tracking(0.7).foregroundStyle(color)
    }
}

struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    var fill: Color = DS.surface
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.border.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

extension View {
    func card(_ radius: CGFloat = 16, fill: Color = DS.surface) -> some View { modifier(CardBackground(radius: radius, fill: fill)) }
}

struct PButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain, critical }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.bodySM)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(kind == .secondary ? DS.borderStrong : .clear))
            .shadow(color: kind == .primary || kind == .critical ? .black.opacity(0.2) : .clear, radius: 1, y: 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
            .handCursor()
    }
    private var fg: Color {
        switch kind {
        case .primary: return DS.onBrand
        case .critical: return .white
        case .secondary, .plain: return DS.text
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: return DS.brand
        case .critical: return DS.critical
        case .secondary: return DS.surface
        case .plain: return .clear
        }
    }
}

extension ButtonStyle where Self == PButtonStyle {
    static var primary: PButtonStyle { PButtonStyle(kind: .primary) }
    static var secondary: PButtonStyle { PButtonStyle(kind: .secondary) }
    static var plainP: PButtonStyle { PButtonStyle(kind: .plain) }
    static var critical: PButtonStyle { PButtonStyle(kind: .critical) }
}

/// Pointing-hand cursor while hovering a clickable control. `onContinuousHover` re-asserts the
/// cursor on every move (AppKit cursor rects would otherwise reset it), and resets to the arrow
/// on exit — no push/pop, so it can't get stuck if the view disappears mid-hover.
struct HandCursor: ViewModifier {
    var enabled = true
    func body(content: Content) -> some View {
        if enabled {
            content.onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func handCursor(_ enabled: Bool = true) -> some View { modifier(HandCursor(enabled: enabled)) }
}

struct Chip: View {
    enum Style { case normal, selected, understood }
    let label: String
    var symbol: String?
    var style: Style = .normal
    var menu = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
            Text(label).font(DS.bodySM).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).help("Remove").handCursor()
            } else if menu {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(fg)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style == .normal ? DS.border : .clear))
        .contentShape(Rectangle())
        // "Understood" chips are read-only labels (only their ✕ is clickable); the rest are filter/menu buttons.
        .handCursor(style != .understood)
    }
    private var fg: Color { style == .selected ? DS.onBrand : style == .understood ? DS.Tone.emphasis.fg : DS.text }
    private var bg: Color { style == .selected ? DS.brand : style == .understood ? DS.Tone.emphasis.bg : DS.surface }
}

struct Badge: View {
    let label: String
    var tone: DS.Tone = .neutral
    init(_ label: String, tone: DS.Tone = .neutral) { self.label = label; self.tone = tone }
    var body: some View {
        Text(label).font(DS.bodySM).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(tone.fg)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tone.bg))
    }
}

struct Kbd: View {
    let key: String
    var dark = false
    init(_ key: String, dark: Bool = false) { self.key = key; self.dark = dark }
    var body: some View {
        Text(key).font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(dark ? DS.onDark2 : DS.text2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(dark ? DS.onDark2.opacity(0.7) : DS.borderStrong))
    }
}

struct IconBtn: View {
    let symbol: String
    var dark = false
    var selected = false
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(dark ? DS.onDark : DS.text)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? (dark ? DS.topbarField : DS.tertiary) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help(help)
    }
}

struct ToneIcon: View {
    let symbol: String
    var tone: DS.Tone
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(tone.fg)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tone.bg))
    }
}

/// Dark floating pill used for selection bars and toasts.
struct DarkPill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1A1A1A).opacity(0.9)))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            .foregroundStyle(.white)
    }
}

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void
    var body: some View {
        DarkPill {
            Text(toast.message).font(DS.body)
            if let undo = toast.undo {
                Button { undo(); dismiss() } label: {
                    Text("Undo").font(DS.bodySM).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                Kbd("⌘Z", dark: true)
            }
        }
    }
}

// MARK: - Backgrounds

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case dots, aurora, liquid, halftone, tide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dots: return "Dot grid"
        case .aurora: return "Pixel aurora"
        case .liquid: return "Liquid glass"
        case .halftone: return "Halftone"
        case .tide: return "Tide lines"
        }
    }
    var file: String? {
        switch self {
        case .dots: return nil
        case .aurora: return "bg-aurora@2x.png"
        case .liquid: return "bg-liquid@2x.jpg"
        case .halftone: return "bg-halftone@2x.png"
        case .tide: return "bg-tide@2x.png"
        }
    }
}

enum Art {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Backgrounds/" + name),
              let img = NSImage(contentsOf: url) else { return nil }
        if name.contains("@2x"), let rep = img.representations.first {
            img.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        }
        cache[name] = img
        return img
    }
}

/// Window canvas: dot grid or the chosen background (Night sea in dark mode).
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    let style: BackgroundStyle

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                DS.app
                if scheme == .dark {
                    if let img = Art.image("bg-night@2x.png") {
                        Image(nsImage: img).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                    }
                } else if let f = style.file, let img = Art.image(f) {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                } else if let tile = Art.image("dotgrid-tile@2x.png") {
                    Image(nsImage: tile).resizable(resizingMode: .tile)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Small dithered illustration for empty states.
struct DitherBlob: View {
    var symbol: String
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2, r = min(size.width, size.height) / 2
                var y: CGFloat = 2
                while y < size.height {
                    var x: CGFloat = 2
                    while x < size.width {
                        let d = hypot(x - cx, y - cy) / r
                        let noise = Double((Int(x) * 7 + Int(y) * 13) % 9) / 9
                        if d < 1 && noise < 1.15 - d * 0.9 {
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 3.5, height: 3.5)),
                                     with: .color(Color(hex: 0x1E3F8F).opacity(0.15 + 0.45 * (1 - d))))
                        }
                        x += 7
                    }
                    y += 7
                }
            }
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(DS.text)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.surface))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .frame(width: 150, height: 100)
    }
}

struct EmptyState: View {
    let symbol: String
    let tag: String
    var tone: DS.Tone = .neutral
    let title: String
    let message: String
    var actions: AnyView? = nil

    var body: some View {
        VStack(spacing: 12) {
            DitherBlob(symbol: symbol)
            Badge(tag, tone: tone)
            Text(title).font(DS.headingSM).foregroundStyle(DS.text).multilineTextAlignment(.center)
            Text(message).font(DS.bodySM).foregroundStyle(DS.text2).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let actions { actions.padding(.top, 4) }
        }
        .padding(28)
        .card(16)
        .frame(maxWidth: 460)
    }
}

/// Lets the window be dragged from an empty part of the custom top bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        /// SwiftUI lays this view out taller than the 52pt bar (ignoresSafeArea doubles it to ~104pt),
        /// which made it swallow clicks on content just below the bar. Only claim the bar itself.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let sv = superview, let w = window else { return nil }
            let y = sv.convert(point, to: nil).y
            return w.frame.height - y <= DS.topbarHeight ? super.hitTest(point) : nil
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}

struct VoiceLevelView: View {
    let level: Float
    var color: Color = DS.brand
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = (sin(t * 9 + Double(i) * 1.3) + 1) / 2
                    Capsule().fill(color).frame(width: 3, height: 4 + CGFloat(level) * 16 * (0.45 + 0.55 * wobble))
                }
            }
            .frame(height: 22)
        }
    }
}

struct MicButton: View {
    let active: Bool
    var size: CGFloat = 36
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(active ? DS.critical : DS.brand)
                Image(systemName: active ? "stop.fill" : "mic.fill").font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(active ? .white : DS.onBrand)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .help(active ? "Stop listening" : "Search by voice (⌥⌘F)")
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Registers the bundled Geist Pixel font for this process (Info.plist registration only applies to LaunchServices launches).
enum FontLoader {
    static func register() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
        if NSFont(name: DS.pixelName, size: 12) == nil { NSLog("OrcaFind: Geist Pixel font not available, falling back to system font") }
    }
}
