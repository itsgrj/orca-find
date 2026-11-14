import SwiftUI
import AVFoundation
import AVKit

/// Which part of the Captures tab is open.
enum CaptureFolder: Hashable {
    case everything, unsorted, reminders, collection(String)

    var title: String {
        switch self {
        case .everything: return "Everything"
        case .unsorted: return "Unsorted"
        case .reminders: return "Reminders"
        case .collection(let n): return n
        }
    }

    func contains(_ c: Capture) -> Bool {
        switch self {
        case .everything: return true
        case .unsorted: return c.collection == nil
        case .reminders: return c.reminderDate != nil
        case .collection(let n): return c.collection.map { SpokenIntent.same($0, n) } ?? false
        }
    }
}

/// T1–T3 — Captures opens on collections as tinted glass folders. Tags narrow inside a folder, or pull one
/// theme out of every folder (#design across SigmaFlow, Newsletter, Wedding…).
struct CapturesScreen: View {
    @Environment(AppState.self) private var state
    @Environment(CaptureLibrary.self) private var library

    private var query: String { state.capturesQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                VoiceNotesTip()
                chips
                if !query.isEmpty || state.capturesFolder != nil || state.capturesTag != nil {
                    if shown.isEmpty { empty } else { grid }
                } else if library.items.isEmpty {
                    empty
                } else {
                    folders
                }
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 40)
        }
        .scrollIndicators(.never)
    }

    // MARK: What's shown

    /// "#design pricing" → tag "design" + words "pricing".
    private var queryParts: (tags: [String], words: String) {
        var tags: [String] = [], words: [String] = []
        for w in query.split(separator: " ").map(String.init) {
            if w.hasPrefix("#"), let t = CaptureTags.normalize(w) { tags.append(t) } else { words.append(w) }
        }
        return (tags, words.joined(separator: " "))
    }

    private var shown: [Capture] {
        var list: [Capture]
        let q = queryParts
        if q.words.isEmpty {
            list = library.items
        } else {
            _ = library.version
            list = CaptureStore.shared.search(q.words, matchAll: true)
            if list.isEmpty { list = CaptureStore.shared.search(q.words, matchAll: false) }
        }
        for t in q.tags { list = list.filter { $0.hasTag(t) } }
        if let f = state.capturesFolder { list = list.filter(f.contains) }
        if let t = state.capturesTag { list = list.filter { $0.hasTag(t) } }
        if state.capturesFolder == .reminders {
            list.sort { ($0.reminderDate ?? .distantFuture) < ($1.reminderDate ?? .distantFuture) }
        }
        return list
    }

    private func items(in f: CaptureFolder) -> [Capture] { library.items.filter(f.contains) }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if state.capturesFolder != nil || state.capturesTag != nil {
                    Button { goHome() } label: { Text("← Captures").font(DS.bodySM).foregroundStyle(DS.text2) }
                        .buttonStyle(.plain).handCursor()
                }
                Text(title).font(DS.headingLG).foregroundStyle(DS.text).lineLimit(1)
                Text(subtitle).font(DS.bodySM).foregroundStyle(DS.text2)
            }
            Spacer()
            Button { CaptureController.shared.start() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "viewfinder").font(.system(size: 11, weight: .medium))
                    Text("\(state.prefs.captureHotKey.display) to grab anything")
                }
            }
            .buttonStyle(.secondary)
            .help("Press it from any app, drag over anything, then talk")
        }
    }

    private var title: String {
        if !query.isEmpty { return "Captures" }
        if let f = state.capturesFolder { return f.title }
        if let t = state.capturesTag { return "#" + t }
        return "Captures"
    }

    private var subtitle: String {
        if !query.isEmpty { return "\(Fmt.plural(shown.count, "match", "matches")) for “\(query)”" }
        if let f = state.capturesFolder {
            let all = items(in: f)
            var s = Fmt.plural(all.count, "save")
            if let t = state.capturesTag { s = "\(Fmt.plural(shown.count, "save")) tagged #\(t) · \(all.count) in \(f.title)" }
            else if let last = all.first { s += " · last added \(Capture.shortDate(last.created).lowercased())" }
            return s
        }
        if state.capturesTag != nil {
            let cols = Set(shown.map { $0.collection?.lowercased() ?? "" })
            return "\(Fmt.plural(shown.count, "save")) in \(Fmt.plural(cols.count, "collection"))"
        }
        var parts = ["\(library.items.count) saved", Fmt.plural(library.collections.count, "collection")]
        let r = library.upcomingReminders
        if r > 0 { parts.append("\(r) reminder\(r == 1 ? "" : "s") coming up") }
        return parts.joined(separator: " · ")
    }

    private func goHome() {
        state.capturesFolder = nil
        state.capturesTag = nil
    }

    // MARK: Chips

    @ViewBuilder private var chips: some View {
        if query.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if let f = state.capturesFolder {
                        // T2: tags used in this folder.
                        let inside = items(in: f)
                        chip("All  \(inside.count)", selected: state.capturesTag == nil) { state.capturesTag = nil }
                        let tags = CaptureLibrary.countTags(inside)
                        ForEach(tags, id: \.name) { t in
                            chip("#\(t.name)  \(t.count)", selected: state.capturesTag.map { CaptureTags.same($0, t.name) } ?? false) {
                                state.capturesTag = t.name
                            }
                        }
                        hint(tags.isEmpty ? "Say “tag it design” while capturing to add tags" : "Tap a tag to narrow")
                    } else if let t = state.capturesTag {
                        // T3: one tag, every collection it's in.
                        let tagged = library.items.filter { $0.hasTag(t) }
                        chip("All  \(tagged.count)", selected: true) {}
                        ForEach(Self.folderCounts(tagged), id: \.0) { f, n in
                            chip("\(f.title)  \(n)", selected: false) { state.capturesFolder = f }
                        }
                        hint("Narrow to one collection")
                    } else {
                        // T1: tags across everything.
                        chip("All", selected: true) {}
                        let r = library.items.filter { $0.reminderDate != nil }.count
                        if r > 0 { chip("Reminders  \(r)", selected: false) { state.capturesFolder = .reminders } }
                        ForEach(library.tags.prefix(14), id: \.name) { t in
                            chip("#\(t.name)  \(t.count)", selected: false) { state.capturesTag = t.name }
                        }
                        hint(library.tags.isEmpty ? "Say “tag it design” while capturing — tags work across collections"
                                                  : "Tags come from what you say and what Orca sees")
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    static func folderCounts(_ list: [Capture]) -> [(CaptureFolder, Int)] {
        var order: [CaptureFolder] = []
        var counts: [CaptureFolder: Int] = [:]
        for c in list {
            let f: CaptureFolder = c.collection.map { name in
                order.first { if case .collection(let n) = $0 { return SpokenIntent.same(n, name) }; return false } ?? .collection(name)
            } ?? .unsorted
            if counts[f] == nil { order.append(f) }
            counts[f, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }.sorted { $0.1 > $1.1 }
    }

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Chip(label: label, style: selected ? .selected : .normal) }
            .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle").font(.system(size: 10))
            Text(text).font(DS.caption)
        }
        .foregroundStyle(DS.Tone.magic.fg)
        .padding(.leading, 6)
    }

    // MARK: T1 folders

    private var folders: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 230), spacing: 28)], alignment: .leading, spacing: 26) {
            folderTile(.everything, palette: CaptureFolderPalette.everything)
            if library.items.contains(where: { $0.collection == nil }) {
                folderTile(.unsorted, palette: CaptureFolderPalette.unsorted)
            }
            ForEach(library.collections, id: \.name) { col in
                folderTile(.collection(col.name), palette: nil)
            }
        }
    }

    private func folderTile(_ f: CaptureFolder, palette: KindPalette?) -> some View {
        let list = items(in: f)
        let when = list.first.map { " · " + Capture.shortDate($0.created).lowercased() } ?? ""
        return CaptureFolderTile(title: f.title, meta: Fmt.plural(list.count, "save") + when,
                                 ids: list.prefix(3).map(\.id), fixedPalette: palette) {
            state.capturesTag = nil
            state.capturesFolder = f
        }
        .contextMenu {
            if case .collection(let name) = f {
                Button("Open") { state.capturesFolder = f }
                Button("Copy “\(name)” for AI (Details Only)") { CaptureActions.copyCollectionText(name, list) }
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        let showCollection: Bool = {
            if case .collection = state.capturesFolder { return false }
            return true
        }()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
            ForEach(shown) { c in
                CaptureCard(capture: c, showCollection: showCollection)
                    .onTapGesture { state.navigate(.capture(c.id)) }
                    .contextMenu { CaptureMenu(capture: c) }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder").font(.system(size: 34, weight: .light)).foregroundStyle(DS.text3)
            if query.isEmpty && library.items.isEmpty {
                Text("Save anything on your screen").font(DS.headingMD).foregroundStyle(DS.text)
                Text("Press \(state.prefs.captureHotKey.display) in any app, drag over a post, a product, a slide — then just say why.\nStop talking and it’s saved, with the link and the text in the picture. If it’s moving, Orca keeps a clip.")
                    .font(DS.body).foregroundStyle(DS.text2).multilineTextAlignment(.center)
                Button("Try it now") { CaptureController.shared.start() }.buttonStyle(.primary)
            } else {
                Text("Nothing here").font(DS.headingMD).foregroundStyle(DS.text)
                Text("Try other words — Orca searches what you said, the page, the text in the picture and tags like #design.").font(DS.body).foregroundStyle(DS.text2)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}

/// A collection as a glass folder: its latest three saves peek out, tinted by the colours in its pictures.
struct CaptureFolderTile: View {
    let title: String
    let meta: String
    let ids: [String]
    var fixedPalette: KindPalette?
    var action: () -> Void

    @State private var hovering = false
    @State private var tint: KindPalette?

    var body: some View {
        let palette = fixedPalette ?? tint ?? CaptureFolderPalette.fallback(title)
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [palette.back.0, palette.back.1], startPoint: .top, endPoint: .bottom))
                    .frame(width: 184, height: 126)
                    .offset(x: 8, y: 8)
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 12)

                prints.offset(y: hovering ? -6 : 0)

                GlassPocket(glass: palette.glass, hairline: 0.55) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [palette.back.0, palette.back.1], startPoint: .top, endPoint: .bottom))
                            .frame(width: 184, height: 126)
                            .offset(x: 8, y: 8)
                        prints.offset(y: hovering ? -6 : 0)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(DS.px(16)).foregroundStyle(palette.text).lineLimit(1)
                    Text(meta).font(DS.px(11)).foregroundStyle(palette.meta).lineLimit(1)
                }
                .frame(width: 128, alignment: .leading)
                .offset(x: 18, y: 120)

                ZStack {
                    Circle().fill(Color(hex: 0x1A1A1A)).shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                .offset(x: 154, y: 124)
            }
            .frame(width: 200, height: 168, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
        .task(id: ids.joined()) {
            guard fixedPalette == nil else { return }
            let ids = ids
            if let c = await Task.detached(priority: .utility, operation: { CaptureFolderPalette.tint(ids) }).value {
                tint = CaptureFolderPalette.palette(c)
            }
        }
    }

    private var prints: some View {
        let frames: [(CGFloat, CGFloat, CGFloat, CGFloat, Double)] = [(20, 22, 82, 100, 8), (66, 4, 84, 104, -2), (118, 20, 72, 94, -10)]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ids.prefix(3).enumerated()), id: \.element) { i, id in
                let f = frames[i]
                VStack(spacing: 0) {
                    CaptureThumb(id: id, maxPixel: 260).frame(width: f.2 - 8, height: f.3 - 22).clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer(minLength: 0)
                }
                .padding(4)
                .frame(width: f.2, height: f.3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                .rotationEffect(.degrees(-f.4))
                .offset(x: f.0, y: f.1)
            }
        }
    }
}

