import SwiftUI
import AppKit

// MARK: - Thumbnails

struct Thumb: View {
    let item: FileItem
    var size: CGFloat
    var mode: Mode = .fill
    enum Mode { case fill, fit, page }

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                // Color.clear takes the parent's frame; the image fills/fits it without a GeometryReader.
                Color.clear.overlay(alignment: mode == .page ? .top : .center) {
                    Image(nsImage: image).resizable().interpolation(.medium)
                        .aspectRatio(contentMode: mode == .fit ? .fit : .fill)
                }
                .clipped()
            } else {
                GeometryReader { geo in
                    ZStack {
                        Rectangle().fill(KindPalette.of(item.category).placeholder)
                        Image(systemName: item.isFolder ? "folder.fill" : KindPalette.symbol(item.category))
                            .font(.system(size: max(10, min(geo.size.width, geo.size.height) * 0.3)))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
        .task(id: "\(item.id)|\(item.modifiedStamp)|\(ThumbnailCache.bucket(size))") {
            if let c = ThumbnailCache.shared.cached(item, size: size) { image = c; return }
            image = await ThumbnailCache.shared.image(for: item, size: size)
        }
    }
}

/// How a file kind looks across the app: folder colours, chips, badges.
struct KindPalette {
    var back: (Color, Color)
    var glass: (Color, Color)
    var text: Color
    var meta: Color
    var lightButton = false
    var placeholder: Color

    static func symbol(_ c: FileCategory) -> String {
        switch c {
        case .images: return "photo"
        case .videos: return "film"
        case .music: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .apps: return "square.grid.2x2"
        case .other: return "doc"
        }
    }

    static func of(_ c: FileCategory) -> KindPalette {
        switch c {
        case .images: return KindPalette(back: (Color(hex: 0x8CC3F2), Color(hex: 0x4E98DE)), glass: (Color(hex: 0x9CCBF2, alpha: 0.42), Color(hex: 0x6FB0EA, alpha: 0.86)), text: .white, meta: .white.opacity(0.85), placeholder: Color(hex: 0x6FB0EA))
        case .videos: return KindPalette(back: (Color(hex: 0x3C3C41), Color(hex: 0x1B1B1E)), glass: (Color(hex: 0x2A2A2E, alpha: 0.4), Color(hex: 0x111113, alpha: 0.88)), text: .white, meta: .white.opacity(0.75), lightButton: true, placeholder: Color(hex: 0x3C3C41))
        case .music: return KindPalette(back: (Color(hex: 0xFFCC45), Color(hex: 0xFFAA00)), glass: (Color(hex: 0xFFD460, alpha: 0.42), Color(hex: 0xFFB21A, alpha: 0.88)), text: .white, meta: .white.opacity(0.9), placeholder: Color(hex: 0xFFB21A))
        case .documents, .other: return KindPalette(back: (Color(hex: 0xECECEF), Color(hex: 0xD2D2D8)), glass: (Color.white.opacity(0.42), Color.white.opacity(0.86)), text: Color(hex: 0x303030), meta: Color(hex: 0x616161), placeholder: Color(hex: 0xB9BCC4))
        case .archives: return KindPalette(back: (Color(hex: 0x8ADDB8), Color(hex: 0x36B985)), glass: (Color(hex: 0x9BE3C2, alpha: 0.42), Color(hex: 0x4CC594, alpha: 0.86)), text: .white, meta: .white.opacity(0.9), placeholder: Color(hex: 0x4CC594))
        case .apps: return KindPalette(back: (Color(hex: 0xFF9C92), Color(hex: 0xF0564B)), glass: (Color(hex: 0xFFA79E, alpha: 0.42), Color(hex: 0xF46A60, alpha: 0.88)), text: .white, meta: .white.opacity(0.9), placeholder: Color(hex: 0xF46A60))
        }
    }

    /// A brand colour (download sources): solid back, tinted glass.
    static func brand(_ hex: UInt32) -> KindPalette {
        let c = Color(hex: hex)
        return KindPalette(back: (c, c.opacity(0.85)), glass: (Color(hex: hex, alpha: 0.42), Color(hex: hex, alpha: 0.88)),
                           text: .white, meta: .white.opacity(0.85), placeholder: c)
    }
}

// MARK: - Glass folder

struct FrontPocket: Shape {
    func path(in r: CGRect) -> Path {
        let sx = r.width / 200, sy = r.height / 110
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * sx, y: r.minY + y * sy) }
        var path = Path()
        path.move(to: p(16, 0)); path.addLine(to: p(70, 0))
        path.addCurve(to: p(86, 8), control1: p(77, 0), control2: p(81, 3))
        path.addLine(to: p(93, 16))
        path.addCurve(to: p(107, 22), control1: p(97, 20), control2: p(101, 22))
        path.addLine(to: p(186, 22))
        path.addCurve(to: p(200, 36), control1: p(194, 22), control2: p(200, 28))
        path.addLine(to: p(196.5, 93))
        path.addCurve(to: p(179, 110), control1: p(195.9, 102.5), control2: p(188.5, 110))
        path.addLine(to: p(21, 110))
        path.addCurve(to: p(3.5, 93), control1: p(11.5, 110), control2: p(4.1, 102.5))
        path.addLine(to: p(0, 16))
        path.addCurve(to: p(16, 0), control1: p(0, 7), control2: p(7, 0))
        path.closeSubpath()
        return path
    }
}

