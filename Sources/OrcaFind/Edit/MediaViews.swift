import SwiftUI
import AVKit
import AppKit

// MARK: - Player

struct MediaPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var controls = true
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = false
        v.allowsPictureInPicturePlayback = false
        v.controlsStyle = controls ? .inline : .none
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
        let style: AVPlayerViewControlsStyle = controls ? .inline : .none
        if v.controlsStyle != style { v.controlsStyle = style }
    }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

private func fitted(_ px: CGSize, in avail: CGSize) -> CGSize {
    guard px.width > 0, px.height > 0, avail.width > 0, avail.height > 0 else { return CGSize(width: max(1, avail.width), height: max(1, avail.height)) }
    let s = min(avail.width / px.width, avail.height / px.height, 2)
    return CGSize(width: (px.width * s).rounded(), height: (px.height * s).rounded())
}

/// The dark pill at the top of the stage while something long runs.
struct MediaBusyPill: View {
    let text: String?
    var body: some View {
        if let text {
            VStack {
                DarkPill {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(text).font(DS.bodySM).monospacedDigit()
                }
                .padding(.top, 18)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Video stage

struct VideoStage: View {
    @Bindable var ws: VideoWorkspace

    var body: some View {
        ZStack {
            if let err = ws.loadError {
                EmptyState(symbol: "film", tag: "Video", title: "Can’t open this video", message: err)
            } else if ws.info == nil {
                ProgressView().controlSize(.small)
            } else {
                GeometryReader { geo in
                    let trackW = max(200, min(geo.size.width - 64, 820))
                    let fit = fitted(ws.displaySize, in: CGSize(width: geo.size.width - 64, height: geo.size.height - 140))
                    VStack(spacing: 18) {
                        Spacer(minLength: 0)
                        ZStack(alignment: .topLeading) {
                            picture
                            if ws.active == .cropVideo { VideoCropOverlay(ws: ws, size: fit) }
                        }
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                        VStack(spacing: 8) {
                            TrimTrack(ws: ws, height: 52, dim: Color.black.opacity(0.55)) { ThumbStrip(images: ws.thumbs) }
                            TrimLabels(ws: ws)
                        }
                        .frame(width: trackW)
                        Spacer(minLength: 0)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            MediaBusyPill(text: ws.busy)
        }
        .onDisappear { ws.player.pause() }
    }

    @ViewBuilder
    private var picture: some View {
        if MediaEngine.isSnapshotRun {
            if let p = ws.poster { Image(decorative: p, scale: 1).resizable() } else { Color.black }
        } else {
            MediaPlayerView(player: ws.player, controls: ws.active != .cropVideo)
        }
    }
}

struct ThumbStrip: View {
    let images: [CGImage]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if images.isEmpty {
                    DS.tertiary
                } else {
                    ForEach(images.indices, id: \.self) { i in
                        Image(decorative: images[i], scale: 1).resizable().scaledToFill()
                            .frame(width: geo.size.width / CGFloat(images.count), height: geo.size.height)
                            .clipped()
                    }
                }
            }
        }
        .background(Color.black)
    }
}

// MARK: - Trim bar (video thumbnails or audio waveform underneath)

struct TrimTrack<WS: TrimmableMedia, Content: View>: View {
    let ws: WS
    var height: CGFloat = 52
    var dim: Color = Color.black.opacity(0.55)
    @ViewBuilder let content: () -> Content
    @State private var grab: CGFloat?

    static var yellow: Color { Color(hex: 0xFFC629) }
    private let hw: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let inner = max(1, w - 2 * hw)
            let xs = x(ws.trimStart, inner), xe = x(ws.trimEnd, inner)
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: inner, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .offset(x: hw)
                    .allowsHitTesting(false)
                Rectangle().fill(dim).frame(width: max(0, xs - hw), height: height).offset(x: hw).allowsHitTesting(false)
                Rectangle().fill(dim).frame(width: max(0, w - hw - xe), height: height).offset(x: xe).allowsHitTesting(false)
                // Click or drag anywhere to move the playhead.
                Color.clear.contentShape(Rectangle())
                    .frame(width: w, height: height)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                        .onChanged { g in ws.seek(to: time(g.location.x, inner)) })
                // Yellow frame round the kept part
                Path { p in
                    p.addRect(CGRect(x: xs, y: 0, width: max(0, xe - xs), height: 3))
                    p.addRect(CGRect(x: xs, y: height - 3, width: max(0, xe - xs), height: 3))
                }
                .fill(Self.yellow)
                .allowsHitTesting(false)
                handle(left: true)
                    .offset(x: xs - hw)
                    .gesture(drag(left: true, inner: inner))
                handle(left: false)
                    .offset(x: xe)
                    .gesture(drag(left: false, inner: inner))
                Playhead(ws: ws, height: height, x: { x($0, inner) })
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: height)
    }

    private func x(_ t: Double, _ inner: CGFloat) -> CGFloat {
        hw + CGFloat(min(1, max(0, t / max(0.001, ws.duration)))) * inner
    }

    private func time(_ x: CGFloat, _ inner: CGFloat) -> Double {
        Double(min(1, max(0, (x - hw) / inner))) * ws.duration
    }

    private func handle(left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 6 : 0, bottomLeadingRadius: left ? 6 : 0,
                               bottomTrailingRadius: left ? 0 : 6, topTrailingRadius: left ? 0 : 6)
            .fill(Self.yellow)
            .overlay(
                Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.7))
            )
            .frame(width: hw, height: height)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { $0 ? NSCursor.resizeLeftRight.set() : NSCursor.arrow.set() }
    }

    private func drag(left: Bool, inner: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { g in
                let edge = x(left ? ws.trimStart : ws.trimEnd, inner)
                if grab == nil { grab = g.startLocation.x - edge; ws.beginTrim() }
                let t = time(g.location.x - (grab ?? 0), inner)
                let minLen = max(0.1, min(1.0, ws.duration * 0.05))
                if left {
                    let s = min(max(0, t), ws.trimEnd - minLen)
                    ws.setTrim(start: s, end: ws.trimEnd, showing: s)
                } else {
                    let e = max(min(ws.duration, t), ws.trimStart + minLen)
                    ws.setTrim(start: ws.trimStart, end: e, showing: e)
                }
            }
            .onEnded { _ in grab = nil; ws.endTrim() }
    }
}