/// Folder colours: taken from the colourful parts of the pictures inside, kept soft enough for white text.
enum CaptureFolderPalette {
    static let everything = KindPalette(back: (Color(hex: 0xECECEF), Color(hex: 0xD2D2D8)), glass: (Color.white.opacity(0.42), Color.white.opacity(0.86)),
                                        text: Color(hex: 0x303030), meta: Color(hex: 0x616161), placeholder: Color(hex: 0xB9BCC4))
    static let unsorted = palette(NSColor(hex: 0x8A8F98))

    private static var cache: [String: NSColor] = [:]
    private static let lock = NSLock()

    static func palette(_ c: NSColor) -> KindPalette {
        let base = c.usingColorSpace(.sRGB) ?? c
        let light = base.blended(withFraction: 0.35, of: .white) ?? base
        let glassTop = base.blended(withFraction: 0.3, of: .white) ?? base
        let glassBottom = base.blended(withFraction: 0.1, of: .white) ?? base
        return KindPalette(back: (Color(nsColor: light), Color(nsColor: base)),
                           glass: (Color(nsColor: glassTop).opacity(0.42), Color(nsColor: glassBottom).opacity(0.86)),
                           text: .white, meta: .white.opacity(0.88), placeholder: Color(nsColor: base))
    }

    /// A steady colour from the name when the pictures are mostly white or grey.
    static func fallback(_ name: String) -> KindPalette {
        let hues: [UInt32] = [0x7C5CF0, 0xE0662E, 0x2E9AA6, 0x7D8B4E, 0xE3A33B, 0x3557B8, 0xD9577F, 0x5D6B7E, 0xB0763A, 0x4D7C5B, 0xC8433A, 0x6B4FA0]
        var h: UInt32 = 2166136261
        for b in name.lowercased().utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette(NSColor(hex: hues[Int(h % UInt32(hues.count))]))
    }