enum FolderStyle {
    case prints, frames, music, sheets, icons
    static func of(_ c: FileCategory) -> FolderStyle {
        switch c {
        case .images: return .prints
        case .videos: return .frames
        case .music: return .music
        case .documents, .other: return .sheets
        case .archives, .apps: return .icons
        }
    }
}

struct GlassFolder: View {
    let title: String
    let meta: String
    var palette: KindPalette
    var style: FolderStyle
    let items: [FileItem]
    var width: CGFloat = 200
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        let s = width / 200
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18 * s, style: .continuous)
                    .fill(LinearGradient(colors: [palette.back.0, palette.back.1], startPoint: .top, endPoint: .bottom))
                    .frame(width: 184 * s, height: 126 * s)
                    .offset(x: 8 * s, y: 8 * s)
                    .shadow(color: .black.opacity(0.14), radius: 14 * s, y: 12 * s)

                contents(s)
                    .offset(y: hovering ? -4 * s : 0)

                FrontPocket()
                    .fill(.ultraThinMaterial)
                    .overlay(FrontPocket().fill(LinearGradient(colors: [palette.glass.0, palette.glass.1], startPoint: .top, endPoint: .bottom)))
                    .overlay(FrontPocket().stroke(Color.white.opacity(palette.lightButton ? 0.22 : 0.65), lineWidth: 1))
                    .frame(width: 200 * s, height: 110 * s)
                    .offset(y: 58 * s)
                    .shadow(color: .black.opacity(0.12), radius: 10 * s, y: 8 * s)

                VStack(alignment: .leading, spacing: 3 * s) {
                    Text(title).font(DS.px(16 * s)).foregroundStyle(palette.text).lineLimit(1)
                    Text(meta).font(DS.px(max(10, 11 * s))).foregroundStyle(palette.meta).lineLimit(1)
                }
                .frame(width: 128 * s, alignment: .leading)
                .offset(x: 18 * s, y: 120 * s)

                ZStack {
                    Circle().fill(palette.lightButton ? Color.white : Color(hex: 0x1A1A1A))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    Image(systemName: "arrow.up.right").font(.system(size: 11 * s, weight: .bold))
                        .foregroundStyle(palette.lightButton ? Color(hex: 0x1A1A1A) : .white)
                }
                .frame(width: 30 * s, height: 30 * s)
                .offset(x: 154 * s, y: 124 * s)
            }
            .frame(width: 200 * s, height: 168 * s, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
        .handCursor()
    }

    @ViewBuilder private func contents(_ s: CGFloat) -> some View {
        switch style {
        case .prints:
            slots(s, [(20, 22, 82, 100, 8), (66, 4, 84, 104, -2), (118, 20, 72, 94, -10)]) { item, w, h in
                VStack(spacing: 0) {
                    Thumb(item: item, size: w).frame(width: w - 8 * s, height: h - 22 * s).clipShape(RoundedRectangle(cornerRadius: 3 * s))
                    Spacer(minLength: 0)
                }
                .padding(4 * s)
                .frame(width: w, height: h)
                .background(RoundedRectangle(cornerRadius: 5 * s).fill(.white))
            }
        case .frames:
            slots(s, [(22, 18, 80, 98, 7), (70, 4, 80, 98, -3), (122, 20, 80, 98, -9)]) { item, w, h in
                ZStack {
                    Thumb(item: item, size: w).frame(width: w, height: h)
                    Color.black.opacity(0.18)
                    Image(systemName: "play.fill").font(.system(size: 13 * s)).foregroundStyle(.white.opacity(0.95))
                }
                .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 8 * s))
            }
        case .music:
            ZStack(alignment: .topLeading) {
                Circle().fill(Color(hex: 0x1C1C1E))
                    .overlay(Circle().strokeBorder(Color(hex: 0x3A3A3E), lineWidth: 7 * s))
                    .overlay(Group { if let f = items.first { Thumb(item: f, size: 30 * s).frame(width: 30 * s, height: 30 * s).clipShape(Circle()) } })
                    .frame(width: 94 * s, height: 94 * s).offset(x: 98 * s, y: 2 * s)
                slots(s, [(20, 18, 86, 86, 7), (60, 8, 84, 84, -5)]) { item, w, h in
                    Thumb(item: item, size: w).frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 5 * s))
                }
            }
        case .sheets:
            slots(s, [(22, 14, 92, 118, 6), (76, 4, 90, 116, -3), (124, 18, 66, 100, -9)]) { item, w, h in
                Thumb(item: item, size: w * 2, mode: .page).frame(width: w, height: h)
                    .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 6 * s))
            }
        case .icons:
            slots(s, [(18, 12, 82, 82, 8), (66, 0, 88, 88, -3), (116, 10, 84, 84, -10)]) { item, w, h in
                Thumb(item: item, size: w, mode: .fit).frame(width: w, height: h)
            }
        }
    }

    private func slots<C: View>(_ s: CGFloat, _ frames: [(CGFloat, CGFloat, CGFloat, CGFloat, Double)],
                                @ViewBuilder content: @escaping (FileItem, CGFloat, CGFloat) -> C) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(frames.indices, items.prefix(frames.count))), id: \.1.id) { i, item in
                let f = frames[i]
                content(item, f.2 * s, f.3 * s)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                    .rotationEffect(.degrees(-f.4))
                    .offset(x: f.0 * s, y: f.1 * s)
            }
        }
    }
}