/// Its own view so only it redraws as the video plays.
private struct Playhead<WS: TrimmableMedia>: View {
    let ws: WS
    let height: CGFloat
    let x: (Double) -> CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white)
            .frame(width: 3, height: height + 10)
            .shadow(color: .black.opacity(0.45), radius: 2)
            .offset(x: x(ws.currentTime) - 1.5, y: -5)
            .allowsHitTesting(false)
    }
}

struct TrimLabels<WS: TrimmableMedia>: View {
    let ws: WS
    var body: some View {
        HStack {
            Text(MediaEngine.clock(ws.trimStart))
            Spacer()
            Text("\(MediaEngine.clock(ws.trimEnd)) · \(MediaEngine.span(ws.trimEnd - ws.trimStart)) kept")
        }
        .font(DS.caption).foregroundStyle(DS.text2).monospacedDigit()
        .padding(.horizontal, 13)
    }
}

// MARK: - Crop box over the video

struct VideoCropOverlay: View {
    @Bindable var ws: VideoWorkspace
    let size: CGSize
    @State private var start: CGRect?

    var body: some View {
        let r = ws.edits.crop
        let rect = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(rect) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
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
                MediaCornerHandle(corner: h)
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
                if start == nil { start = ws.edits.crop; ws.beginCrop() }
                ws.dragCrop(handle: handle, from: start!, by: CGSize(width: g.translation.width / size.width, height: g.translation.height / size.height))
            }
            .onEnded { _ in start = nil; ws.endCrop() }
    }
}