    /// Average of the saturated pixels in up to four pictures; nil when they're mostly neutral.
    static func tint(_ ids: [String]) -> NSColor? {
        let key = ids.joined(separator: ",")
        lock.lock(); if let hit = cache[key] { lock.unlock(); return hit }; lock.unlock()
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, colourful = 0, total = 0
        let side = 20
        for id in ids.prefix(4) {
            let url = CaptureStore.folder.appendingPathComponent("\(id).png")
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary),
                  let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            for i in 0..<(side * side) {
                let pr = Double(data[i * 4]) / 255, pg = Double(data[i * 4 + 1]) / 255, pb = Double(data[i * 4 + 2]) / 255
                let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
                total += 1
                let sat = mx > 0 ? (mx - mn) / mx : 0
                guard sat > 0.28, mx > 0.25, mx < 0.97 || sat > 0.5 else { continue }
                colourful += 1
                r += pr * sat; g += pg * sat; b += pb * sat; weight += sat
            }
        }
        guard total > 0, weight > 0, Double(colourful) / Double(total) > 0.06 else { return nil }
        var c = NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
        c = NSColor(hue: hue, saturation: min(0.72, max(0.38, sat)), brightness: min(0.82, max(0.55, bri)), alpha: 1)
        lock.lock(); cache[key] = c; lock.unlock()
        return c
    }
}

