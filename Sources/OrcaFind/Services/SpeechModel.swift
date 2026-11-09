import Foundation
import FluidAudio

/// The optional English speech model (NVIDIA Parakeet TDT 0.6B v2, CC-BY-4.0) that makes voice notes
/// more accurate. Never bundled: people download it from Settings or the one-time tip in Captures.
/// Orca keeps its own copy in Application Support/OrcaFind/Models. The UI never names the model.
@MainActor
@Observable
final class SpeechModel {
    static let shared = SpeechModel()

    enum State: Equatable {
        case notInstalled
        /// 0…1 of the whole job (download, then getting the model ready on this Mac).
        case downloading(Double)
        /// Downloaded; macOS is preparing it for this Mac's chip (only the first time).
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .notInstalled
    /// Bytes per second while downloading, for the "about N min left" estimate.
    private(set) var rate: Double = 0

    /// What the download weighs (Preprocessor + Encoder + Decoder + JointDecision + vocabulary).
    static let downloadBytes: Int64 = 463_000_000
    static let downloadLabel = "460 MB"
    /// Room needed on disk: the download plus what macOS keeps after preparing it.
    static let neededBytes: Int64 = 700_000_000

    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var manager: AsrManager?
    @ObservationIgnored private var unload: Task<Void, Never>?
    @ObservationIgnored private var lastSample: (time: Date, fraction: Double)?

    private init() {
        state = Self.isInstalled ? .ready : .notInstalled
    }

    // MARK: Where it lives

    static var modelsFolder: URL {
        CaptureStore.baseDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// FluidAudio wants the folder named after the model ("…/Models/parakeet-tdt-0.6b-v2-coreml").
    static var directory: URL {
        modelsFolder.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v2).lastPathComponent, isDirectory: true)
    }

    static var isInstalled: Bool { AsrModels.modelsExist(at: directory, version: .v2) }

    // MARK: Can this Mac use it?

    /// Apple silicon only — on Intel it would be too slow, so the option doesn't appear at all.
    static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// The model only understands English.
    static var languageIsEnglish: Bool { Preferences.shared.voiceLocale.lowercased().hasPrefix("en") }

    static var freeBytes: Int64 {
        let url = CaptureStore.baseDirectory
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    static var hasRoom: Bool { freeBytes >= neededBytes }

    var isReady: Bool { state == .ready }
    var isBusy: Bool {
        switch state { case .downloading, .preparing: return true; default: return false }
    }

    // MARK: Download / cancel / remove

    func download() {
        guard Self.isSupported, !isBusy, state != .ready else { return }
        state = .downloading(0)
        rate = 0
        lastSample = nil
        try? FileManager.default.createDirectory(at: Self.modelsFolder, withIntermediateDirectories: true)
        job = Task { [weak self] in
            do {
                _ = try await AsrModels.download(to: Self.directory, version: .v2) { progress in
                    Task { @MainActor in self?.progressed(progress) }
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.state = Self.isInstalled ? .ready : .failed("The download didn’t finish. Try again.")
                    self.job = nil
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.job = nil
                    if Task.isCancelled || error is CancellationError { self.state = .notInstalled; return }
                    NSLog("OrcaFind: speech model download failed: \(error)")
                    self.state = .failed(Self.friendly(error))
                }
            }
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        state = Self.isInstalled ? .ready : .notInstalled
    }

    /// Deletes the download. Voice notes keep the words they have; new ones use the built-in recognizer.
    func remove() {
        cancel()
        manager = nil
        try? FileManager.default.removeItem(at: Self.directory)
        state = .notInstalled
    }

    private func progressed(_ p: DownloadProgress) {
        guard isBusy else { return }
        switch p.phase {
        case .compiling:
            state = .preparing
        case .listing:
            state = .downloading(0)
        case .downloading:
            // FluidAudio reports the download as the first half (0–0.5) and preparing as the second.
            let f = max(0, min(1, p.fractionCompleted / 0.5))
            let now = Date()
            if let last = lastSample, now.timeIntervalSince(last.time) > 0.8, f > last.fraction {
                let bytes = (f - last.fraction) * Double(Self.downloadBytes)
                let r = bytes / now.timeIntervalSince(last.time)
                rate = rate == 0 ? r : rate * 0.7 + r * 0.3
                lastSample = (now, f)
            } else if lastSample == nil {
                lastSample = (now, f)
            }
            if f >= 0.999 { state = .preparing } else { state = .downloading(f) }
        }
    }

    /// "176 of 460 MB · about 1 min left"
    var progressText: String {
        switch state {
        case .downloading(let f):
            let done = Int(f * Double(Self.downloadBytes) / 1_000_000)
            var s = "\(done) of \(Self.downloadLabel)"
            if rate > 0 {
                let left = (1 - f) * Double(Self.downloadBytes) / rate
                s += left < 60 ? " · less than a minute left" : " · about \(Int((left / 60).rounded(.up))) min left"
            }
            return s
        case .preparing: return "Getting it ready on this Mac…"
        default: return ""
        }
    }

    private static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut:
                return "No internet. What’s already downloaded is kept."
            default: break
            }
        }
        if !hasRoom { return "Not enough free space on this Mac." }
        return "The download stopped. What’s already downloaded is kept."
    }

    // MARK: Transcribing

    /// Words for a saved recording. Loads the model on first use and lets it go after a few idle minutes.
    func transcribe(_ url: URL) async throws -> String {
        guard isReady else { throw CancellationError() }
        unload?.cancel()
        let m: AsrManager
        if let manager { m = manager } else {
            let models = try await AsrModels.load(from: Self.directory, version: .v2)
            let fresh = AsrManager(config: .default)
            try await fresh.loadModels(models)
            manager = fresh
            m = fresh
        }
        var decoder = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
        let result = try await m.transcribe(url, decoderState: &decoder)
        unload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.manager = nil
        }
        return result.text
    }
}