private struct MediaCornerHandle: View {
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

// MARK: - Audio stage

struct AudioStage: View {
    @Bindable var ws: AudioWorkspace

    var body: some View {
        ZStack {
            if let err = ws.loadError {
                EmptyState(symbol: "waveform", tag: "Audio", title: "Can’t open this sound", message: err)
            } else if let info = ws.info {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Button { ws.togglePlay() } label: {
                            Image(systemName: ws.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(DS.onBrand)
                                .offset(x: ws.playing ? 0 : 1.5)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(DS.brand))
                        }
                        .buttonStyle(.plain).handCursor()
                        .keyboardShortcut(.space, modifiers: [])
                        .help(ws.playing ? "Pause (Space)" : "Play the kept part (Space)")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ws.item.name).font(DS.body).foregroundStyle(DS.text).lineLimit(1)
                            Text("\(info.formatLine) · \(Fmt.size(info.fileSize))").font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
                        }
                        Spacer()
                        AudioClock(ws: ws)
                    }
                    VStack(spacing: 8) {
                        TrimTrack(ws: ws, height: 128, dim: DS.surface.opacity(0.6)) { WaveformView(ws: ws) }
                        TrimLabels(ws: ws)
                    }
                }
                .padding(22)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.border))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
                .frame(maxWidth: 820)
                .padding(.horizontal, 36)
            } else {
                ProgressView().controlSize(.small)
            }
            MediaBusyPill(text: ws.busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { ws.player.pause() }
    }
}

private struct AudioClock: View {
    let ws: AudioWorkspace
    var body: some View {
        Text("\(MediaEngine.clock(ws.currentTime)) / \(MediaEngine.clock(ws.duration))")
            .font(DS.bodySM).foregroundStyle(DS.text2).monospacedDigit()
    }
}

struct WaveformView: View {
    let ws: AudioWorkspace
    var body: some View {
        let bars = ws.bars, start = ws.trimStart, end = ws.trimEnd, now = ws.currentTime, dur = max(0.001, ws.duration)
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(DS.surface2))
            guard !bars.isEmpty else {
                var mid = Path(); mid.move(to: CGPoint(x: 0, y: size.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(mid, with: .color(DS.border), lineWidth: 1)
                return
            }
            let count = max(1, min(bars.count, Int(size.width / 3)))
            let step = size.width / CGFloat(count)
            let per = Double(bars.count) / Double(count)
            let usable = size.height - 20
            for i in 0..<count {
                let a = Int(Double(i) * per), b = max(a + 1, Int(Double(i + 1) * per))
                var v: Float = 0
                for j in a..<min(b, bars.count) { v = max(v, bars[j]) }
                let h = max(2, CGFloat(v) * usable)
                let t = (Double(i) + 0.5) / Double(count) * dur
                let inside = t >= start && t <= end
                let color: Color = !inside ? DS.text3.opacity(0.55) : t <= now ? DS.focus : DS.text.opacity(0.8)
                let rect = CGRect(x: CGFloat(i) * step + step * 0.2, y: (size.height - h) / 2, width: max(1, step * 0.6), height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(1.5, rect.width / 2)), with: .color(color))
            }
        }
    }
}

// MARK: - Options box: video