struct CaptureCard: View {
    let capture: Capture
    var showCollection = true
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                CaptureThumb(id: capture.id, maxPixel: 700, fit: true)
                if hovering, capture.hasClip {
                    LoopingClipView(url: capture.clipURL).allowsHitTesting(false)
                }
                if let s = capture.clipSeconds, s > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text(CaptureStripView.clock(s)).font(DS.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.7)))
                    .padding(8)
                }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(capture.note.isEmpty ? capture.title : "“\(capture.note)”")
                .font(DS.bodySM).foregroundStyle(DS.text).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            HStack(spacing: 6) {
                Image(systemName: CaptureCard.symbol(capture)).font(.system(size: 10))
                Text(meta).font(DS.caption).lineLimit(1)
            }
            .foregroundStyle(DS.text2)
            if !capture.tagList.isEmpty {
                Text(capture.tagList.map { "#" + $0 }.joined(separator: "  ")).font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
            }
        }
        .padding(10)
        .card(14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? DS.borderStrong : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .handCursor()
    }

    private var meta: String {
        var parts = [capture.sourceLabel, Capture.shortDate(capture.created)]
        if showCollection, let c = capture.collection { parts.append(c) }
        if let r = capture.reminderDate, r > Date() { parts.append("reminder \(Capture.reminderShort(r))") }
        return parts.joined(separator: " · ")
    }

    static func symbol(_ c: Capture) -> String {
        if (c.clipSeconds ?? 0) > 0 { return "film" }
        switch c.sourceLabel {
        case "X", "Threads", "Bluesky", "Reddit": return "text.bubble"
        case "YouTube": return "play.rectangle"
        case "Instagram", "TikTok", "Pinterest": return "photo.on.rectangle"
        case "Medium", "Substack": return "doc.text"
        default: return c.pageURL != nil ? "globe" : "macwindow"
        }
    }
}

struct CaptureMenu: View {
    @Environment(AppState.self) private var state
    @Environment(CaptureLibrary.self) private var library
    let capture: Capture
    var body: some View {
        Button("Open") { state.navigate(.capture(capture.id)) }
        if let link = capture.links.first, let url = URL(string: link) {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        Button("Copy for AI (Picture + Details)") { CaptureActions.copyForAI(capture) }
        Button("Copy Picture Only") { CaptureActions.copyImage(capture) }
        Button("Copy Details Only") { CaptureActions.copyText(capture) }
        Divider()
        Button("Delete", role: .destructive) { library.delete(capture) }
    }
}

enum CaptureActions {
    /// Picture + note + links + source + text in the picture, as one clipboard item:
    /// image (PNG/TIFF), rich text (HTML with the picture inline) and plain text, so each app takes what it can.
    static func copyForAI(_ c: Capture) {
        let text = c.asText
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        var hasPicture = false
        if let png = try? Data(contentsOf: c.imageURL) {
            hasPicture = true
            item.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
            let inline = CaptureStore.pngData(c.imageURL, maxPixel: 1600) ?? png
            let body = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
            let html = "<meta charset=\"utf-8\"><div><img src=\"data:image/png;base64,\(inline.base64EncodedString())\"><p>\(body)</p></div>"
            item.setString(html, forType: .html)
        }
        NSPasteboard.general.clearContents()
        var objects: [NSPasteboardWriting] = [item]
        // The clip goes along as a file, for apps that take video.
        if c.hasClip { objects.append(c.clipURL as NSURL) }
        NSPasteboard.general.writeObjects(objects)
        MainActor.assumeIsolated {
            AppState.shared.showToast(c.hasClip ? "Copied the picture, the clip and everything about it"
                                      : hasPicture ? "Copied the picture and everything about it — paste into Claude or any chat"
                                                   : "Copied — paste it into any AI chat")
        }
    }

    /// Every capture in a collection, as text (for "write the newsletter from these").
    static func copyCollectionText(_ name: String, _ list: [Capture]) {
        let text = "# \(name) — \(list.count) saved captures\n\n" + list.map(\.asText).joined(separator: "\n\n---\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        MainActor.assumeIsolated { AppState.shared.showToast("Copied \(Fmt.plural(list.count, "capture")) from \(name)") }
    }

    static func copyText(_ c: Capture) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.asText, forType: .string)
        MainActor.assumeIsolated { AppState.shared.showToast("Copied the note and details") }
    }

    static func copyImage(_ c: Capture) {
        guard let img = NSImage(contentsOf: c.imageURL) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        MainActor.assumeIsolated { AppState.shared.showToast("Picture copied") }
    }
}

// MARK: - V6: one capture, opened

struct CaptureDetailScreen: View {
    @Environment(AppState.self) private var state
    @Environment(CaptureLibrary.self) private var library
    let id: String
    @State private var editing = false
    @State private var draft = ""
    @State private var newCollection = ""
    @State private var askingCollection = false
    @State private var addingTag = false
    @StateObject private var audio = AudioPlayback()

