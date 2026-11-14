import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// The AVFoundation side of the video and audio editors: reading a file, building one composition
// that applies every pending edit, and writing copies (MP4/MOV, GIF, PNG frame, M4A/WAV/AIFF).
// Nothing here touches the UI; the workspaces call in and get progress back on any thread.

// MARK: - What the person has asked for

/// Every pending change to a video. "Save copy" writes one file that applies all of them.
struct VideoEdits: Equatable {
    /// Kept part, in seconds of the original.
    var start: Double = 0
    var end: Double = 0
    /// Quarter turns to the left.
    var turns = 0
    var flip = false
    /// Normalised, top-left origin, in the turned and flipped picture.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var mute = false
    /// Short side in pixels (1080, 720, 480); nil keeps the original size.
    var size: Int?
    /// Save as MP4 was picked.
    var mp4 = false
    var compress: VideoCompress?
    var stripLocation = false

    var isCropped: Bool { crop != CGRect(x: 0, y: 0, width: 1, height: 1) }
}

enum VideoCompress: String, CaseIterable, Equatable {
    case mail = "For Mail", messages = "For Messages", smallest = "Smallest"
    var shortSide: Int { switch self { case .mail: 720; case .messages: 540; case .smallest: 360 } }
    var videoBitrate: Double { switch self { case .mail: 2_400_000; case .messages: 1_300_000; case .smallest: 550_000 } }
    var audioBitrate: Int { switch self { case .mail: 128_000; case .messages: 96_000; case .smallest: 64_000 } }
    var detail: String { "\(shortSide)p" }
}

/// What an audio copy is written as.
enum AudioOut: Equatable {
    case original
    case m4a(kbps: Int)
    case wav, aiff

    var ext: String? {
        switch self { case .original: nil; case .m4a: "m4a"; case .wav: "wav"; case .aiff: "aif" }
    }
}

// MARK: - What the file is

struct VideoInfo {
    var duration: Double
    var naturalSize: CGSize
    var transform: CGAffineTransform
    var fps: Double
    var hasVideo: Bool
    var hasAudio: Bool
    var videoTrackID: CMPersistentTrackID
    var videoBitrate: Double
    var audioBitrate: Double
    var audioChannels: Int
    var fileSize: Int64
    var codec: String
    var metadata: [AVMetadataItem]
    var hasLocation: Bool

    /// Upright size, as the video is shown.
    var orientedSize: CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
    }
}