struct VideoOptions: View {
    @Bindable var ws: VideoWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if ws.loadError != nil {
                OptTitle(ws.item.name)
                OptHint("This video can’t be opened, so there’s nothing to edit.")
            } else if let info = ws.info {
                switch ws.active {
                case nil: about(info)
                case .trim: trim(info)
                case .cropVideo: crop
                case .saveAsMP4: mp4(info)
                case .makeGIF: gif
                case .compressVideo: compress(info)
                case .transcribe:
                    TranscriptBox(text: ws.transcript, error: ws.transcriptError, working: ws.busy == "Listening…",
                                  copy: ws.copyTranscript, save: ws.saveTranscript, retry: ws.runTranscribe)
                case .resizeVideo: resize(info)
                case .stripVideoLocation: location
                default: OptHint(ws.active!.hint)
                }
            } else {
                OptTitle(ws.item.name)
                OptHint("Opening…")
            }
        }
    }

    private func about(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OptTitle(ws.item.name)
            OptRow("Size", "\(Int(info.orientedSize.width)) × \(Int(info.orientedSize.height))")
            OptRow("Length", MediaEngine.clock(info.duration))
            OptRow("File", Fmt.size(info.fileSize))
            if !info.codec.isEmpty { OptRow("Format", "\(info.codec) · \(ws.item.ext.uppercased())") }
            OptRow("Sound", info.hasAudio ? "Yes" : "None")
            if info.hasLocation { OptRow("Location", "Saved in the file") }
            OptHint("Pick a tool here, or use the bar for the usual four.")
        }
    }

    private func trim(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Trim")
            VStack(spacing: 5) {
                OptRow("Start", MediaEngine.clock(ws.trimStart, tenths: info.duration < 600))
                OptRow("End", MediaEngine.clock(ws.trimEnd, tenths: info.duration < 600))
                OptRow("Kept", MediaEngine.span(ws.kept))
            }
            if info.hasAudio {
                Toggle(isOn: Binding(get: { ws.edits.mute }, set: { ws.setMute($0) })) { Text("Mute sound").font(DS.bodySM) }
                    .toggleStyle(.switch).controlSize(.mini)
            }
            OptButton("Reset", symbol: "arrow.counterclockwise") { ws.resetTrim() }
            OptHint("Drag the yellow handles under the video. The copy keeps only what’s between them.")
        }
    }

    private var crop: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Crop")
            // Two rows so "Square" isn't squeezed.
            OptChoice(options: [VideoWorkspace.Aspect.free, .square].map(\.rawValue), selection: ws.aspect.rawValue) { ws.aspect = VideoWorkspace.Aspect(rawValue: $0)! }
            OptChoice(options: [VideoWorkspace.Aspect.wide, .tall, .fourThree].map(\.rawValue), selection: ws.aspect.rawValue) { ws.aspect = VideoWorkspace.Aspect(rawValue: $0)! }
            OptCaption("\(Int(ws.outputSize(short: ws.edits.size).width)) × \(Int(ws.outputSize(short: ws.edits.size).height)) px")
            HStack(spacing: 6) {
                OptButton("Rotate", symbol: "rotate.left") { ws.select(.rotateVideo) }
                OptButton("Flip", symbol: ToolID.flipVideo.symbol) { ws.select(.flipVideo) }
            }
            HStack(spacing: 6) {
                OptButton("Reset", symbol: "arrow.counterclockwise") { ws.resetCrop() }
                OptButton("Done", symbol: "checkmark", primary: true) { ws.doneCropping() }
            }
            OptHint("Drag the corners, or move the box. The copy keeps what’s inside.")
        }
    }

    private func sizeEstimate(_ bytes: Int64, was: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("About \(Fmt.size(bytes))").font(DS.headingSM).foregroundStyle(DS.text)
            OptCaption("was \(Fmt.size(was)) · Save copy in the top bar")
        }
    }

    private func qualityLabel(_ s: Int?) -> String { s.map { "\($0)p" } ?? "Original" }

    private func mp4(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Save as MP4")
            OptCaption("Quality")
            OptChoice(options: ["Original", "1080p", "720p"], selection: qualityLabel(ws.edits.size)) {
                ws.setMP4Quality($0 == "Original" ? nil : Int($0.dropLast()))
            }
            OptCaption("\(Int(ws.outputSize.width)) × \(Int(ws.outputSize.height)) px")
            OptHint(ws.item.ext.lowercased() == "mp4" ? "It’s already an MP4; this saves a copy at the size you pick." : "MP4 plays everywhere: Windows, Android, the web.")
            sizeEstimate(ws.estimatedBytes, was: info.fileSize)
        }
    }

    private var gif: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Make a GIF")
            OptCaption("Width")
            OptChoice(options: ["320", "480", "640"], selection: "\(ws.gif.width)") { ws.gif.width = Int($0) ?? 480 }
            OptCaption("Frames a second")
            OptChoice(options: ["10", "15"], selection: "\(ws.gif.fps)") { ws.gif.fps = Int($0) ?? 10 }
            VStack(spacing: 5) {
                OptRow("Length", MediaEngine.span(ws.kept))
                OptRow("Frames", Fmt.count(ws.gifFrames))
            }
            Divider()
            Text(ws.gifEstimate.map { "About \(Fmt.size($0))" } ?? "Working it out…").font(DS.headingSM).foregroundStyle(DS.text)
            OptButton("Make GIF", symbol: ToolID.makeGIF.symbol, primary: true) { ws.makeGIF() }
                .disabled(ws.busy != nil)
            OptHint(ws.kept > 12 ? "Long GIFs get big. Trim it to a few seconds first." : "Uses the trimmed part, with any crop. Saved as its own file, loops forever.")
        }
    }

    private func compress(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OptTitle("Compress")
            ForEach(VideoCompress.allCases, id: \.self) { c in
                OptRadioRow(title: c.rawValue, detail: "\(c.detail) · about \(Fmt.size(ws.estimate(compress: c)))", selected: ws.edits.compress == c) { ws.setCompress(c) }
            }
            OptHint(ws.estimatedBytes >= info.fileSize ? "This video is already small. The copy won’t be much smaller." : compressHint)
            sizeEstimate(ws.estimatedBytes, was: info.fileSize)
        }
    }

    private var compressHint: String {
        let mb = Double(ws.estimatedBytes) / 1_000_000
        switch ws.edits.compress {
        case .mail?: return mb < 20 ? "Small enough for Mail." : "Still over 20 MB. Trim it shorter to send it by Mail."
        case .messages?: return mb < 100 ? "Small enough for Messages." : "Still big. Trim it shorter for Messages."
        default: return "The smallest file that still looks fine on a phone."
        }
    }

    private func resize(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Resize")
            OptChoice(options: ["Original", "1080p", "720p", "480p"], selection: qualityLabel(ws.edits.size)) {
                ws.setSize($0 == "Original" ? nil : Int($0.dropLast()))
            }
            OptCaption("\(Int(ws.outputSize.width)) × \(Int(ws.outputSize.height)) px")
            OptHint("Never makes it bigger than it is.")
            sizeEstimate(ws.estimatedBytes, was: info.fileSize)
        }
    }

    private var location: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Remove location")
            Toggle(isOn: Binding(get: { ws.edits.stripLocation }, set: { ws.setStripLocation($0) })) { Text("Remove location").font(DS.bodySM) }
                .toggleStyle(.switch).controlSize(.mini)
            OptHint("This video knows where it was filmed. The copy keeps the picture and sound but drops the place and other personal details.")
        }
    }
}