    var body: some View {
        if let c = library.capture(id) {
            VStack(alignment: .leading, spacing: 16) {
                topRow(c)
                HStack(alignment: .top, spacing: 20) {
                    picture(c)
                    ScrollView { side(c) }.scrollIndicators(.never).frame(width: 380)
                }
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 24)
            .onDisappear { audio.stop() }
        } else {
            EmptyState(symbol: "viewfinder", tag: "Captures", title: "This capture is gone", message: "It may have been deleted.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func topRow(_ c: Capture) -> some View {
        HStack(spacing: 8) {
            Button { state.navigate(.captures) } label: { Text("← Captures").font(DS.bodySM).foregroundStyle(DS.text2) }
                .buttonStyle(.plain).handCursor()
            if let col = c.collection {
                Text("/").font(DS.bodySM).foregroundStyle(DS.text3)
                Button {
                    state.capturesTag = nil
                    state.capturesFolder = .collection(col)
                    state.navigate(.captures)
                } label: { Text(col).font(DS.bodySM).foregroundStyle(DS.text) }
                    .buttonStyle(.plain).handCursor()
            }
            Spacer()
            if let link = c.links.first, let url = URL(string: link) {
                Button("Open link") { NSWorkspace.shared.open(url) }.buttonStyle(.secondary)
            }
            Button("Copy for AI") { CaptureActions.copyForAI(c) }.buttonStyle(.secondary)
                .help("Copies the picture with what you said, the links and the text in it — paste into Claude or any chat")
            Menu {
                Button("Copy Picture Only") { CaptureActions.copyImage(c) }
                Button("Copy Details Only") { CaptureActions.copyText(c) }
                if c.hasAudio { Button("Transcribe Again from Recording") { CaptureController.transcribeAgain(c.id) } }
                Divider()
                Button("Show Picture in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.imageURL]) }
                if c.hasClip {
                    Button("Show Clip in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.clipURL]) }
                    Button("Delete Clip, Keep Picture") { library.deleteClip(c) }
                }
                Divider()
                Button("Delete Capture", role: .destructive) { library.delete(c); state.navigate(.captures) }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 22) }
                .menuStyle(.button).buttonStyle(.secondary).menuIndicator(.hidden).fixedSize()
        }
    }

    private func picture(_ c: Capture) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if c.hasClip {
                ClipPlayerView(url: c.clipURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                ClipKeyFrames(url: c.clipURL)
            } else {
                CaptureThumb(id: c.id, maxPixel: 2400, fit: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(c.imageURL) }
            }
            HStack(spacing: 6) {
                if let s = c.clipSeconds, s > 0 { Badge("Clip · \(CaptureStripView.clock(s))") }
                Badge("\(c.width) × \(c.height)")
                if let app = c.sourceApp { Badge(app) }
                Text("Saved \(Self.savedDate(c.created))").font(DS.caption).foregroundStyle(DS.text2)
                Spacer()
            }
        }
        .padding(16)
        .card(16)
    }

    @ViewBuilder private func side(_ c: Capture) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(c.title).font(DS.headingMD).foregroundStyle(DS.text).textSelection(.enabled)

            box {
                HStack {
                    Text(c.noteTyped ? "What you typed" : "What you said").font(DS.bodySM).foregroundStyle(DS.text)
                    Spacer()
                    if !editing {
                        Button(c.note.isEmpty ? "Add words" : "Edit") { draft = c.note; editing = true }
                            .buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.link).handCursor()
                    }
                    if c.hasAudio { Text(CaptureStripView.clock(c.audioSeconds)).font(DS.caption).foregroundStyle(DS.text2) }
                }
                if c.hasAudio && !editing {
                    HStack(spacing: 10) {
                        Button { audio.toggle(c.audioURL) } label: {
                            Image(systemName: audio.playing ? "pause.fill" : "play.fill").font(.system(size: 11))
                                .foregroundStyle(DS.onBrand).frame(width: 28, height: 28).background(Circle().fill(DS.brand))
                        }
                        .buttonStyle(.plain).handCursor()
                        ProgressView(value: audio.progress).tint(Color(hex: 0x8B5CF6))
                    }
                }
                if editing {
                    TextEditor(text: $draft).font(DS.body).frame(minHeight: 80).scrollContentBackground(.hidden)
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(DS.surface2))
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }.buttonStyle(.plainP)
                        Button("Save") { saveNote(c) }.buttonStyle(.primary)
                    }
                } else {
                    Text(c.note.isEmpty ? "Nothing said. Add words any time." : "“\(c.note)”")
                        .font(DS.px(15)).foregroundStyle(c.note.isEmpty ? DS.text3 : DS.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !c.links.isEmpty {
                box {
                    Text("Links").font(DS.bodySM).foregroundStyle(DS.text)
                    ForEach(c.linkItems, id: \.self) { link in
                        HStack(spacing: 6) {
                            Image(systemName: link.label.contains(" at ") ? "play.rectangle" : "globe")
                                .font(.system(size: 10)).foregroundStyle(DS.text2)
                            Button { if let u = URL(string: link.url) { NSWorkspace.shared.open(u) } } label: {
                                Text(link.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: ""))
                                    .font(DS.caption).foregroundStyle(DS.link).lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(.plain).handCursor()
                            Spacer()
                            Text(link.label).font(DS.caption).lineLimit(1).fixedSize()
                                .foregroundStyle(link.pasted ? DS.Tone.magic.fg : DS.text2)
                        }
                    }
                }
            }

            if let path = c.filePath {
                // Shared from Finder: Orca remembers where the file is rather than keeping a copy.
                let url = URL(fileURLWithPath: path)
                let exists = FileManager.default.fileExists(atPath: path)
                box {
                    Text("File").font(DS.bodySM).foregroundStyle(DS.text)
                    HStack(spacing: 6) {
                        Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(DS.text2)
                        Button { NSWorkspace.shared.open(url) } label: {
                            Text(url.lastPathComponent).font(DS.caption).foregroundStyle(exists ? DS.link : DS.text3)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain).handCursor().disabled(!exists)
                        Spacer()
                        if exists {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.link).handCursor()
                        } else {
                            Text("Moved or deleted").font(DS.caption).foregroundStyle(DS.text3)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                if let due = c.reminderDate {
                    box {
                        Label("Apple Reminders", systemImage: "bell").font(DS.bodySM).foregroundStyle(DS.text)
                        Text(Self.reminderDate(due)).font(DS.bodySM).foregroundStyle(DS.text)
                        if let p = c.reminderPhrase { Text("from “\(p)”").font(DS.caption).foregroundStyle(DS.Tone.magic.fg) }
                        if c.reminderID != nil {
                            Button("Open in Reminders ↗") { RemindersBridge.openApp() }
                                .buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.link).handCursor()
                        }
                    }
                }
                box {
                    HStack {
                        Label("Collection", systemImage: "folder").font(DS.bodySM).foregroundStyle(DS.text)
                        Spacer()
                        Menu("Change") {
                            ForEach(library.collections, id: \.name) { col in
                                Button(col.name) { setCollection(c, col.name) }
                            }
                            Divider()
                            Button("New Collection…") { newCollection = ""; askingCollection = true }
                            if c.collection != nil { Button("Remove from Collection") { setCollection(c, nil) } }
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .font(DS.caption).foregroundStyle(DS.link)
                        .popover(isPresented: $askingCollection, arrowEdge: .bottom) {
                            NewCollectionPopover(existing: library.collections.map(\.name)) { name in
                                askingCollection = false
                                if let name { setCollection(c, name) }
                            }
                        }
                    }
                    Text(c.collection ?? "None").font(DS.bodySM).foregroundStyle(c.collection == nil ? DS.text3 : DS.text)
                    if let p = c.collectionPhrase, c.collection != nil {
                        Text("from “\(p)”").font(DS.caption).foregroundStyle(DS.Tone.magic.fg)
                    }
                }
            }

            tagsBox(c)

            if !c.ocr.isEmpty {
                box {
                    Text("Text Orca read").font(DS.bodySM).foregroundStyle(DS.text)
                    Text(c.ocr.replacingOccurrences(of: "\n", with: " "))
                        .font(DS.caption).foregroundStyle(DS.text2).lineLimit(8).textSelection(.enabled)
                }
            }

            let related = related(c)
            if !related.isEmpty {
                PixelLabel(c.collection.map { "Also in \($0)" } ?? "Saved around the same time")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(related) { r in
                        CaptureThumb(id: r.id, maxPixel: 300, fit: false)
                            .frame(height: 70).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border))
                            .onTapGesture { state.navigate(.capture(r.id)) }
                            .handCursor()
                            .help(r.note.isEmpty ? r.title : r.note)
                    }
                }
            }
        }
    }

    /// T4: tags with where each came from; × removes, + adds.
    private func tagsBox(_ c: Capture) -> some View {
        box {
            HStack {
                Label("Tags", systemImage: "number").font(DS.bodySM).foregroundStyle(DS.text)
                Spacer()
            }
            FlowLayout(spacing: 6) {
                ForEach(c.tagList, id: \.self) { t in
                    let byOrca = c.tagOrigins?[t] == "orca"
                    Button {
                        state.capturesFolder = nil
                        state.capturesTag = t
                        state.navigate(.captures)
                    } label: { Chip(label: "#\(t)", symbol: byOrca ? "sparkle" : nil, style: .normal, onRemove: { removeTag(c, t) }) }
                        .buttonStyle(.plain)
                        .help(byOrca ? "Orca added this from your words and the picture — × if it’s wrong" : "See every capture tagged #\(t)")
                }
                Button { addingTag = true } label: { Chip(label: "+ tag", style: .normal) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $addingTag, arrowEdge: .bottom) {
                        AddTagPopover(existing: library.tagNames, have: c.tagList) { t in
                            addingTag = false
                            if let t { addTag(c, t) }
                        }
                    }
            }
            if let note = tagNote(c) {
                Text(note).font(DS.caption).foregroundStyle(DS.Tone.magic.fg).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Only says something when it helps: how to add tags, or that ✦ tags were Orca's guess. Tags you added or
    /// said need no label — you know where they came from.
    private func tagNote(_ c: Capture) -> String? {
        if c.tagList.isEmpty { return "Say “tag it design” while capturing, or add one here. Tags work across collections." }
        if c.tagList.contains(where: { c.tagOrigins?[$0] == "orca" }) { return "✦ Orca’s guesses — × any that don’t fit" }
        return nil
    }

    private func addTag(_ c: Capture, _ t: String) {
        var c = c
        c.addTag(CaptureTags.canonical(t, existing: library.tagNames), origin: "you")
        library.update(c)
    }

    private func removeTag(_ c: Capture, _ t: String) {
        var c = c
        c.removeTag(t)
        library.update(c)
    }

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(12)
    }

    private func related(_ c: Capture) -> [Capture] {
        let others = library.items.filter { $0.id != c.id }
        if let col = c.collection {
            return Array(others.filter { $0.collection.map { SpokenIntent.same($0, col) } ?? false }.prefix(6))
        }
        return Array(others.sorted { abs($0.created.timeIntervalSince(c.created)) < abs($1.created.timeIntervalSince(c.created)) }.prefix(3))
    }

    private func saveNote(_ c: Capture) {
        var c = c
        c.note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        c.noteTyped = c.audioSeconds == 0
        if c.collection == nil {
            let intent = SpokenIntent.parse(c.note, existing: library.collections.map(\.name), existingTags: library.tagNames)
            c.collection = intent.collection
            c.collectionPhrase = intent.collectionPhrase
        }
        for t in SpokenIntent.parse(c.note, existing: [], existingTags: library.tagNames).tags { c.addTag(t, origin: "said") }
        library.update(c)
        editing = false
    }

    private func setCollection(_ c: Capture, _ name: String?) {
        var c = c
        c.collection = name?.trimmingCharacters(in: .whitespaces)
        c.collectionPhrase = nil
        library.update(c)
    }

    static func savedDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM · H:mm"; return f.string(from: d)
    }
    static func reminderDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, H:mm"; return f.string(from: d)
    }
}

