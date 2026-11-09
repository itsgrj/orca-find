import SwiftUI
import AVFoundation
import AppKit

@MainActor
enum MediaWorkspaceFactory {
    static func make(_ item: FileItem, kind: EditKind) -> EditWorkspace {
        kind == .audio ? AudioWorkspace(item: item) : VideoWorkspace(item: item)
    }
}

/// What the shared trim bar needs from either workspace.
@MainActor
protocol TrimmableMedia: AnyObject, Observable {
    var duration: Double { get }
    var trimStart: Double { get }
    var trimEnd: Double { get }
    var currentTime: Double { get }
    func beginTrim()
    func setTrim(start: Double, end: Double, showing: Double)
    func endTrim()
    func seek(to seconds: Double)
}

/// Keeps progress callbacks from a finished job from writing over the next one.
@MainActor
final class BusyTicket {
    private var n = 0
    func next() -> Int { n += 1; return n }
    func isCurrent(_ k: Int) -> Bool { k == n }
}

// MARK: - Video

/// Videos. Each tool sets something up (trim, crop, turn, size, sound, format); "Save copy" writes one
/// file with all of it. GIF, frame, sound and transcript are separate files made straight away.
@MainActor
@Observable
final class VideoWorkspace: EditWorkspace, TrimmableMedia {
    let item: FileItem
    let kind: EditKind = .video
    private(set) var info: VideoInfo?
    private(set) var loadError: String?
    private(set) var active: ToolID?
    private(set) var busy: String?

    private(set) var edits = VideoEdits()
    @ObservationIgnored private var original = VideoEdits()
    private var history: [VideoEdits] = []
    @ObservationIgnored private var dragBase: VideoEdits?

    // Playback
    let player = AVPlayer()
    @ObservationIgnored private var playerItem: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    private(set) var currentTime: Double = 0
    private(set) var thumbs: [CGImage] = []
    /// Stands in for the player in offscreen snapshots.
    private(set) var poster: CGImage?

    // Crop
    enum Aspect: String, CaseIterable { case free = "Free", square = "Square", wide = "16:9", tall = "9:16", fourThree = "4:3" }
    var aspect: Aspect = .free { didSet { applyAspect() } }

    // GIF
    var gif = MediaEngine.GIFSettings() { didSet { if gif != oldValue { estimateGIF() } } }
    private(set) var gifEstimate: Int64?
    @ObservationIgnored private var gifTask: Task<Void, Never>?

    // Transcript
    private(set) var transcript: String?
    private(set) var transcriptError: String?

    @ObservationIgnored private let ticket = BusyTicket()

    init(item: FileItem) {
        self.item = item
        Task { await load() }
    }

