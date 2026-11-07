import AppKit
import Speech
import AVFoundation

/// Voice search: speak a query ("pdfs from gmail last week") and it's typed into search for you.
/// Uses on-device recognition when the Mac supports it, so audio stays on the Mac.
@MainActor
@Observable
final class VoiceSearch {
    static let shared = VoiceSearch()

    var isListening = false
    var isStarting = false
    var transcript = ""
    var level: Float = 0
    var error: String?
    var isOnDevice = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var onUpdate: ((String) -> Void)?
    @ObservationIgnored private var onFinish: ((String) -> Void)?
    @ObservationIgnored private(set) var owner: String = ""

    static let hints = ["pdf", "pdfs", "screenshots", "gmail", "google drive", "chatgpt", "canva", "slack", "whatsapp",
                        "github", "dmg", "zip", "zips", "megabytes", "gigabytes", "mb", "gb", "iphone", "downloads",
                        "older than", "last week", "bigger than", "installers", "duplicates"]

    func toggle(owner: String, onUpdate: @escaping (String) -> Void, onFinish: @escaping (String) -> Void) {
        if isListening || isStarting { stop(); return }
        start(owner: owner, onUpdate: onUpdate, onFinish: onFinish)
    }

    func start(owner: String, onUpdate: @escaping (String) -> Void, onFinish: @escaping (String) -> Void) {
        guard !isListening, !isStarting else { return }
        error = nil
        self.owner = owner
        self.onUpdate = onUpdate
        self.onFinish = onFinish
        isStarting = true
        Task {
            defer { self.isStarting = false }
            guard await VoiceSearch.requestSpeechPermission() else {
                self.error = "Speech recognition is off for Orca Find. Turn it on in System Settings › Privacy & Security › Speech Recognition."
                return
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                self.error = "Microphone access is off for Orca Find. Turn it on in System Settings › Privacy & Security › Microphone."
                return
            }
            do { try self.begin() } catch { self.error = error.localizedDescription }
        }
    }

    nonisolated static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    private func begin() throws {
        let prefs = Preferences.shared
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: prefs.voiceLocale)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw NSError(domain: "OrcaFind", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available for this language right now."])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.contextualStrings = VoiceSearch.hints
        req.taskHint = .search
        isOnDevice = recognizer.supportsOnDeviceRecognition && prefs.voiceOnDevice
        if isOnDevice { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                         block: VoiceSearch.makeTap(req))
        engine.prepare()
        try engine.start()

        transcript = ""
        isListening = true
        task = recognizer.recognitionTask(with: req, resultHandler: VoiceSearch.makeResultHandler())
        armSilenceTimer(initial: true)
    }

    nonisolated private static func makeTap(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            req.append(buffer)
            let level = VoiceSearch.rms(buffer)
            DispatchQueue.main.async { VoiceSearch.shared.level = level }
        }
    }

    nonisolated private static func makeResultHandler() -> (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            let text = result.map { VoiceSearch.clean($0.bestTranscription.formattedString) }
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                let v = VoiceSearch.shared
                guard v.isListening else { return }
                if let text, !text.isEmpty {
                    v.transcript = text
                    v.onUpdate?(text)
                    v.armSilenceTimer(initial: false)
                }
                if isFinal || failed { v.finish() }
            }
        }
    }

    private func armSilenceTimer(initial: Bool) {
        silenceTask?.cancel()
        let delay: UInt64 = initial ? 7_000_000_000 : 1_600_000_000
        silenceTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            if !Task.isCancelled { self.finish() }
        }
    }

    func stop() { finish() }

    private func finish() {
        guard isListening else { return }
        isListening = false
        silenceTask?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        level = 0
        let text = transcript
        onFinish?(text)
        onFinish = nil
        onUpdate = nil
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return min(1, sqrt(sum / Float(n)) * 10)
    }

    /// Normalises what speech recognition hears into something the query parser likes.
    nonisolated static func clean(_ s: String) -> String {
        var t = s.lowercased()
        let swaps: [(String, String)] = [
            ("pdf's", "pdfs"), ("p d f", "pdf"), ("pdf s", "pdfs"), ("megabytes", "mb"), ("megabyte", "mb"),
            ("gigabytes", "gb"), ("gigabyte", "gb"), ("kilobytes", "kb"), ("chat gpt", "chatgpt"),
            ("git hub", "github"), ("what's app", "whatsapp"), ("whats app", "whatsapp"), ("screen shots", "screenshots"),
            ("d m g", "dmg"), ("zip's", "zips"), ("jpeg's", "jpegs"), ("png's", "pngs")
        ]
        for (a, b) in swaps { t = t.replacingOccurrences(of: a, with: b) }
        while let last = t.last, ".?!".contains(last) { t.removeLast() }
        return t
    }
}
