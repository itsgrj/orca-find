import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Records the grabbed box while the person talks. The video is kept only when something in it moved
/// (an animation, a playing video, scrolling) or when they pressed V; otherwise it's thrown away and the
/// capture stays a picture. Frames are written straight to a .mov with AVAssetWriter.
final class ClipRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let maxSeconds = 30.0
    /// How many separate moments of change make it "moving". One hover highlight is 1–2; an animation is many.
    static let movingAfter = 4

    private let queue = DispatchQueue(label: "orca.clip", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var url: URL?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var finished = false
    private var detector = MotionDetector()
    private var lastCheck: Double = -1

    /// Called once on the main actor when movement is first seen.
    var onMotion: (@MainActor () -> Void)?

    private let stateLock = NSLock()
    private var _moved = false
    var moved: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _moved }

    /// `rect` is in global AppKit coordinates and lies on `screen` (same as ScreenGrab.capture).
    func start(rect: NSRect, on screen: NSScreen, to url: URL) async throws {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
        let ours = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])

        // Even pixel sizes (H.264), longest side at most 1920.
        let scale = screen.backingScaleFactor
        let fit = min(1, 1920 / max(rect.width * scale, rect.height * scale))
        let w = max(2, Int(rect.width * scale * fit) / 2 * 2)
        let h = max(2, Int(rect.height * scale * fit) / 2 * 2)

        let config = SCStreamConfiguration()
        config.sourceRect = NSRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 6

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, w * h * 3)]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw NSError(domain: "OrcaFind", code: 20, userInfo: [NSLocalizedDescriptionKey: "Can’t record video here."]) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "OrcaFind", code: 21) }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.writer = writer
            self.input = input
            self.url = url
        }
        self.stream = stream
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let writer, let input, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if firstPTS == nil {
            firstPTS = pts
            writer.startSession(atSourceTime: pts)
        }
        guard let first = firstPTS, (pts - first).seconds <= ClipRecorder.maxSeconds else { return }
        if input.isReadyForMoreMediaData, input.append(sb) { lastPTS = pts }

        // Look for movement about five times a second.
        let t = (pts - first).seconds
        if t - lastCheck >= 0.2, let pb = CMSampleBufferGetImageBuffer(sb) {
            lastCheck = t
            if detector.feed(pb), detector.changes >= ClipRecorder.movingAfter {
                stateLock.lock(); let wasMoving = _moved; _moved = true; stateLock.unlock()
                if !wasMoving, let onMotion { Task { @MainActor in onMotion() } }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("OrcaFind: clip stream stopped: \(error.localizedDescription)")
    }

    /// Stops recording. Returns the clip's length (0 if nothing was written). Keeps the file either way;
    /// call `discard()` to throw it away.
    func stop() async -> Double {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        let (writer, input, first, last): (AVAssetWriter?, AVAssetWriterInput?, CMTime?, CMTime?) = queue.sync {
            finished = true
            return (self.writer, self.input, firstPTS, lastPTS)
        }
        guard let writer, writer.status == .writing else { return 0 }
        guard let first, let last else {
            writer.cancelWriting()
            return 0
        }
        input?.markAsFinished()
        writer.endSession(atSourceTime: last + CMTime(value: 1, timescale: 30))
        await writer.finishWriting()
        return writer.status == .completed ? max(0.1, (last - first).seconds) : 0
    }

    func discard() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

/// Compares a coarse grid of pixels between one look and the next. Counts the looks where enough of the
/// grid changed, so a blinking caret or one hover highlight doesn't count but an animation does.
struct MotionDetector {
    static let grid = 24
    private var last: [UInt8]?
    private(set) var changes = 0

    /// Returns true when this frame differs from the previous one.
    @discardableResult
    mutating func feed(_ pb: CVPixelBuffer) -> Bool {
        guard let sample = MotionDetector.sample(pb) else { return false }
        defer { last = sample }
        guard let last else { return false }
        return compare(last, sample)
    }

    @discardableResult
    mutating func feed(samples: [UInt8]) -> Bool {
        defer { last = samples }
        guard let last else { return false }
        return compare(last, samples)
    }

    private mutating func compare(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var n = 0
        for i in 0..<min(a.count, b.count) where abs(Int(a[i]) - Int(b[i])) > 16 { n += 1 }
        let changed = n >= 3
        if changed { changes += 1 }
        return changed
    }

    /// Luminance at grid×grid points of a BGRA buffer.
    static func sample(_ pb: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: grid * grid)
        for gy in 0..<grid {
            let y = min(h - 1, (gy * h + h / 2) / grid)
            for gx in 0..<grid {
                let x = min(w - 1, (gx * w + w / 2) / grid)
                let o = y * row + x * 4
                let lum = (Int(p[o + 2]) * 77 + Int(p[o + 1]) * 150 + Int(p[o]) * 29) >> 8
                out[gy * grid + gx] = UInt8(lum)
            }
        }
        return out
    }
}

/// Four evenly spaced stills from a clip, for the detail page and for AI tools (which can't watch video).
enum ClipFrames {
    static func times(duration: Double, count: Int = 4) -> [Double] {
        guard duration > 0.2, count > 1 else { return [0] }
        let end = max(0, duration - 0.05)
        return (0..<count).map { end * Double($0) / Double(count - 1) }
    }

    static func frames(_ url: URL, count: Int = 4, maxPixel: CGFloat = 1400) async -> [(time: Double, image: CGImage)] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        var out: [(Double, CGImage)] = []
        for t in times(duration: duration, count: count) {
            if let r = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) { out.append((t, r.image)) }
        }
        return out
    }

    /// Blocking version for the MCP server (no run loop needed).
    static func framesSync(_ url: URL, count: Int = 4, maxPixel: CGFloat = 1000) -> [(time: Double, image: CGImage)] {
        let box = FrameBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await frames(url, count: count, maxPixel: maxPixel)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 20)
        return box.value
    }

    private final class FrameBox: @unchecked Sendable { var value: [(time: Double, image: CGImage)] = [] }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