    private func load() async {
        do {
            let i = try await MediaEngine.loadVideo(item.url)
            guard i.hasVideo else { loadError = "There’s no picture in this file."; return }
            info = i
            edits = VideoEdits(start: 0, end: i.duration)
            original = edits
            let pi = AVPlayerItem(asset: AVURLAsset(url: item.url))
            playerItem = pi
            player.replaceCurrentItem(with: pi)
            player.actionAtItemEnd = .pause
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.tick(t.seconds) }
            }
            applyPreview()
            if MediaEngine.isSnapshotRun, let t = ProcessInfo.processInfo.environment["ORCA_SNAPSHOT_TRIM"]?.split(separator: ",").compactMap({ Double($0) }), t.count == 2 {
                change { $0.start = t[0]; $0.end = t[1] }
                seek(to: (t[0] + t[1]) / 2)
            }
            thumbs = await MediaEngine.thumbnails(url: item.url, count: 10, height: 56)
        } catch {
            loadError = (error as NSError).domain == AVFoundationErrorDomain
                ? "It may be damaged, still downloading from iCloud, or in a format this Mac can’t play."
                : error.localizedDescription
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        // Playback stays inside the kept part.
        if player.rate > 0 && (t < edits.start - 0.1 || t > edits.end + 0.05) { seek(to: edits.start) }
    }

    // MARK: Tool lists

    var bar: [ToolID] { [.trim, .saveAsMP4, .makeGIF, .compressVideo] }

    var groups: [ToolGroup] {
        [ToolGroup(title: "Trim", tools: [.trim, .saveFrame, .cropVideo, .rotateVideo]),
         ToolGroup(title: "Save as", tools: [.saveAsMP4, .makeGIF, .extractAudio, .compressVideo]),
         ToolGroup(title: "More", tools: [.transcribe, .resizeVideo, .flipVideo, .muteVideo, .stripVideoLocation])]
    }

    func isAvailable(_ tool: ToolID) -> Bool {
        if loadError != nil { return false }
        guard let info else { return true }
        switch tool {
        case .extractAudio, .transcribe, .muteVideo: return info.hasAudio
        case .stripVideoLocation: return info.hasLocation
        case .resizeVideo: return min(info.orientedSize.width, info.orientedSize.height) > 480
        default: return true
        }
    }

    // MARK: State

    var duration: Double { info?.duration ?? 0 }
    var trimStart: Double { edits.start }
    var trimEnd: Double { edits.end }
    var kept: Double { max(0, edits.end - edits.start) }
    var isTrimmed: Bool { info != nil && (edits.start > 0.05 || edits.end < duration - 0.05) }
    var canUndo: Bool { !history.isEmpty }
    var hasEdits: Bool { info != nil && edits != original }

    private var labels: [String] {
        guard let info else { return [] }
        var l: [String] = []
        if isTrimmed { l.append("trimmed") }
        if edits.isCropped { l.append("cropped") }
        if edits.turns % 4 != 0 { l.append("rotated") }
        if edits.flip { l.append("flipped") }
        if edits.mute && info.hasAudio { l.append("muted") }
        if edits.compress != nil { l.append("smaller") }
        else if let s = edits.size, min(info.orientedSize.width, info.orientedSize.height) > CGFloat(s) + 1 { l.append("\(s)p") }
        if edits.stripLocation && info.hasLocation { l.append("no location") }
        return l
    }

    var outputExt: String {
        if edits.mp4 || edits.compress != nil { return "mp4" }
        let e = item.ext.lowercased()
        return ["mov", "mp4", "m4v"].contains(e) ? e : "mp4"
    }

    private var suffix: String? {
        let l = labels
        if l.isEmpty { return outputExt == item.ext.lowercased() ? "copy" : nil }
        return l.count == 1 ? l[0] : "edited"
    }

    var status: String? {
        guard hasEdits else { return nil }
        let name = CopySaver.destination(near: item.url, suffix: suffix, ext: outputExt).lastPathComponent
        var l = labels
        if edits.mp4 && edits.compress == nil && item.ext.lowercased() != "mp4" { l.append("as MP4") }
        let what = l.isEmpty ? "Save a copy" : l.joined(separator: " · ").capitalizedFirst
        return "\(what) · will save as \(name)"
    }

    // MARK: Changing settings (each one can be undone)

    func change(record: Bool = true, _ f: (inout VideoEdits) -> Void) {
        var e = edits
        f(&e)
        guard e != edits else { return }
        if record { history.append(edits) }
        edits = e
        applyPreview()
    }

    func undo() {
        guard let last = history.popLast() else { return }
        edits = last
        applyPreview()
    }

    func discard() {
        history.removeAll()
        edits = original
        active = nil
        aspect = .free
        applyPreview()
    }

    // MARK: Picking tools

    func select(_ tool: ToolID) {
        guard isAvailable(tool), info != nil else { return }
        switch tool {
        case .saveFrame: saveFrame(); return
        case .extractAudio: extractAudio(); return
        case .rotateVideo:
            change { e in
                e.turns = (e.turns + 1) % 4
                // The crop box turns with the picture.
                let c = e.crop
                e.crop = CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
            }
            return
        case .flipVideo:
            change { e in e.flip.toggle(); e.crop.origin.x = 1 - e.crop.maxX }
            return
        case .muteVideo:
            change { $0.mute.toggle() }
            EditToastCenter.shared.show(edits.mute ? "The copy will have no sound · ⌘Z to undo" : "Sound back on")
            return
        default: break
        }
        if active == tool { active = nil; applyPreview(); return }
        active = tool
        switch tool {
        case .saveAsMP4: change { $0.mp4 = true }
        case .compressVideo: if edits.compress == nil { change { $0.compress = .mail } }
        case .stripVideoLocation: change { $0.stripLocation = true }
        case .makeGIF: estimateGIF()
        case .transcribe: if transcript == nil { runTranscribe() }
        case .cropVideo: player.pause()
        default: break
        }
        applyPreview()
    }

    // MARK: Preview

    /// The size the stage shows: turned, flipped and cropped (not while the crop box is out).
    var displaySize: CGSize {
        guard let info else { return CGSize(width: 16, height: 9) }
        return MediaEngine.geometry(info, edits, crop: active != .cropVideo, scale: false).size
    }

    /// Turned/flipped pixel size the crop box works in.
    var cropSpace: CGSize { info.map { MediaEngine.turnedSize($0, edits) } ?? .zero }

    private func applyPreview() {
        guard let info, let pi = playerItem else { return }
        var e = edits; e.size = nil; e.compress = nil
        if active == .cropVideo { e.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
        pi.videoComposition = MediaEngine.changesPicture(info, e)
            ? MediaEngine.videoComposition(trackID: info.videoTrackID, duration: CMTime(seconds: info.duration + 1, preferredTimescale: 600), info: info, edits: e, scale: false)
            : nil
        player.isMuted = edits.mute
        pi.forwardPlaybackEndTime = isTrimmed ? CMTime(seconds: edits.end, preferredTimescale: 600) : .invalid
        if MediaEngine.isSnapshotRun { refreshPoster() }
    }

    private func refreshPoster() {
        guard let info else { return }
        let e = edits, crop = active != .cropVideo, url = item.url, t = max(edits.start, min(edits.end, max(currentTime, info.duration * 0.3)))
        Task {
            let p = await MediaEngine.poster(url: url, info: info, edits: e, crop: crop, at: t)
            if e == self.edits { poster = p }
        }
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600)
        currentTime = t.seconds
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Trim

    func beginTrim() { dragBase = edits; player.pause() }

    func setTrim(start: Double, end: Double, showing: Double) {
        change(record: false) { $0.start = start; $0.end = end }
        seek(to: showing)
    }

    func endTrim() {
        if let b = dragBase, b != edits { history.append(b) }
        dragBase = nil
        if active == .makeGIF { estimateGIF() }
    }

    func resetTrim() { change { $0.start = 0; $0.end = duration } }

    // MARK: Crop

    private func ratio(_ a: Aspect) -> CGFloat? {
        switch a {
        case .free: return nil
        case .square: return 1
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .fourThree: let s = cropSpace; return s.width >= s.height ? 4.0 / 3.0 : 3.0 / 4.0
        }
    }

    private var normalizedRatio: CGFloat? {
        let s = cropSpace
        guard let r = ratio(aspect), s.width > 0 else { return nil }
        return r * s.height / s.width
    }

    private func applyAspect() {
        guard let nr = normalizedRatio else { return }
        var w: CGFloat = 1, h = 1 / nr
        if h > 1 { h = 1; w = nr }
        let r = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        change { $0.crop = r }
    }

    func beginCrop() { dragBase = edits }
    func endCrop() { if let b = dragBase, b != edits { history.append(b) }; dragBase = nil }

    /// Same handles as the picture crop: corners 0…3, or −1 to move the whole box.
    func dragCrop(handle: Int, from start: CGRect, by d: CGSize) {
        var r = start
        let minSide: CGFloat = 0.08
        if handle == -1 {
            r.origin.x = min(max(0, start.minX + d.width), 1 - start.width)
            r.origin.y = min(max(0, start.minY + d.height), 1 - start.height)
            change(record: false) { $0.crop = r }
            return
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
        change(record: false) { $0.crop = r }
    }

    func resetCrop() {
        aspect = .free
        change { $0.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    func doneCropping() { active = nil; applyPreview() }

    // MARK: Sizes

    /// Pixel size of the copy.
    var outputSize: CGSize { info.map { MediaEngine.geometry($0, edits).size } ?? .zero }

    func outputSize(short: Int?) -> CGSize {
        guard let info else { return .zero }
        var e = edits; e.size = short; e.compress = nil
        return MediaEngine.geometry(info, e).size
    }

    /// Rough size of the copy, from bitrates.
    var estimatedBytes: Int64 { estimate(edits) }

    func estimate(_ e: VideoEdits) -> Int64 {
        guard let info else { return 0 }
        let kept = max(0, e.end - e.start)
        let audio = e.mute ? 0 : info.audioBitrate
        let (_, size) = MediaEngine.geometry(info, e)
        let turned = MediaEngine.turnedSize(info, e)
        let ratio = (size.width * size.height) / max(1, turned.width * turned.height)
        if let c = e.compress {
            let v = MediaEngine.compressBitrate(c, info: info, pixelRatio: ratio)
            let a = e.mute || !info.hasAudio ? 0 : Double(MediaEngine.compressAudioBitrate(c, info: info))
            return Int64((v + a) * kept / 8 * 1.02)
        }
        if !MediaEngine.changesPicture(info, e) { return Int64((info.videoBitrate + audio) * kept / 8) }
        // Re-encoded at high quality as H.264: about the original's bits per pixel (HEVC needs more as H.264).
        let pixels = Double(size.width * size.height)
        let codec = info.codec == "HEVC" ? 1.6 : info.codec == "ProRes" ? 0.08 : 1.1
        let v = min(pixels * info.fps * 0.25, max(100_000, info.videoBitrate * Double(ratio) * codec))
        return Int64((v + audio) * kept / 8)
    }

    func estimate(compress c: VideoCompress) -> Int64 { var e = edits; e.compress = c; return estimate(e) }

    func setSize(_ short: Int?) { change { $0.size = short } }
    func setCompress(_ c: VideoCompress) { change { $0.compress = c } }
    func setMP4Quality(_ short: Int?) { change { $0.size = short; $0.mp4 = true } }
    func setStripLocation(_ on: Bool) { change { $0.stripLocation = on } }
    func setMute(_ on: Bool) { change { $0.mute = on } }

    // MARK: Saving the copy

    private func progressSink(_ label: String) -> (Int, @Sendable (Double) -> Void) {
        let k = ticket.next()
        busy = "\(label) 0%"
        return (k, { [weak self] p in
            Task { @MainActor in
                guard let self, self.ticket.isCurrent(k), self.busy != nil else { return }
                self.busy = "\(label) \(Int(p * 100))%"
            }
        })
    }

    private func finishBusy(_ k: Int) { if ticket.isCurrent(k) { busy = nil } }

    func save() async throws -> URL {
        guard let info else { throw EditError.message("This video can’t be read") }
        player.pause()
        let dest = CopySaver.destination(near: item.url, suffix: suffix, ext: outputExt)
        let (k, sink) = progressSink("Saving…")
        defer { finishBusy(k) }
        try await MediaEngine.exportVideo(url: item.url, info: info, edits: edits, to: dest, progress: sink)
        CopySaver.register(dest, like: item)
        return dest
    }

    // MARK: Separate files, made straight away

    private func makeSeparate(_ label: String, suffix: String?, ext: String,
                              _ work: @escaping (URL, @escaping @Sendable (Double) -> Void) async throws -> Void) {
        guard busy == nil else { return }
        let dest = CopySaver.destination(near: item.url, suffix: suffix, ext: ext)
        let (k, sink) = progressSink(label)
        Task {
            defer { finishBusy(k) }
            do {
                try await work(dest, sink)
                CopySaver.register(dest, like: item)
                EditToastCenter.shared.show(saved: .init(original: item, copy: dest))
            } catch {
                EditToastCenter.shared.show("Couldn’t save it: \(error.localizedDescription)")
            }
        }
    }

    func saveFrame() {
        guard let info else { return }
        let t = currentTime, e = edits, url = item.url
        player.pause()
        makeSeparate("Saving the frame…", suffix: "frame at \(Self.stamp(t))", ext: "png") { dest, _ in
            try await MediaEngine.saveFrame(url: url, info: info, edits: e, at: t, to: dest)
        }
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s < 60 ? "\(s)s" : String(format: "%dm%02ds", s / 60, s % 60)
    }

    func extractAudio() {
        let e = edits, url = item.url
        makeSeparate("Pulling out the sound…", suffix: nil, ext: "m4a") { dest, p in
            try await MediaEngine.extractAudio(url: url, start: e.start, end: e.end, to: dest, progress: p)
        }
    }

    func makeGIF() {
        guard let info else { return }
        let e = edits, g = gif, url = item.url
        makeSeparate("Making the GIF…", suffix: nil, ext: "gif") { dest, p in
            try await MediaEngine.makeGIF(url: url, info: info, edits: e, settings: g, to: dest, progress: p)
        }
    }

    var gifFrames: Int { MediaEngine.gifFrameCount(seconds: kept, fps: gif.fps) }

    private func estimateGIF() {
        guard let info else { return }
        gifTask?.cancel()
        gifEstimate = nil
        let e = edits, g = gif, url = item.url
        gifTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let est = await MediaEngine.estimateGIF(url: url, info: info, edits: e, settings: g)
            guard !Task.isCancelled else { return }
            gifEstimate = est
        }
    }

    // MARK: Transcript

    func runTranscribe() {
        transcriptError = nil
        busy = "Listening…"
        let url = item.url
        Task {
            do { transcript = try await MediaEngine.transcribe(url: url, isVideo: true) }
            catch { transcriptError = error.localizedDescription }
            busy = nil
        }
    }

    func copyTranscript() {
        guard let t = transcript else { return }
        FileActions.copyText(t)
        EditToastCenter.shared.show("Copied the transcript")
    }

    func saveTranscript() { MediaText.save(transcript, near: item) }

    // MARK: Views

    func stage() -> AnyView { AnyView(VideoStage(ws: self)) }
    func options() -> AnyView { AnyView(VideoOptions(ws: self)) }
}

enum MediaText {
    @MainActor
    static func save(_ text: String?, near item: FileItem) {
        guard let text, !text.isEmpty else { return }
        let dest = CopySaver.destination(near: item.url, suffix: "transcript", ext: "txt")
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            CopySaver.register(dest, like: item)
            EditToastCenter.shared.show(saved: .init(original: item, copy: dest))
        } catch {
            EditToastCenter.shared.show("Couldn’t save the text: \(error.localizedDescription)")
        }
    }
}

// MARK: - Audio

/// Sound files: trim with the waveform, transcribe, and save as M4A, WAV or AIFF, or smaller AAC.
@MainActor
@Observable
final class AudioWorkspace: EditWorkspace, TrimmableMedia {
    let item: FileItem
    let kind: EditKind = .audio
    private(set) var info: AudioInfo?
    private(set) var loadError: String?
    private(set) var active: ToolID?
    private(set) var busy: String?

    struct Edits: Equatable { var start: Double = 0; var end: Double = 0; var out: AudioOut = .original }
    private(set) var edits = Edits()
    @ObservationIgnored private var original = Edits()
    private var history: [Edits] = []
    @ObservationIgnored private var dragBase: Edits?

    let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    private(set) var currentTime: Double = 0
    private(set) var playing = false
    private(set) var bars: [Float] = []

    private(set) var transcript: String?
    private(set) var transcriptError: String?
    @ObservationIgnored private let ticket = BusyTicket()

    init(item: FileItem) {
        self.item = item
        Task { await load() }
    }

    private func load() async {
        do {
            let i = try await MediaEngine.loadAudio(item.url)
            info = i
            edits = Edits(start: 0, end: i.duration)
            original = edits
            player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: item.url)))
            player.actionAtItemEnd = .pause
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.tick(t.seconds) }
            }
            if MediaEngine.isSnapshotRun, let t = ProcessInfo.processInfo.environment["ORCA_SNAPSHOT_TRIM"]?.split(separator: ",").compactMap({ Double($0) }), t.count == 2 {
                change { $0.start = t[0]; $0.end = t[1] }
                seek(to: (t[0] + t[1]) / 2)
            }
            bars = (try? await MediaEngine.waveform(url: item.url, bars: 600)) ?? []
        } catch {
            loadError = (error as NSError).domain == AVFoundationErrorDomain
                ? "It may be damaged, still downloading from iCloud, or in a format this Mac can’t play."
                : error.localizedDescription
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        playing = player.rate > 0
        if playing && t >= edits.end - 0.02 { player.pause(); playing = false; seek(to: edits.start) }
    }

    var bar: [ToolID] { [.trimAudio, .transcribeAudio, .convertAudio, .compressAudio] }

    var groups: [ToolGroup] {
        [ToolGroup(title: "Trim", tools: [.trimAudio]),
         ToolGroup(title: "Text", tools: [.transcribeAudio]),
         ToolGroup(title: "Save as", tools: [.convertAudio, .compressAudio])]
    }

    func isAvailable(_ tool: ToolID) -> Bool { loadError == nil }

    var duration: Double { info?.duration ?? 0 }
    var trimStart: Double { edits.start }
    var trimEnd: Double { edits.end }
    var kept: Double { max(0, edits.end - edits.start) }
    var isTrimmed: Bool { info != nil && (edits.start > 0.05 || edits.end < duration - 0.05) }
    var canUndo: Bool { !history.isEmpty }
    var hasEdits: Bool { info != nil && edits != original }

    var outputExt: String {
        if let e = edits.out.ext { return e }
        let e = item.ext.lowercased()
        // A plain trim keeps the format when it can be copied as is.
        return ["m4a", "wav", "aif", "aiff", "caf", "mp3", "aac"].contains(e) ? (e == "aac" || e == "mp3" ? "m4a" : e) : "m4a"
    }

    private var suffix: String? {
        var l: [String] = []
        if isTrimmed { l.append("trimmed") }
        if case .m4a(let k) = edits.out, k < 256 { l.append("smaller") }
        if l.isEmpty { return outputExt == item.ext.lowercased() ? "copy" : nil }
        return l.count == 1 ? l[0] : "edited"
    }

    var status: String? {
        guard hasEdits else { return nil }
        let name = CopySaver.destination(near: item.url, suffix: suffix, ext: outputExt).lastPathComponent
        var l: [String] = []
        if isTrimmed { l.append("Trimmed") }
        switch edits.out {
        case .original: break
        case .m4a(let k): l.append(k < 256 ? "AAC \(k) kbps" : "M4A")
        case .wav: l.append("WAV")
        case .aiff: l.append("AIFF")
        }
        return "\(l.joined(separator: " · ")) · will save as \(name)"
    }

    private func change(record: Bool = true, _ f: (inout Edits) -> Void) {
        var e = edits
        f(&e)
        guard e != edits else { return }
        if record { history.append(edits) }
        edits = e
    }

    func undo() { if let last = history.popLast() { edits = last } }
    func discard() { history.removeAll(); edits = original; active = nil }

    func select(_ tool: ToolID) {
        guard isAvailable(tool), info != nil else { return }
        if active == tool { active = nil; return }
        active = tool
        switch tool {
        case .convertAudio: if edits.out == .original { change { $0.out = .m4a(kbps: 256) } }
        case .compressAudio: if case .m4a(let k) = edits.out, k < 256 {} else { change { $0.out = .m4a(kbps: 96) } }
        case .transcribeAudio: if transcript == nil { runTranscribe() }
        default: break
        }
    }

    func setOut(_ o: AudioOut) { change { $0.out = o } }

    // Playback

    func togglePlay() {
        if player.rate > 0 { player.pause(); playing = false; return }
        if currentTime < edits.start || currentTime >= edits.end - 0.05 { seek(to: edits.start) }
        player.play(); playing = true
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600)
        currentTime = t.seconds
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginTrim() { dragBase = edits; player.pause(); playing = false }
    func setTrim(start: Double, end: Double, showing: Double) { change(record: false) { $0.start = start; $0.end = end }; seek(to: showing) }
    func endTrim() { if let b = dragBase, b != edits { history.append(b) }; dragBase = nil }
    func resetTrim() { change { $0.start = 0; $0.end = duration } }

    // Sizes

    func estimate(_ out: AudioOut) -> Int64 {
        guard let info else { return 0 }
        let ch = Double(max(1, min(2, info.channels)))
        switch out {
        case .original: return Int64(Double(info.fileSize) * kept / max(0.001, duration))
        case .m4a(let k): return Int64(Double(MediaEngine.aacPlan(info, kbps: k).bitrate) * kept / 8 * 1.03)
        case .wav, .aiff: return Int64(info.sampleRate * ch * Double(info.bitsPerChannel > 16 ? 3 : 2) * kept)
        }
    }

    var estimatedBytes: Int64 { estimate(edits.out) }

    func save() async throws -> URL {
        guard let info else { throw EditError.message("This file can’t be read") }
        player.pause(); playing = false
        let dest = CopySaver.destination(near: item.url, suffix: suffix, ext: outputExt)
        let k = ticket.next()
        busy = "Saving… 0%"
        defer { if ticket.isCurrent(k) { busy = nil } }
        try await MediaEngine.exportAudio(url: item.url, info: info, start: edits.start, end: edits.end, out: edits.out, to: dest) { [weak self] p in
            Task { @MainActor in
                guard let self, self.ticket.isCurrent(k), self.busy != nil else { return }
                self.busy = "Saving… \(Int(p * 100))%"
            }
        }
        CopySaver.register(dest, like: item)
        return dest
    }

    func runTranscribe() {
        transcriptError = nil
        busy = "Listening…"
        let url = item.url
        Task {
            do { transcript = try await MediaEngine.transcribe(url: url, isVideo: false) }
            catch { transcriptError = error.localizedDescription }
            busy = nil
        }
    }

    func copyTranscript() {
        guard let t = transcript else { return }
        FileActions.copyText(t)
        EditToastCenter.shared.show("Copied the transcript")
    }

    func saveTranscript() { MediaText.save(transcript, near: item) }

    func stage() -> AnyView { AnyView(AudioStage(ws: self)) }
    func options() -> AnyView { AnyView(AudioOptions(ws: self)) }
}