struct AudioInfo {
    var duration: Double
    var sampleRate: Double
    var channels: Int
    var bitsPerChannel: Int
    var bitrate: Double
    var codec: String
    var fileSize: Int64
    var formatLine: String {
        var parts = [codec]
        if sampleRate > 0 { parts.append(String(format: sampleRate.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f kHz" : "%.1f kHz", sampleRate / 1000)) }
        parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels) channels")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Engine

enum MediaEngine {
    /// The editor is being drawn offscreen by `--edit-snapshot`, where AVPlayerView can't be captured.
    static let isSnapshotRun = CommandLine.arguments.contains("--edit-snapshot")

    static func fourCC(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC, 0x68657631 /* hev1 */: return "HEVC"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy: return "ProRes"
        case kCMVideoCodecType_MPEG4Video: return "MPEG-4"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAC3, kAudioFormatEnhancedAC3: return "Dolby"
        default:
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
            return String(chars).trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func isLocation(_ m: AVMetadataItem) -> Bool {
        let ids: Set<AVMetadataIdentifier> = [.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709, .commonIdentifierLocation,
                                              .quickTimeMetadataLocationName, .quickTimeMetadataLocationBody, .quickTimeMetadataLocationNote,
                                              .quickTimeMetadataLocationRole, .quickTimeMetadataLocationDate]
        if m.commonKey == .commonKeyLocation { return true }
        if let id = m.identifier, ids.contains(id) { return true }
        return (m.identifier?.rawValue ?? "").lowercased().contains("location")
    }

    static func loadVideo(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, tracks, metadata) = try await asset.load(.duration, .tracks, .metadata)
        var info = VideoInfo(duration: duration.seconds, naturalSize: .zero, transform: .identity, fps: 30, hasVideo: false, hasAudio: false,
                             videoTrackID: kCMPersistentTrackID_Invalid, videoBitrate: 0, audioBitrate: 0, audioChannels: 2,
                             fileSize: fileSize(url), codec: "", metadata: metadata, hasLocation: metadata.contains(where: isLocation))
        for t in tracks {
            switch t.mediaType {
            case .video where !info.hasVideo:
                let (size, transform, fps, rate, formats) = try await t.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
                info.hasVideo = size.width > 0 && size.height > 0
                info.naturalSize = size
                info.transform = transform
                info.fps = fps > 1 ? Double(fps) : 30
                info.videoBitrate = Double(rate)
                info.videoTrackID = t.trackID
                if let f = formats.first { info.codec = fourCC(CMFormatDescriptionGetMediaSubType(f)) }
            case .audio:
                let (rate, formats) = try await t.load(.estimatedDataRate, .formatDescriptions)
                info.hasAudio = true
                info.audioBitrate += Double(rate)
                if let f = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    info.audioChannels = max(1, Int(asbd.mChannelsPerFrame))
                }
            default: break
            }
        }
        guard duration.isNumeric, info.duration > 0 else { throw EditError.message("This file has no length") }
        if info.videoBitrate <= 0, info.duration > 0 { info.videoBitrate = max(0, Double(info.fileSize) * 8 / info.duration - info.audioBitrate) }
        return info
    }

    static func loadAudio(_ url: URL) async throws -> AudioInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        guard let t = tracks.first(where: { $0.mediaType == .audio }) else { throw EditError.message("No sound in this file") }
        let (rate, formats) = try await t.load(.estimatedDataRate, .formatDescriptions)
        var info = AudioInfo(duration: duration.seconds, sampleRate: 44_100, channels: 2, bitsPerChannel: 16, bitrate: Double(rate), codec: "", fileSize: fileSize(url))
        if let f = formats.first {
            info.codec = fourCC(CMFormatDescriptionGetMediaSubType(f))
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                info.sampleRate = asbd.mSampleRate
                info.channels = max(1, Int(asbd.mChannelsPerFrame))
                if asbd.mBitsPerChannel > 0 { info.bitsPerChannel = Int(asbd.mBitsPerChannel) }
            }
        }
        guard duration.isNumeric, info.duration > 0 else { throw EditError.message("This file has no length") }
        if info.bitrate <= 0 { info.bitrate = Double(info.fileSize) * 8 / info.duration }
        return info
    }

    // MARK: Geometry: orient → turn → flip → crop → scale, in top-left pixel space

    static func evenFloor(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }

    /// The size after turning and flipping (before crop).
    static func turnedSize(_ info: VideoInfo, _ e: VideoEdits) -> CGSize {
        let o = info.orientedSize
        return e.turns % 2 == 0 ? o : CGSize(width: o.height, height: o.width)
    }

    static func targetShortSide(_ e: VideoEdits) -> Int? {
        switch (e.size, e.compress?.shortSide) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    static func geometry(_ info: VideoInfo, _ e: VideoEdits, crop: Bool = true, scale: Bool = true) -> (transform: CGAffineTransform, size: CGSize) {
        let r = CGRect(origin: .zero, size: info.naturalSize).applying(info.transform)
        var t = info.transform.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
        var size = CGSize(width: abs(r.width), height: abs(r.height))
        for _ in 0..<((e.turns % 4 + 4) % 4) {
            // A quarter turn to the left: (x, y) → (y, w − x).
            t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width))
            size = CGSize(width: size.height, height: size.width)
        }
        if e.flip { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
        if crop && e.isCropped {
            let c = e.crop
            let px = CGRect(x: (c.minX * size.width).rounded(), y: (c.minY * size.height).rounded(),
                            width: evenFloor(c.width * size.width), height: evenFloor(c.height * size.height))
            t = t.concatenating(CGAffineTransform(translationX: -px.minX, y: -px.minY))
            size = px.size
        }
        if scale, let target = targetShortSide(e) {
            let short = min(size.width, size.height)
            if short > CGFloat(target) + 1 {
                let s = CGFloat(target) / short
                t = t.concatenating(CGAffineTransform(scaleX: s, y: s))
                size = CGSize(width: size.width * s, height: size.height * s)
            }
        }
        return (t, CGSize(width: evenFloor(size.width.rounded()), height: evenFloor(size.height.rounded())))
    }

    /// Whether the picture itself changes (so the frames have to be drawn again).
    static func changesPicture(_ info: VideoInfo, _ e: VideoEdits) -> Bool {
        if e.turns % 4 != 0 || e.flip || e.isCropped { return true }
        if let target = targetShortSide(e), min(info.orientedSize.width, info.orientedSize.height) > CGFloat(target) + 1 { return true }
        return false
    }

    static func videoComposition(trackID: CMPersistentTrackID, duration: CMTime, info: VideoInfo, edits: VideoEdits,
                                 crop: Bool = true, scale: Bool = true) -> AVMutableVideoComposition {
        let (t, size) = geometry(info, edits, crop: crop, scale: scale)
        let layer = AVMutableVideoCompositionLayerInstruction()
        layer.trackID = trackID
        layer.setTransform(t, at: .zero)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: duration)
        ins.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(120, max(1, info.fps.rounded()))))
        vc.instructions = [ins]
        return vc
    }

    /// MP4 drops QuickTime's own keys, so the ones with a common meaning (title, date, place…) are re-labelled as common keys.
    static func portable(_ items: [AVMetadataItem], for type: AVFileType) -> [AVMetadataItem] {
        guard type != .mov else { return items }
        var seen = Set<AVMetadataKey>()
        return items.compactMap { m in
            guard let key = m.commonKey, seen.insert(key).inserted else { return nil }
            let c = AVMutableMetadataItem()
            c.keySpace = .common
            c.key = key as NSString
            c.value = m.value
            c.dataType = m.dataType
            c.extendedLanguageTag = m.extendedLanguageTag
            return c
        }
    }

    static func timeRange(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }

    /// The kept part as one composition: the first video track and (unless muted) every audio track.
    static func composition(_ asset: AVAsset, range: CMTimeRange, video: Bool = true, audio: Bool = true) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        if video, let src = try await asset.loadTracks(withMediaType: .video).first {
            let (tr, transform) = try await src.load(.timeRange, .preferredTransform)
            let r = range.intersection(tr)
            if r.duration > .zero, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try t.insertTimeRange(r, of: src, at: r.start - range.start)
                t.preferredTransform = transform
            }
        }
        if audio {
            for src in try await asset.loadTracks(withMediaType: .audio) {
                let tr = try await src.load(.timeRange)
                let r = range.intersection(tr)
                guard r.duration > .zero, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try t.insertTimeRange(r, of: src, at: r.start - range.start)
            }
        }
        return comp
    }

    static func fileType(forExt ext: String) -> AVFileType {
        switch ext.lowercased() {
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "m4a": return .m4a
        case "wav": return .wav
        case "aif", "aiff": return .aiff
        case "caf": return .caf
        case "mp3": return .mp3
        case "3gp": return .mobile3GPP
        default: return .mov
        }
    }

    // MARK: Video copy

    static func exportVideo(url: URL, info: VideoInfo, edits e: VideoEdits, to dest: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let comp = try await composition(asset, range: timeRange(e.start, e.end), audio: !e.mute)
        let type = fileType(forExt: dest.pathExtension)
        let metadata = e.stripLocation ? info.metadata.filter { !isLocation($0) } : info.metadata
        try? FileManager.default.removeItem(at: dest)

        if let c = e.compress {
            guard let track = try await comp.loadTracks(withMediaType: .video).first else { throw EditError.message("No picture in this video") }
            let vc = videoComposition(trackID: track.trackID, duration: comp.duration, info: info, edits: e)
            let ratio = (vc.renderSize.width * vc.renderSize.height) / max(1, turnedSize(info, e).width * turnedSize(info, e).height)
            let vbr = compressBitrate(c, info: info, pixelRatio: ratio)
            try await writeVideo(comp, videoComposition: vc, videoBitrate: vbr, audioBitrate: e.mute ? nil : compressAudioBitrate(c, info: info),
                                 channels: min(2, info.audioChannels), fileType: type, metadata: e.stripLocation ? [] : metadata,
                                 to: dest, duration: comp.duration.seconds, progress: progress)
            return
        }

        var session: AVAssetExportSession?
        if !changesPicture(info, e), let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough),
           s.supportedFileTypes.contains(type) {
            session = s
        }
        if session == nil {
            guard let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw EditError.message("This Mac can’t re-encode this video") }
            if let track = try await comp.loadTracks(withMediaType: .video).first {
                s.videoComposition = videoComposition(trackID: track.trackID, duration: comp.duration, info: info, edits: e)
            }
            session = s
        }
        guard let session else { throw EditError.message("Couldn’t start saving") }
        session.metadata = portable(metadata, for: type)
        if e.stripLocation { session.metadataItemFilter = .forSharing() }
        session.shouldOptimizeForNetworkUse = true
        try await run(session, to: dest, as: type, progress: progress)
    }

    /// Bits per second for a compressed copy: the level's target, never more than the original had.
    static func compressBitrate(_ c: VideoCompress, info: VideoInfo, pixelRatio: CGFloat) -> Double {
        let source = info.videoBitrate > 0 ? info.videoBitrate * Double(pixelRatio) * 0.85 : c.videoBitrate
        return max(200_000, min(c.videoBitrate, source))
    }

    /// The level's AAC rate, but never far above what the original's sound had.
    static func compressAudioBitrate(_ c: VideoCompress, info: VideoInfo) -> Int {
        guard info.audioBitrate > 0 else { return c.audioBitrate }
        return min(c.audioBitrate, max(64_000, Int(info.audioBitrate * 1.1)))
    }

    static func run(_ s: AVAssetExportSession, to dest: URL, as type: AVFileType, progress: @escaping @Sendable (Double) -> Void) async throws {
        nonisolated(unsafe) let session = s
        let poll = Task.detached {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poll.cancel() }
        do {
            try await session.export(to: dest, as: type)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        progress(1)
    }

    /// Re-encodes with a set bitrate (export presets can't), for Compress.
    static func writeVideo(_ comp: AVComposition, videoComposition vc: AVVideoComposition, videoBitrate: Double, audioBitrate: Int?,
                           channels: Int, fileType: AVFileType, metadata: [AVMetadataItem], to dest: URL, duration: Double,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: comp)
        let writer = try AVAssetWriter(outputURL: dest, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = portable(metadata, for: fileType)
        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = []

        let vTracks = try await comp.loadTracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        vOut.videoComposition = vc
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw EditError.message("Can’t read the picture") }
        reader.add(vOut)
        let fps = vc.frameDuration.seconds > 0 ? 1 / vc.frameDuration.seconds : 30
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(vc.renderSize.width),
            AVVideoHeightKey: Int(vc.renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(videoBitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw EditError.message("Can’t write this video") }
        writer.add(vIn)
        pairs.append((vOut, vIn, true))

        let aTracks = try await comp.loadTracks(withMediaType: .audio)
        if let audioBitrate, !aTracks.isEmpty {
            let ch = max(1, min(2, channels))
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: pcmSettings(rate: 44_100, channels: ch, bits: 16, bigEndian: false))
            aOut.alwaysCopiesSampleData = false
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: ch,
                AVEncoderBitRateKey: aacBitrate(audioBitrate, sampleRate: 44_100, channels: ch),
            ])
            aIn.expectsMediaDataInRealTime = false
            if reader.canAdd(aOut), writer.canAdd(aIn) {
                reader.add(aOut); writer.add(aIn)
                pairs.append((aOut, aIn, false))
            }
        }
        try await pump(reader: reader, writer: writer, pairs: pairs, duration: duration, progress: progress, dest: dest)
    }

    static func pcmSettings(rate: Double, channels: Int, bits: Int, bigEndian: Bool) -> [String: Any] {
        var s: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if channels <= 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            s[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return s
    }

    /// Sample rate, channels and the bitrate AAC will really use for this file (low-rate mono tops out early).
    static func aacPlan(_ info: AudioInfo, kbps: Int) -> (rate: Double, channels: Int, bitrate: Int) {
        let ch = max(1, min(2, info.channels))
        let rate = [44_100.0, 48_000.0, 32_000.0, 24_000.0, 22_050.0].contains(info.sampleRate) ? info.sampleRate : 44_100
        return (rate, ch, aacBitrate(kbps * 1000, sampleRate: rate, channels: ch))
    }

    /// The nearest AAC bitrate the encoder accepts for this rate and channel count, at or under what was asked.
    static func aacBitrate(_ wanted: Int, sampleRate: Double, channels: Int) -> Int {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]),
              let conv = AVAudioConverter(from: pcm, to: aac),
              let rates = conv.applicableEncodeBitRates?.map(\.intValue), !rates.isEmpty else { return wanted }
        return rates.filter { $0 <= wanted }.max() ?? rates.min()!
    }

    /// Moves samples from reader to writer until both run dry.
    static func pump(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)],
                     duration: Double, progress: @escaping @Sendable (Double) -> Void, dest: URL) async throws {
        guard reader.startReading() else { throw reader.error ?? EditError.message("Can’t read this file") }
        guard writer.startWriting() else { reader.cancelReading(); throw writer.error ?? EditError.message("Can’t write the copy") }
        writer.startSession(atSourceTime: .zero)
        nonisolated(unsafe) let pairs = pairs
        nonisolated(unsafe) let reader = reader
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            let tracksProgress = !pairs.contains(where: { $0.2 })
            for (i, (out, inp, isVideo)) in pairs.enumerated() {
                nonisolated(unsafe) let output = out, input = inp
                group.enter()
                let q = DispatchQueue(label: "orca.media.pump.\(i)")
                var done = false
                input.requestMediaDataWhenReady(on: q) {
                    guard !done else { return }
                    while input.isReadyForMoreMediaData {
                        guard reader.status == .reading, let sb = output.copyNextSampleBuffer() else {
                            input.markAsFinished(); done = true; group.leave(); return
                        }
                        if (isVideo || tracksProgress), duration > 0 {
                            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                            if t.isFinite { progress(min(0.99, max(0, t / duration))) }
                        }
                        if !input.append(sb) {
                            input.markAsFinished(); done = true; group.leave(); return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { c.resume() }
        }
        if reader.status == .failed || writer.status == .failed {
            let err = writer.error ?? reader.error
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dest)
            throw err ?? EditError.message("Saving stopped part way")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            throw writer.error ?? EditError.message("Couldn’t finish the copy")
        }
        progress(1)
    }

    // MARK: Separate files from a video

    /// A PNG of one frame, with the crop, turn and flip applied.
    static func saveFrame(url: URL, info: VideoInfo, edits e: VideoEdits, at seconds: Double, to dest: URL) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        var noScale = e; noScale.size = nil; noScale.compress = nil
        if changesPicture(info, noScale) {
            gen.videoComposition = videoComposition(trackID: info.videoTrackID, duration: CMTime(seconds: info.duration + 1, preferredTimescale: 600), info: info, edits: noScale, scale: false)
        }
        let t = CMTime(seconds: min(max(0, seconds), max(0, info.duration - 0.01)), preferredTimescale: 600)
        let (cg, _) = try await gen.image(at: t)
        try writePNG(cg, to: dest)
    }

    static func writePNG(_ cg: CGImage, to dest: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw EditError.message("Can’t write the picture") }
        CGImageDestinationAddImage(d, cg, nil)
        guard CGImageDestinationFinalize(d) else { throw EditError.message("Can’t write the picture") }
    }

    /// The sound alone, as AAC in an .m4a.
    static func extractAudio(url: URL, start: Double, end: Double, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let comp = try await composition(asset, range: timeRange(start, end), video: false)
        guard let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { throw EditError.message("Can’t write the sound") }
        try? FileManager.default.removeItem(at: dest)
        try await run(s, to: dest, as: .m4a, progress: progress)
    }

    struct GIFSettings: Equatable { var width = 480; var fps = 10 }

    static func gifFrameCount(seconds: Double, fps: Int) -> Int { min(900, max(1, Int((seconds * Double(fps)).rounded(.up)))) }

    private static func gifGenerator(_ comp: AVComposition, info: VideoInfo, edits e: VideoEdits, width: Int, fps: Int) async throws -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: comp)
        gen.appliesPreferredTrackTransform = true
        let tol = CMTime(seconds: 0.5 / Double(fps), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        var noScale = e; noScale.size = nil; noScale.compress = nil
        var out = info.orientedSize
        if let track = try await comp.loadTracks(withMediaType: .video).first {
            let vc = videoComposition(trackID: track.trackID, duration: comp.duration, info: info, edits: noScale, scale: false)
            gen.videoComposition = vc
            out = vc.renderSize
        }
        let w = min(CGFloat(width), out.width)
        gen.maximumSize = CGSize(width: w, height: (w * out.height / max(1, out.width)).rounded())
        return gen
    }

    private static func gifFileProps() -> CFDictionary {
        [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
    }

    private static func gifFrameProps(fps: Int) -> CFDictionary {
        let delay = 1.0 / Double(fps)
        return [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay,
                                                          kCGImagePropertyGIFUnclampedDelayTime as String: delay]] as CFDictionary
    }

    /// A looping GIF of the kept part (crop, turn and flip included). Returns its size in bytes.
    @discardableResult
    static func makeGIF(url: URL, info: VideoInfo, edits e: VideoEdits, settings g: GIFSettings, to dest: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let comp = try await composition(asset, range: timeRange(e.start, e.end), audio: false)
        let gen = try await gifGenerator(comp, info: info, edits: e, width: g.width, fps: g.fps)
        let seconds = comp.duration.seconds
        let n = gifFrameCount(seconds: seconds, fps: g.fps)
        let times = (0..<n).map { CMTime(seconds: min(seconds - 0.001, Double($0) / Double(g.fps)), preferredTimescale: 600) }
        try? FileManager.default.removeItem(at: dest)
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.gif.identifier as CFString, n, nil) else { throw EditError.message("Can’t write the GIF") }
        CGImageDestinationSetProperties(d, gifFileProps())
        let frameProps = gifFrameProps(fps: g.fps)
        var added = 0
        var last: CGImage?
        for await r in gen.images(for: times) {
            switch r {
            case .success(_, let image, _): CGImageDestinationAddImage(d, image, frameProps); last = image
            case .failure:
                // A frame that can't be decoded repeats the one before so the timing holds.
                if let last { CGImageDestinationAddImage(d, last, frameProps) } else { continue }
            }
            added += 1
            progress(Double(added) / Double(n))
        }
        guard added > 0, CGImageDestinationFinalize(d) else {
            try? FileManager.default.removeItem(at: dest)
            throw EditError.message("Couldn’t make the GIF")
        }
        return fileSize(dest)
    }

    /// Encodes three sample frames and scales up: GIF frames don't share data, so this is close.
    static func estimateGIF(url: URL, info: VideoInfo, edits e: VideoEdits, settings g: GIFSettings) async -> Int64? {
        let asset = AVURLAsset(url: url)
        guard let comp = try? await composition(asset, range: timeRange(e.start, e.end), audio: false),
              let gen = try? await gifGenerator(comp, info: info, edits: e, width: g.width, fps: g.fps) else { return nil }
        let seconds = comp.duration.seconds
        let times = [0.2, 0.5, 0.8].map { CMTime(seconds: seconds * $0, preferredTimescale: 600) }
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, times.count, nil) else { return nil }
        CGImageDestinationSetProperties(d, gifFileProps())
        var k = 0
        for await r in gen.images(for: times) {
            if case .success(_, let image, _) = r { CGImageDestinationAddImage(d, image, gifFrameProps(fps: g.fps)); k += 1 }
        }
        guard k > 0, CGImageDestinationFinalize(d) else { return nil }
        // Sample frames carry the file header and their own colour tables; the full GIF shares some of that.
        let perFrame = Double(data.length) / Double(k) * 0.8
        return Int64(perFrame * Double(gifFrameCount(seconds: seconds, fps: g.fps)))
    }

    /// A strip of small pictures across the whole video, for the trim bar.
    static func thumbnails(url: URL, count: Int, height: CGFloat) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration).seconds, d > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 3, height: height)
        let tol = CMTime(seconds: d / Double(count) / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let times = (0..<count).map { CMTime(seconds: d * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var out: [CGImage] = []
        var last: CGImage?
        for await r in gen.images(for: times) {
            if case .success(_, let image, _) = r { out.append(image); last = image } else if let last { out.append(last) }
        }
        return out
    }

    /// One frame as the stage shows it (used where the live player can't be drawn).
    static func poster(url: URL, info: VideoInfo, edits e: VideoEdits, crop: Bool, at seconds: Double) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        var noScale = e; noScale.size = nil; noScale.compress = nil
        if changesPicture(info, noScale) {
            gen.videoComposition = videoComposition(trackID: info.videoTrackID, duration: CMTime(seconds: info.duration + 1, preferredTimescale: 600),
                                                    info: info, edits: noScale, crop: crop, scale: false)
        }
        return try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: Audio

    /// Peaks for the waveform: `bars` values from 0 to 1.
    static func waveform(url: URL, bars: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let (duration, tracks) = try await asset.load(.duration, .tracks)
        let audio = tracks.filter { $0.mediaType == .audio }
        guard !audio.isEmpty else { return [] }
        let rate = 8_000.0
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? EditError.message("Can’t read the sound") }
        let total = max(1, duration.seconds * rate)
        let perBar = max(1, Int(total / Double(bars)))
        var peaks = [Float](repeating: 0, count: bars)
        var index = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            let n = length / 2
            ptr.withMemoryRebound(to: Int16.self, capacity: n) { s in
                for i in 0..<n {
                    let bar = min(bars - 1, index / perBar)
                    let v = Float(abs(Int32(s[i]))) / 32768
                    if v > peaks[bar] { peaks[bar] = v }
                    index += 1
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? EditError.message("Can’t read the sound") }
        let top = max(0.0001, peaks.max() ?? 1)
        return peaks.map { min(1, $0 / top) }
    }

    /// Writes the kept part of an audio file as M4A, WAV or AIFF (or, for a plain trim, the same format, untouched).
    static func exportAudio(url: URL, info: AudioInfo, start: Double, end: Double, out: AudioOut, to dest: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        try? FileManager.default.removeItem(at: dest)
        let range = timeRange(start, end)
        switch out {
        case .original:
            let type = fileType(forExt: dest.pathExtension)
            if let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough), s.supportedFileTypes.contains(type) {
                s.timeRange = range
                try await run(s, to: dest, as: type, progress: progress)
                return
            }
            // Can't copy it as is (MP3 and friends): fall back to AAC.
            try await writeAudio(asset, range: range, info: info, out: .m4a(kbps: 256), to: dest, progress: progress)
        default:
            try await writeAudio(asset, range: range, info: info, out: out, to: dest, progress: progress)
        }
    }

    private static func writeAudio(_ asset: AVAsset, range: CMTimeRange, info: AudioInfo, out: AudioOut, to dest: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw EditError.message("No sound in this file") }
        let ch = max(1, min(2, info.channels))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let fileType: AVFileType
        let readSettings: [String: Any]
        let writeSettings: [String: Any]
        switch out {
        case .wav, .aiff:
            let big = out == .aiff
            let bits = info.bitsPerChannel > 16 ? 24 : 16
            let rate = info.sampleRate > 0 ? info.sampleRate : 44_100
            readSettings = pcmSettings(rate: rate, channels: ch, bits: bits, bigEndian: big)
            writeSettings = readSettings
            fileType = big ? .aiff : .wav
        case .m4a, .original:
            var kbps = 256
            if case .m4a(let k) = out { kbps = k }
            let plan = aacPlan(info, kbps: kbps)
            readSettings = pcmSettings(rate: plan.rate, channels: plan.channels, bits: 16, bigEndian: false)
            writeSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: plan.rate, AVNumberOfChannelsKey: plan.channels,
                             AVEncoderBitRateKey: plan.bitrate]
            fileType = .m4a
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditError.message("Can’t read the sound") }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: dest, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writeSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EditError.message("Can’t write this format") }
        writer.add(input)
        // Reader times start at the trim point; the writer session starts there too.
        try await pumpAudio(reader: reader, writer: writer, output: output, input: input, start: range.start, duration: range.duration.seconds, progress: progress, dest: dest)
    }

    private static func pumpAudio(reader: AVAssetReader, writer: AVAssetWriter, output: AVAssetReaderOutput, input: AVAssetWriterInput,
                                  start: CMTime, duration: Double, progress: @escaping @Sendable (Double) -> Void, dest: URL) async throws {
        guard reader.startReading() else { throw reader.error ?? EditError.message("Can’t read this file") }
        guard writer.startWriting() else { reader.cancelReading(); throw writer.error ?? EditError.message("Can’t write the copy") }
        writer.startSession(atSourceTime: start)
        nonisolated(unsafe) let reader = reader, output = output, input = input
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var done = false
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "orca.media.audio")) {
                guard !done else { return }
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished(); done = true; c.resume(); return
                    }
                    let t = (CMSampleBufferGetPresentationTimeStamp(sb) - start).seconds
                    if duration > 0, t.isFinite { progress(min(0.99, max(0, t / duration))) }
                    if !input.append(sb) { input.markAsFinished(); done = true; c.resume(); return }
                }
            }
        }
        if reader.status == .failed || writer.status == .failed {
            let err = writer.error ?? reader.error
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dest)
            throw err ?? EditError.message("Saving stopped part way")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            throw writer.error ?? EditError.message("Couldn’t finish the copy")
        }
        progress(1)
    }

    // MARK: Speech

    enum TranscribeError: LocalizedError {
        case needsApp, denied, nothing
        var errorDescription: String? {
            switch self {
            case .needsApp: return "Transcribing needs the OrcaFind app (not the command-line build)."
            case .denied: return "OrcaFind isn’t allowed to use Speech Recognition. Turn it on in System Settings → Privacy & Security."
            case .nothing: return "No speech found in this file."
            }
        }
    }

    /// Speech to text, on this Mac when the language allows. Videos have their sound pulled out first.
    static func transcribe(url: URL, isVideo: Bool) async throws -> String {
        if isSnapshotRun, let fake = ProcessInfo.processInfo.environment["ORCA_FAKE_TRANSCRIPT"] { return fake }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { throw TranscribeError.needsApp }
        guard await VoiceSearch.requestSpeechPermission() else { throw TranscribeError.denied }
        var source = url
        var temp: URL?
        if isVideo || !["m4a", "wav", "aif", "aiff", "caf", "mp3", "aac"].contains(url.pathExtension.lowercased()) {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent("orca-speech-\(UUID().uuidString).m4a")
            let d = try await AVURLAsset(url: url).load(.duration).seconds
            try await extractAudio(url: url, start: 0, end: d, to: t, progress: { _ in })
            source = t; temp = t
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        let d = UserDefaults.standard
        let locale = d.string(forKey: "voiceLocale") ?? Locale.current.identifier
        let onDevice = d.object(forKey: "voiceOnDevice") as? Bool ?? true
        guard let text = await CaptureRecorder.transcribeFile(source, locale: locale, onDevice: onDevice),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscribeError.nothing }
        return text
    }

    // MARK: Words

    /// "0:08", "1:02:03", or with tenths "0:08.4".
    static func clock(_ s: Double, tenths: Bool = false) -> String {
        let s = max(0, s)
        let total = Int(s.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        guard tenths else { return base }
        return base + ".\(min(9, Int(((s - Double(total)) * 10).rounded(.down))))"
    }

    /// "13 s", "4.5 s", "2 min 5 s".
    static func span(_ s: Double) -> String {
        if s < 10 { let r = (s * 10).rounded() / 10; return r == r.rounded() ? "\(Int(r)) s" : String(format: "%.1f s", r) }
        if s < 60 { return "\(Int(s.rounded())) s" }
        let t = Int(s.rounded()), m = t / 60, sec = t % 60
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        return sec == 0 ? "\(m) min" : "\(m) min \(sec) s"
    }
}
