import AVFoundation
import AppKit

/// `OrcaFind --edit-selftest <video or audio> <outdir>`: runs every media tool's engine headlessly and checks the copies.
extension MediaWorkspaceFactory {
    static func selfTest(_ item: FileItem, out: URL) async -> Bool {
        EditKind.of(item) == .audio ? await audioTest(item, out: out) : await videoTest(item, out: out)
    }

    private final class Log: @unchecked Sendable {
        var ok = true
        func pass(_ s: String) { print("ok   \(s)") }
        func fail(_ s: String) { print("FAIL \(s)"); ok = false }
        func note(_ s: String) { print("     \(s)") }
    }

    private struct Probe {
        var duration: Double = 0
        var size: CGSize = .zero
        var video = 0, audio = 0
        var bytes: Int64 = 0
        var hasLocation = false
        var codec = ""
        var line: String {
            var p = [Fmt.size(bytes), String(format: "%.2fs", duration)]
            if video > 0 { p.append("\(Int(size.width))×\(Int(size.height))") }
            p.append(audio > 0 ? "sound" : "silent")
            if !codec.isEmpty { p.append(codec) }
            if hasLocation { p.append("location") }
            return p.joined(separator: "  ")
        }
    }

    private static func probe(_ url: URL) async -> Probe? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let (d, tracks, meta) = try? await a.load(.duration, .tracks, .metadata) else { return nil }
        var p = Probe(duration: d.seconds, bytes: MediaEngine.fileSize(url), hasLocation: meta.contains(where: MediaEngine.isLocation))
        for t in tracks {
            if t.mediaType == .video, let (s, tf, f) = try? await t.load(.naturalSize, .preferredTransform, .formatDescriptions) {
                p.video += 1
                let r = CGRect(origin: .zero, size: s).applying(tf)
                p.size = CGSize(width: abs(r.width), height: abs(r.height))
                if let fd = f.first { p.codec = MediaEngine.fourCC(CMFormatDescriptionGetMediaSubType(fd)) }
            }
            if t.mediaType == .audio {
                p.audio += 1
                if p.codec.isEmpty, let f = try? await t.load(.formatDescriptions).first { p.codec = MediaEngine.fourCC(CMFormatDescriptionGetMediaSubType(f)) }
            }
        }
        return p
    }

    private static func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

    // MARK: Video

    private static func videoTest(_ item: FileItem, out: URL) async -> Bool {
        let log = Log()
        let url = item.url
        guard let info = try? await MediaEngine.loadVideo(url) else { log.fail("load"); return false }
        print("video: \(Int(info.orientedSize.width))×\(Int(info.orientedSize.height))  \(String(format: "%.2f", info.duration))s  \(info.fps) fps  \(info.codec)  sound: \(info.hasAudio)  location: \(info.hasLocation)  \(Fmt.size(info.fileSize))")
        let ws = VideoWorkspace(item: item)
        for _ in 0..<100 where ws.info == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        let full = VideoEdits(start: 0, end: info.duration)
        let o = info.orientedSize

        func export(_ name: String, _ e: VideoEdits, ext: String = "mov", check: (Probe) -> String?) async {
            let dest = out.appendingPathComponent("\(name).\(ext)")
            let t0 = Date()
            do {
                try await MediaEngine.exportVideo(url: url, info: info, edits: e, to: dest, progress: { _ in })
                guard let p = await probe(dest) else { log.fail("\(name): no file"); return }
                let est = ws.estimate(e)
                let extra = String(format: "  est %@  %.1fs", Fmt.size(est), Date().timeIntervalSince(t0))
                if let problem = check(p) { log.fail("\(name).\(ext)  \(p.line)  — \(problem)") } else { log.pass("\(name).\(ext)  \(p.line)\(extra)") }
            } catch { log.fail("\(name): \(error.localizedDescription)") }
        }

        let a = min(2, info.duration * 0.2), b = min(info.duration, a + max(1, info.duration * 0.45))
        var trim = full; trim.start = a; trim.end = b
        await export("trimmed", trim) { p in near(p.duration, b - a, 0.25) ? nil : "length \(p.duration), wanted \(b - a)" }

        var mute = trim; mute.mute = true
        await export("trimmed-muted", mute) { p in p.audio == 0 ? nil : "still has sound" }

        var crop = full; crop.crop = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
        let cw = MediaEngine.evenFloor(o.width * 0.5), ch = MediaEngine.evenFloor(o.height * 0.8)
        await export("cropped", crop) { p in near(p.size.width, cw, 2) && near(p.size.height, ch, 2) ? nil : "size \(p.size), wanted \(cw)×\(ch)" }

        var rot = full; rot.turns = 1
        await export("rotated", rot) { p in near(p.size.width, o.height, 2) && near(p.size.height, o.width, 2) ? nil : "size \(p.size) not turned" }

        var flip = full; flip.flip = true
        await export("flipped", flip) { p in near(p.size.width, o.width, 2) ? nil : "size \(p.size)" }

        var combo = trim; combo.turns = 3; combo.flip = true; combo.crop = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        await export("crop-turn-flip", combo) { _ in nil }

        var resize = full; resize.size = 480
        await export("resized-480", resize) { p in near(min(p.size.width, p.size.height), 480, 2) || min(o.width, o.height) <= 480 ? nil : "short side \(min(p.size.width, p.size.height))" }

        var mp4 = full; mp4.mp4 = true; mp4.stripLocation = true
        await export("as-mp4-no-location", mp4, ext: "mp4") { p in p.hasLocation ? "location still there" : nil }

        var keepLoc = full; keepLoc.mp4 = true
        await export("as-mp4", keepLoc, ext: "mp4") { p in info.hasLocation && !p.hasLocation ? "location lost" : nil }

        var mp4_720 = full; mp4_720.mp4 = true; mp4_720.size = 720
        await export("as-mp4-720p", mp4_720, ext: "mp4") { p in near(min(p.size.width, p.size.height), min(720, min(o.width, o.height)), 2) ? nil : "size \(p.size)" }

        print("compress: original \(Fmt.size(info.fileSize))")
        for c in VideoCompress.allCases {
            var e = full; e.compress = c; e.mp4 = true
            await export("compressed-\(c.shortSide)p", e, ext: "mp4") { p in
                near(min(p.size.width, p.size.height), CGFloat(min(c.shortSide, Int(min(o.width, o.height)))), 2) ? nil : "size \(p.size)"
            }
        }

        // GIF
        for g in [MediaEngine.GIFSettings(width: 320, fps: 10), MediaEngine.GIFSettings(width: 480, fps: 15)] {
            let dest = out.appendingPathComponent("clip-\(g.width)-\(g.fps).gif")
            do {
                let est = await MediaEngine.estimateGIF(url: url, info: info, edits: trim, settings: g)
                let bytes = try await MediaEngine.makeGIF(url: url, info: info, edits: trim, settings: g, to: dest, progress: { _ in })
                let src = CGImageSourceCreateWithURL(dest as CFURL, nil)
                let frames = src.map(CGImageSourceGetCount) ?? 0
                let props = src.flatMap { CGImageSourceCopyProperties($0, nil) as? [String: Any] }
                let loop = (props?[kCGImagePropertyGIFDictionary as String] as? [String: Any])?[kCGImagePropertyGIFLoopCount as String] as? Int
                let first = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                let want = MediaEngine.gifFrameCount(seconds: b - a, fps: g.fps)
                if frames == want, loop == 0, first?.width == g.width || first.map({ $0.width <= g.width }) == true {
                    log.pass("\(dest.lastPathComponent)  \(Fmt.size(bytes))  \(frames) frames  \(first?.width ?? 0)×\(first?.height ?? 0)  loop \(loop ?? -1)  est \(est.map { Fmt.size($0) } ?? "—")")
                } else { log.fail("\(dest.lastPathComponent): frames \(frames)/\(want) loop \(String(describing: loop)) width \(first?.width ?? 0)") }
            } catch { log.fail("gif: \(error.localizedDescription)") }
        }

        // Frame
        do {
            let dest = out.appendingPathComponent("frame.png")
            try await MediaEngine.saveFrame(url: url, info: info, edits: full, at: info.duration / 2, to: dest)
            let img = NSImage(contentsOf: dest)
            if let r = img?.representations.first, r.pixelsWide == Int(o.width) { log.pass("frame.png  \(r.pixelsWide)×\(r.pixelsHigh)  \(Fmt.size(MediaEngine.fileSize(dest)))") }
            else { log.fail("frame.png size \(img?.representations.first?.pixelsWide ?? 0)") }
            let dest2 = out.appendingPathComponent("frame-cropped-turned.png")
            try await MediaEngine.saveFrame(url: url, info: info, edits: combo, at: 1, to: dest2)
            if let r = NSImage(contentsOf: dest2)?.representations.first { log.pass("frame-cropped-turned.png  \(r.pixelsWide)×\(r.pixelsHigh)") } else { log.fail("frame-cropped-turned.png") }
        } catch { log.fail("frame: \(error.localizedDescription)") }

        // Sound
        if info.hasAudio {
            let dest = out.appendingPathComponent("sound.m4a")
            do {
                try await MediaEngine.extractAudio(url: url, start: trim.start, end: trim.end, to: dest, progress: { _ in })
                if let p = await probe(dest), p.audio == 1, p.video == 0, near(p.duration, b - a, 0.25) { log.pass("sound.m4a  \(p.line)") }
                else { log.fail("sound.m4a") }
            } catch { log.fail("sound: \(error.localizedDescription)") }
            await transcribe(url, isVideo: true, out: out, log: log)
        } else {
            log.note("no sound track: Pull out audio, Transcribe and Mute are greyed out")
        }

        // Names the shell will use
        ws.select(.trim); ws.beginTrim(); ws.setTrim(start: a, end: b, showing: a); ws.endTrim()
        log.note("status after trim: \(ws.status ?? "—")")
        ws.select(.muteVideo)
        log.note("status after mute: \(ws.status ?? "—")")
        ws.undo(); ws.undo()
        if ws.hasEdits { log.fail("two undos should leave no edits") } else { log.pass("undo steps back trim and mute") }
        ws.select(.saveAsMP4)
        log.note("save as MP4: \(ws.status ?? "—")")
        ws.discard()
        return log.ok
    }

    private static func transcribe(_ url: URL, isVideo: Bool, out: URL, log: Log) async {
        do {
            let text = try await MediaEngine.transcribe(url: url, isVideo: isVideo)
            try? text.write(to: out.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            log.pass("transcript: \(text)")
        } catch MediaEngine.TranscribeError.needsApp {
            log.note("transcribe skipped: needs the app bundle (speech permission)")
        } catch {
            log.fail("transcribe: \(error.localizedDescription)")
        }
    }

    // MARK: Audio

    private static func audioTest(_ item: FileItem, out: URL) async -> Bool {
        let log = Log()
        let url = item.url
        guard let info = try? await MediaEngine.loadAudio(url) else { log.fail("load"); return false }
        print("audio: \(info.formatLine)  \(String(format: "%.2f", info.duration))s  \(Fmt.size(info.fileSize))  \(Int(info.bitrate / 1000)) kbps")
        do {
            let bars = try await MediaEngine.waveform(url: url, bars: 600)
            let loud = bars.filter { $0 > 0.05 }.count
            if bars.count == 600, loud > 30 { log.pass("waveform  \(bars.count) bars, \(loud) with sound") } else { log.fail("waveform \(bars.count) bars, \(loud) loud") }
        } catch { log.fail("waveform: \(error.localizedDescription)") }

        let ws = AudioWorkspace(item: item)
        for _ in 0..<100 where ws.info == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        let a = min(1, info.duration * 0.1), b = min(info.duration, a + max(1, info.duration * 0.5))

        func write(_ name: String, _ outFmt: AudioOut, ext: String, start: Double, end: Double, codec: String) async {
            let dest = out.appendingPathComponent("\(name).\(ext)")
            do {
                try await MediaEngine.exportAudio(url: url, info: info, start: start, end: end, out: outFmt, to: dest, progress: { _ in })
                guard let p = await probe(dest) else { log.fail("\(name): no file"); return }
                ws.setTrim(start: start, end: end, showing: start)
                let est = ws.estimate(outFmt)
                if near(p.duration, end - start, 0.2), p.codec == codec { log.pass("\(name).\(ext)  \(p.line)  est \(Fmt.size(est))") }
                else { log.fail("\(name).\(ext)  \(p.line) — wanted \(codec), \(end - start)s") }
            } catch { log.fail("\(name).\(ext): \(error.localizedDescription)") }
        }

        let sameCodec = ["m4a", "wav", "aif", "aiff", "caf"].contains(item.ext.lowercased()) ? info.codec : "AAC"
        let trimExt = ["m4a", "wav", "aif", "aiff", "caf"].contains(item.ext.lowercased()) ? item.ext.lowercased() : "m4a"
        await write("trimmed", .original, ext: trimExt, start: a, end: b, codec: sameCodec)
        await write("converted", .wav, ext: "wav", start: 0, end: info.duration, codec: "PCM")
        await write("converted", .aiff, ext: "aif", start: 0, end: info.duration, codec: "PCM")
        await write("converted", .m4a(kbps: 256), ext: "m4a", start: 0, end: info.duration, codec: "AAC")
        await write("trimmed-wav", .wav, ext: "wav", start: a, end: b, codec: "PCM")
        for k in [64, 96, 128] {
            await write("compressed-\(k)k", .m4a(kbps: k), ext: "m4a", start: 0, end: info.duration, codec: "AAC")
        }
        await transcribe(url, isVideo: false, out: out, log: log)

        ws.setTrim(start: 0, end: info.duration, showing: 0)
        ws.select(.trimAudio); ws.beginTrim(); ws.setTrim(start: a, end: b, showing: a); ws.endTrim()
        log.note("status after trim: \(ws.status ?? "—")")
        ws.select(.convertAudio); ws.setOut(.wav)
        log.note("status after WAV: \(ws.status ?? "—")")
        ws.discard()
        return log.ok
    }
}