/// Plays back what was said.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ url: URL) {
        if playing { player?.pause(); playing = false; timer?.invalidate(); return }
        if player?.url != url { player = try? AVAudioPlayer(contentsOf: url); player?.delegate = self }
        guard let player else { return }
        player.play()
        playing = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() { player?.stop(); playing = false; timer?.invalidate(); progress = 0 }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { self.playing = false; self.progress = 0; self.timer?.invalidate() }
    }
}

// MARK: - Settings › Captures

struct CapturesSettings: View {
    @Environment(AppState.self) private var state
    @State private var desktopLinked = MCPServer.isInClaudeDesktop
    @State private var message: String?
    @State private var screenOK = ScreenGrab.hasPermission
    @State private var pageOK = PageInspector.isAllowed

    var body: some View {
        @Bindable var p = state.prefs
        VStack(alignment: .leading, spacing: 18) {
            group("Capture") {
                line("Grab part of the screen with a shortcut") { Toggle("", isOn: $p.capturesEnabled).toggleStyle(.switch).labelsHidden() }
                line("Shortcut") { ShortcutRecorder(combo: $p.captureHotKey, defaultCombo: .defaultCapture) }
                line("Keep a short clip when what you grab is moving") { Toggle("", isOn: $p.captureClips).toggleStyle(.switch).labelsHidden() }
                line("Add tags with Apple Intelligence") {
                    HStack(spacing: 8) {
                        if SentenceUnderstanding.status != .available { Text(SentenceUnderstanding.statusText).font(DS.caption).foregroundStyle(DS.text2) }
                        Toggle("", isOn: $p.captureAutoTags).toggleStyle(.switch).labelsHidden()
                    }
                }
                line("Keep the exact pin, post or video moment") {
                    if pageOK { Badge("Allowed", tone: .success) }
                    else { Button("Allow…") { PageInspector.askForAccess(); PageInspector.openSettings() }.buttonStyle(.secondary) }
                }
                line("Screen access", last: true) {
                    if screenOK { Badge("Allowed", tone: .success) }
                    else {
                        Button("Allow…") { ScreenGrab.requestPermission(); ScreenGrab.openPrivacySettings() }.buttonStyle(.secondary)
                    }
                }
            }
            Text("Press the shortcut in any app, drag over anything, then talk. Stop talking for 2 seconds and it’s saved. Tab types instead, ⌘V attaches a link, Esc throws it away. Say “for the newsletter” to file it, “tag it design” to tag it, or “remind me Thursday” to add it to Apple Reminders. If something in the box is moving, Orca keeps a clip of up to 30 seconds — V while talking switches between clip and picture. From a browser, Orca keeps the page link by itself; with Accessibility allowed it also keeps the exact pin or post you grabbed from a feed, and the moment a YouTube video was at.")
                .font(DS.caption).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)

            VoiceNotesSettings()

            group("Use your captures in Claude") {
                line("Claude Desktop") {
                    if desktopLinked { Badge("Connected · restart Claude to load it", tone: .success) }
                    else {
                        Button("Add Orca to Claude") {
                            message = MCPServer.addToClaudeDesktop()
                            desktopLinked = MCPServer.isInClaudeDesktop
                        }.buttonStyle(.primary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Claude Code").font(DS.body).foregroundStyle(DS.text)
                        Spacer()
                        Button("Copy command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(MCPServer.claudeCodeCommand, forType: .string)
                            state.showToast("Copied — paste it in Terminal")
                        }.buttonStyle(.secondary)
                    }
                    Text(MCPServer.claudeCodeCommand).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.text2)
                        .textSelection(.enabled).lineLimit(2)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            if let message { Text(message).font(DS.caption).foregroundStyle(DS.critical) }
            Text("Claude can then search what you saved and read why you saved it — e.g. “draft Friday’s newsletter from what I saved for it this week”. It reads from your Mac only; nothing is uploaded until Claude uses it in a chat.")
                .font(DS.caption).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)

            group("Storage") {
                line("\(Fmt.plural(CaptureLibrary.shared.items.count, "capture")) on this Mac", last: true) {
                    Button("Show in Finder") { NSWorkspace.shared.open(CaptureStore.folder) }.buttonStyle(.secondary)
                }
            }
        }
        .onAppear { screenOK = ScreenGrab.hasPermission; pageOK = PageInspector.isAllowed; desktopLinked = MCPServer.isInClaudeDesktop }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PixelLabel(title)
            VStack(spacing: 0) { content() }.background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
        }
    }

    private func line<R: View>(_ label: String, last: Bool = false, @ViewBuilder _ right: () -> R) -> some View {
        VStack(spacing: 0) {
            HStack { Text(label).font(DS.body).foregroundStyle(DS.text); Spacer(); right() }.padding(.horizontal, 14).padding(.vertical, 10)
            if !last { Rectangle().fill(DS.border).frame(height: 1) }
        }
    }
}


