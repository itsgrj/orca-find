import AppKit
import Speech
import AVFoundation

/// Records the "why" right after a grab: live transcript (on-device when possible) plus an .m4a of the voice.
/// Stopping talking for ~2 s ends it — there is no Save button.
@MainActor
@Observable
final class CaptureRecorder {
    var transcript = ""
    var isRecording = false
    var level: Float = 0
    /// Recent levels for the little waveform in the strip.
    var levels: [Float] = Array(repeating: 0, count: 28)
    var elapsed: TimeInterval = 0
    var heardSpeech = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private let writer = AudioWriter()
    @ObservationIgnored private var onSilence: (() -> Void)?
    /// On-device recognition starts a fresh transcript after a pause; this keeps every segment.
    @ObservationIgnored private var joiner = SegmentJoiner()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private let feed = RequestFeed()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restarts = 0

    /// Seconds of quiet after speech that end the recording.
    static let quietSeconds: Double = 2.0
    /// If nothing is said at all, save anyway after this long.
    static let nothingSaidSeconds: Double = 7.0

    enum StartError: LocalizedError {
        case speechDenied, micDenied, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .speechDenied: return "Speech recognition is off for Orca — type instead"
            case .micDenied: return "Microphone is off for Orca — type instead"
            case .unavailable(let s): return s
            }
        }
    }

    func start(audioURL: URL, onSilence: @escaping () -> Void) async throws {
        self.onSilence = onSilence
        transcript = ""; joiner = SegmentJoiner(); heardSpeech = false; elapsed = 0; restarts = 0
        guard await VoiceSearch.requestSpeechPermission() else { throw StartError.speechDenied }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw StartError.micDenied }
        let prefs = Preferences.shared
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: prefs.voiceLocale)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { throw StartError.unavailable("Speech isn’t available right now — type instead") }

        self.recognizer = recognizer

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw StartError.unavailable("No microphone found — type instead")
        }
        writer.open(url: audioURL, format: format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: CaptureRecorder.makeTap(feed, writer))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            writer.close()
            throw StartError.unavailable("Microphone is busy — type instead")
        }

        isRecording = true
        started = Date()
        startRecognition()
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let r = CaptureRecorder.current
                guard let r, r.isRecording else { return }
                r.elapsed = Date().timeIntervalSince(r.started)
                r.levels.removeFirst()
                r.levels.append(r.level)
            }
        }
        CaptureRecorder.current = self
        armSilence(Self.nothingSaidSeconds)
    }

    static weak var current: CaptureRecorder?

    /// A new recognition request on the same mic stream (at start, and again if macOS ends one after a long pause).
    private func startRecognition() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition && Preferences.shared.voiceOnDevice { req.requiresOnDeviceRecognition = true }
        request?.endAudio()
        task?.cancel()
        request = req
        feed.set(req)
        generation += 1
        task = recognizer.recognitionTask(with: req, resultHandler: CaptureRecorder.makeResultHandler(self, generation))
    }

    nonisolated private static func makeTap(_ feed: RequestFeed, _ writer: AudioWriter) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            feed.append(buffer)
            writer.write(buffer)
            let level = VoiceSearch.rms(buffer)
            DispatchQueue.main.async { CaptureRecorder.current?.level = level }
        }
    }

    nonisolated private static func makeResultHandler(_ owner: CaptureRecorder, _ gen: Int) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                guard let owner, owner.isRecording, gen == owner.generation else { return }
                if let text, !text.isEmpty {
                    owner.transcript = owner.joiner.absorb(text)
                    owner.heardSpeech = true
                    owner.armSilence(Self.quietSeconds)
                }
                if isFinal || error != nil {
                    owner.transcript = owner.joiner.commit()
                    // macOS ended this recognition (long pause); keep listening for the rest.
                    if owner.restarts < 30 { owner.restarts += 1; owner.startRecognition() }
                    if !owner.heardSpeech { owner.armSilence(Self.quietSeconds) }
                }
            }
        }
    }

    nonisolated(unsafe) static var lastFileError: String?

    /// Transcribes a saved recording from start to end — the safety net if live recognition dropped words.
    nonisolated static func transcribeFile(_ url: URL, locale: String, onDevice: Bool) async -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { lastFileError = "recognizer unavailable"; return nil }
        // Results arrive on this queue (default is main, which a waiting caller may be blocking).
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        recognizer.queue = q
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        if onDevice && recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        final class State: @unchecked Sendable {
            var joiner = SegmentJoiner(); var done = false; var task: SFSpeechRecognitionTask?
            let lock = NSLock()
        }
        let state = State()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            func finish(_ text: String?) {
                state.lock.lock(); defer { state.lock.unlock() }
                guard !state.done else { return }
                state.done = true
                c.resume(returning: text)
            }
            state.task = recognizer.recognitionTask(with: req) { result, error in
                state.lock.lock()
                if let t = result?.bestTranscription.formattedString, !t.isEmpty { _ = state.joiner.absorb(t) }
                if let error { CaptureRecorder.lastFileError = "\(error)" }
                let final = result?.isFinal ?? false
                let text = state.joiner.commitPeek()
                state.lock.unlock()
                if final || error != nil { finish(text.isEmpty ? nil : text) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
                state.task?.cancel()
                state.lock.lock(); let text = state.joiner.commitPeek(); state.lock.unlock()
                finish(text.isEmpty ? nil : text)
            }
        }
    }

    @ObservationIgnored private var extensions = 0

    private func armSilence(_ seconds: Double, extending: Bool = false) {
        silenceTask?.cancel()
        if !extending { extensions = 0 }
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            // Still hearing sound (speech the recogniser hasn't caught up with)? Wait a little longer.
            // Capped, so a noisy room can't keep it recording forever.
            if self.level > 0.08 && self.extensions < 4 { self.extensions += 1; self.armSilence(0.8, extending: true); return }
            self.onSilence?()
        }
    }

    /// Stops listening and returns the duration of the recording.
    @discardableResult
    func stop() -> TimeInterval {
        guard isRecording else { return 0 }
        isRecording = false
        silenceTask?.cancel()
        clock?.invalidate(); clock = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        transcript = joiner.commit()
        generation += 1
        request?.endAudio()
        task?.finish()
        feed.set(nil)
        task = nil; request = nil
        writer.close()
        level = 0
        onSilence = nil
        return Date().timeIntervalSince(started)
    }
}