// MARK: - Options box: audio

struct AudioOptions: View {
    @Bindable var ws: AudioWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if ws.loadError != nil {
                OptTitle(ws.item.name)
                OptHint("This file can’t be opened, so there’s nothing to edit.")
            } else if let info = ws.info {
                switch ws.active {
                case nil: about(info)
                case .trimAudio: trim(info)
                case .transcribeAudio:
                    TranscriptBox(text: ws.transcript, error: ws.transcriptError, working: ws.busy == "Listening…",
                                  copy: ws.copyTranscript, save: ws.saveTranscript, retry: ws.runTranscribe)
                case .convertAudio: convert(info)
                case .compressAudio: compress(info)
                default: OptHint(ws.active!.hint)
                }
            } else {
                OptTitle(ws.item.name)
                OptHint("Opening…")
            }
        }
    }

    private func about(_ info: AudioInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OptTitle(ws.item.name)
            OptRow("Length", MediaEngine.clock(info.duration))
            OptRow("Format", info.codec)
            OptRow("Sound", info.channels == 1 ? "Mono" : info.channels == 2 ? "Stereo" : "\(info.channels) channels")
            OptRow("File", Fmt.size(info.fileSize))
            OptHint("Pick a tool here, or use the bar for the usual four.")
        }
    }

    private func trim(_ info: AudioInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Trim")
            VStack(spacing: 5) {
                OptRow("Start", MediaEngine.clock(ws.trimStart, tenths: info.duration < 600))
                OptRow("End", MediaEngine.clock(ws.trimEnd, tenths: info.duration < 600))
                OptRow("Kept", MediaEngine.span(ws.kept))
            }
            OptButton("Reset", symbol: "arrow.counterclockwise") { ws.resetTrim() }
            OptHint("Drag the yellow handles on the waveform. Space plays the kept part.")
        }
    }

    private func estimate(_ info: AudioInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("About \(Fmt.size(ws.estimatedBytes))").font(DS.headingSM).foregroundStyle(DS.text)
            OptCaption("was \(Fmt.size(info.fileSize)) · Save copy in the top bar")
        }
    }

    private var formatName: String {
        switch ws.edits.out {
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        default: return "M4A"
        }
    }

    private func convert(_ info: AudioInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Convert")
            OptChoice(options: ["M4A", "WAV", "AIFF"], selection: formatName) {
                ws.setOut($0 == "WAV" ? .wav : $0 == "AIFF" ? .aiff : .m4a(kbps: 256))
            }
            switch ws.edits.out {
            case .wav: OptHint("Uncompressed. Big, but every app opens it.")
            case .aiff: OptHint("Uncompressed, the Mac’s own format.")
            default: OptHint("AAC in an .m4a: small and plays almost anywhere.")
            }
            OptHint("MP3 isn’t possible: Apple’s frameworks can’t write it. M4A plays anywhere MP3 does.")
            estimate(info)
        }
    }

    private func compress(_ info: AudioInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OptTitle("Compress")
            ForEach([(64, "Voice and podcasts"), (96, "Good for most things"), (128, "Music")], id: \.0) { k, label in
                OptRadioRow(title: "\(k) kbps · \(label)", detail: "about \(Fmt.size(ws.estimate(.m4a(kbps: k))))", selected: ws.edits.out == .m4a(kbps: k)) {
                    ws.setOut(.m4a(kbps: k))
                }
            }
            if ws.estimatedBytes >= info.fileSize {
                OptHint("This file is already small. The copy won’t be any smaller.")
            } else {
                OptHint("Saved as AAC in an .m4a.")
            }
            estimate(info)
        }
    }
}

// MARK: - Shared pieces

struct TranscriptBox: View {
    let text: String?
    let error: String?
    let working: Bool
    let copy: () -> Void
    let save: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OptTitle("Transcribe")
            if working {
                OptHint("Listening to the sound… Long files take a while.")
            } else if let error {
                OptHint(error)
                OptButton("Try again", symbol: "arrow.clockwise") { retry() }
            } else if let text {
                ScrollView {
                    Text(text).font(DS.caption).foregroundStyle(DS.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(DS.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border))
                OptCaption(Fmt.plural(text.split(whereSeparator: { $0.isWhitespace }).count, "word"))
                HStack(spacing: 6) {
                    OptButton("Copy", symbol: "doc.on.doc", primary: true) { copy() }
                    OptButton("Save as text", symbol: "doc.plaintext") { save() }
                }
            }
        }
    }
}

struct OptRadioRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .strokeBorder(selected ? DS.focus : DS.borderStrong, lineWidth: selected ? 4 : 1.2)
                    .frame(width: 12, height: 12)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.caption).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(DS.caption).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? DS.surface : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? DS.focus.opacity(0.6) : DS.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }
}