/// "New collection" — same look as the other Orca popovers (pixel label, focused field, quiet buttons).
struct NewCollectionPopover: View {
    let existing: [String]
    let done: (String?) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let match = existing.first { SpokenIntent.same($0, trimmed) }
        VStack(alignment: .leading, spacing: 12) {
            PixelLabel("New collection")
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(DS.text2)
                TextField("", text: $name, prompt: Text("Name, e.g. Newsletter").foregroundStyle(DS.text3))
                    .textFieldStyle(.plain).font(DS.body).focused($focused)
                    .onSubmit { if !trimmed.isEmpty { done(match ?? trimmed) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.focus, lineWidth: 1.5))
            if let match {
                Text("“\(match)” already exists — this adds it there.").font(DS.caption).foregroundStyle(DS.text2)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 10)).padding(.top, 2)
                Text("Next time, just say “for the \(trimmed.isEmpty ? "newsletter" : trimmed.lowercased())” while capturing.")
                    .font(DS.caption).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DS.Tone.magic.fg)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Tone.magic.bg))
            Rectangle().fill(DS.border).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(.plainP).keyboardShortcut(.cancelAction)
                Button(match == nil ? "Add" : "Move there") { done(match ?? trimmed) }
                    .buttonStyle(.primary).disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(DS.surface2)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}