/// Writes mic buffers to an AAC file from the audio thread.
final class AudioWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let lock = NSLock()

    func open(url: URL, format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: min(2, Int(format.channelCount)), AVEncoderBitRateKey: 64_000]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil
    }
}

/// The recognition request the mic tap currently feeds (swapped when recognition restarts).
final class RequestFeed: @unchecked Sendable {
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); let r = request; lock.unlock(); r?.append(b) }
}

/// Joins speech-recognition partials into one transcript. After a pause, on-device recognition
/// starts over with only the new words; this notices the restart and keeps what came before.
struct SegmentJoiner {
    private(set) var committed = ""
    private var partial = ""

    /// Takes the latest partial result; returns the whole transcript so far.
    mutating func absorb(_ text: String) -> String {
        if !partial.isEmpty && SegmentJoiner.isNewSegment(text, after: partial) {
            committed = SegmentJoiner.join(committed, partial)
        }
        partial = text
        return SegmentJoiner.join(committed, partial)
    }

    /// Ends the current segment (recognition finished); returns the whole transcript.
    mutating func commit() -> String {
        committed = SegmentJoiner.join(committed, partial)
        partial = ""
        return committed
    }

    func commitPeek() -> String { SegmentJoiner.join(committed, partial) }

    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    static func isNewSegment(_ new: String, after old: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }.map(String.init).joined()
        }
        let n = norm(new), o = norm(old)
        if n.isEmpty { return false }
        if o.hasPrefix(n) && n.count > 8 { return false }        // recogniser trimmed its own tail
        let firstN = n.split(separator: " ").first, firstO = o.split(separator: " ").first
        if Double(n.count) < Double(o.count) * 0.6 { return true } // much shorter: it started over
        return firstN != firstO && n.count < o.count             // different start, not growing
    }
}