// MARK: - Glass file card

struct GlassFileCard: View {
    let item: FileItem
    var width: CGFloat = 188
    var height: CGFloat = 200
    var selected = false
    var snippet: String? = nil
    /// Driven by the parent grid (one hover tracker per grid, not one per card).
    var hovering = false

    private var kindLabel: String { item.isFolder ? "FOLDER" : (item.ext.isEmpty ? item.category.title : item.ext).uppercased() }

    private var meta: String {
        if let snippet { return snippet }
        if item.isFolder { return Fmt.relative(item.modified) }
        var parts = [item.category == .apps && item.size == 0 ? "App" : Fmt.size(item.size)]
        if let d = item.duration, d > 0, item.category == .videos || item.category == .music { parts.append(Fmt.duration(d)) }
        else if let s = item.source { parts.append(s.name) }
        else if let cam = item.camera { parts.append(cam) }
        else { parts.append(Fmt.relative(item.activityDate)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            media
            HStack(spacing: 4) {
                Text(kindLabel).font(DS.label).tracking(0.5)
                if item.hasText && item.category == .images { Image(systemName: "text.viewfinder").font(.system(size: 9, weight: .semibold)) }
                if item.isCloudOnly { Image(systemName: "icloud").font(.system(size: 9, weight: .semibold)) }
            }
            .foregroundStyle(Color(hex: 0x303030))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.86)))
            .padding(10)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(DS.bodySM).foregroundStyle(Color(hex: 0x303030)).lineLimit(1).truncationMode(.middle)
                Text(meta).font(DS.caption).foregroundStyle(Color(hex: 0x616161)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: width - 16, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.84), Color.white.opacity(0.94)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.7)))
            .offset(x: 8, y: height - 60)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.surface)
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.08), radius: hovering ? 14 : 8, y: hovering ? 8 : 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? DS.focus : DS.border.opacity(0.6), lineWidth: selected ? 3 : 1))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(item.shortPath)
    }

    @ViewBuilder private var media: some View {
        switch item.category {
        case .images, .videos:
            ZStack {
                Thumb(item: item, size: width).frame(width: width, height: height)
                if item.category == .videos {
                    Image(systemName: "play.fill").font(.system(size: 16)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Circle().fill(Color.black.opacity(0.35)))
                        .offset(y: -24)
                }
            }
        case .documents:
            Thumb(item: item, size: width, mode: .page)
                .frame(width: width - 28, height: height - 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .frame(width: width, height: height, alignment: .top)
                .padding(.top, 34)
                .background(LinearGradient(colors: [Color(hex: 0xF6F6F7), Color(hex: 0xEDEDF0)], startPoint: .top, endPoint: .bottom))
        default:
            Thumb(item: item, size: width, mode: .fit)
                .frame(width: width * 0.48, height: width * 0.48)
                .frame(width: width, height: height - 40)
                .background(LinearGradient(colors: [Color(hex: 0xF0F2F6), Color(hex: 0xDDE1E8)], startPoint: .top, endPoint: .bottom))
        }
    }
}