// MARK: - Tags & clips

struct AddTagPopover: View {
    let existing: [String]
    let have: [String]
    let done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let typed = CaptureTags.normalize(text)
        let options = existing.filter { e in !have.contains { CaptureTags.same($0, e) } && (text.isEmpty || e.hasPrefix(typed ?? text.lowercased())) }
        VStack(alignment: .leading, spacing: 12) {
            PixelLabel("Add a tag")
            HStack(spacing: 8) {
                Image(systemName: "number").font(.system(size: 12)).foregroundStyle(DS.text2)
                TextField("", text: $text, prompt: Text("design, pricing, to read…").foregroundStyle(DS.text3))
                    .textFieldStyle(.plain).font(DS.body).focused($focused)
                    .onSubmit { if let typed { done(typed) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.focus, lineWidth: 1.5))
            if !options.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(options.prefix(12), id: \.self) { t in
                        Button { done(t) } label: { Chip(label: "#\(t)", style: .normal) }.buttonStyle(.plain)
                    }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 10)).padding(.top, 2)
                Text("Next time, just say “tag it \(typed ?? "design")” while capturing.").font(DS.caption).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(DS.Tone.magic.fg)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Tone.magic.bg))
            Rectangle().fill(DS.border).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(.plainP).keyboardShortcut(.cancelAction)
                Button("Add") { if let typed { done(typed) } }.buttonStyle(.primary).disabled(typed == nil)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(DS.surface2)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// Silent looping clip (cards play it on hover).
struct LoopingClipView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> LoopingClipNSView { LoopingClipNSView(url: url) }
    func updateNSView(_ v: LoopingClipNSView, context: Context) {}
    static func dismantleNSView(_ v: LoopingClipNSView, coordinator: ()) { v.player.pause() }
}

final class LoopingClipNSView: NSView {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspect
        return l
    }
}

/// The clip on the capture page: loops silently, with the standard scrubber.
struct ClipPlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator { var looper: AVPlayerLooper? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        v.player = player
        player.play()
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ v: AVPlayerView, coordinator: Coordinator) { v.player?.pause() }
}

/// K3: the four stills AI tools get instead of the video.
struct ClipKeyFrames: View {
    let url: URL
    @State private var frames: [(time: Double, image: NSImage)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("What Claude sees · \(max(frames.count, 4)) key frames").font(DS.bodySM).foregroundStyle(DS.text)
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, f in
                    Image(nsImage: f.image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border))
                        .overlay(alignment: .bottomLeading) {
                            Text(String(format: "%.1f s", f.time)).font(DS.caption).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7))).padding(5)
                        }
                }
                if frames.isEmpty { ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(DS.surface2).frame(height: 64) } }
            }
            Text("Sent with what you said over MCP and with Copy for AI (plus the clip file).").font(DS.caption).foregroundStyle(DS.text2)
        }
        .task(id: url) {
            let url = url
            let got = await Task.detached(priority: .utility) { await ClipFrames.frames(url, count: 4, maxPixel: 360) }.value
            frames = got.map { ($0.time, NSImage(cgImage: $0.image, size: NSSize(width: $0.image.width, height: $0.image.height))) }
        }
    }
}
