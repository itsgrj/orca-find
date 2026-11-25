import Foundation
import CryptoKit
import Observation
import llama

/// The optional on-device text model (Qwen3 4B Instruct 2507, Apache-2.0, 4-bit) for Macs without Apple
/// Intelligence. It reads voice notes the way Apple's model does on newer Macs: which name was misheard, what
/// the person finally asked to tag it or where to put it. A 2.5 GB download from Settings; it runs on this Mac only.
/// The UI never names the model ("Understands what you meant").
@MainActor
@Observable
final class LocalModel {
    static let shared = LocalModel()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        /// Checking the download is complete and untouched.
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .notInstalled
    private(set) var rate: Double = 0

    nonisolated static let fileName = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    nonisolated static let source = URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!
    nonisolated static let sha256 = "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
    nonisolated static let downloadBytes: Int64 = 2_497_281_120
    nonisolated static let downloadLabel = "2.5 GB"
    nonisolated static let neededBytes: Int64 = 3_500_000_000

    nonisolated static var folder: URL { CaptureStore.baseDirectory.appendingPathComponent("Models", isDirectory: true) }
    nonisolated static var file: URL { folder.appendingPathComponent(fileName) }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Apple silicon with enough memory to hold it next to everything else (it takes about 3 GB while reading).
    static var isSupported: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.physicalMemory >= 8 * 1_073_741_824
        #else
        return false
        #endif
    }

    /// Only offered where Apple Intelligence can't do the same job.
    static var isNeeded: Bool { SentenceUnderstanding.status != .available }

    var isReady: Bool { state == .ready }
    var isBusy: Bool { if case .downloading = state { return true }; return state == .preparing }

    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var delegate: DownloadDelegate?
    @ObservationIgnored private var lastSample: (time: Date, fraction: Double)?
    @ObservationIgnored let runner = LlamaRunner()

    private init() { state = Self.isInstalled ? .ready : .notInstalled }

    // MARK: Download

    func download() {
        guard Self.isSupported, !isBusy, state != .ready else { return }
        state = .downloading(0)
        rate = 0
        lastSample = nil
        try? FileManager.default.createDirectory(at: LocalModel.folder, withIntermediateDirectories: true)
        job = Task { [weak self] in
            do {
                let tmp = try await Self.fetch { f in Task { @MainActor in self?.progressed(f) } }
                await MainActor.run { self?.state = .preparing }
                let ok = try await Task.detached(priority: .utility) { try Self.verify(tmp) }.value
                guard ok else {
                    try? FileManager.default.removeItem(at: tmp)
                    await MainActor.run { self?.state = .failed("The download was damaged. Try again."); self?.job = nil }
                    return
                }
                try? FileManager.default.removeItem(at: Self.file)
                try FileManager.default.moveItem(at: tmp, to: Self.file)
                await MainActor.run { self?.state = .ready; self?.job = nil }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.job = nil
                    if Task.isCancelled || error is CancellationError { self.state = .notInstalled; return }
                    NSLog("OrcaFind: text model download failed: \(error)")
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

    func remove() {
        cancel()
        Task { await runner.unload() }
        try? FileManager.default.removeItem(at: Self.file)
        state = .notInstalled
    }

    private nonisolated static func fetch(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate.finish = { result in cont.resume(with: result) }
                session.downloadTask(with: source).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private nonisolated static func verify(_ url: URL) throws -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }

    private func progressed(_ f: Double) {
        guard case .downloading = state else { return }
        let now = Date()
        if let last = lastSample, now.timeIntervalSince(last.time) > 0.8, f > last.fraction {
            let r = (f - last.fraction) * Double(Self.downloadBytes) / now.timeIntervalSince(last.time)
            rate = rate == 0 ? r : rate * 0.7 + r * 0.3
            lastSample = (now, f)
        } else if lastSample == nil {
            lastSample = (now, f)
        }
        state = .downloading(min(f, 0.999))
    }

    var progressText: String {
        switch state {
        case .downloading(let f):
            let done = Double(Self.downloadBytes) * f / 1_000_000_000
            var s = String(format: "%.1f of %@", done, Self.downloadLabel)
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
        if ns.domain == NSURLErrorDomain,
           [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(ns.code) {
            return "No internet. Try again when you’re online."
        }
        if SpeechModel.freeBytes < neededBytes { return "Not enough free space on this Mac." }
        return "The download stopped. Try again."
    }

    // MARK: Reading

    /// One answer in the shape `grammar` allows, or nil. Loads the model on first use; lets it go after a few idle minutes.
    func respond(system: String, user: String, grammar: String, maxTokens: Int = 160, file: URL? = nil) async -> String? {
        guard isReady || file != nil else { return nil }
        let prompt = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        return await runner.generate(model: file ?? Self.file, prompt: prompt, grammar: grammar, maxTokens: maxTokens)
    }
}

/// Reports progress and hands back the finished file (moved out of the system's temporary spot before it's deleted).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    var finish: ((Result<URL, Error>) -> Void)?
    private var done = false

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : LocalModel.downloadBytes
        progress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = LocalModel.folder.appendingPathComponent(LocalModel.fileName + ".part")
        try? FileManager.default.removeItem(at: dest)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            complete(.success(dest))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)) }
    }

    private func complete(_ r: Result<URL, Error>) {
        guard !done else { return }
        done = true
        finish?(r)
    }
}

/// llama.cpp, one request at a time, off the main thread.
actor LlamaRunner {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var loadedPath: String?
    private var idle: Task<Void, Never>?
    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)   // quiet: llama.cpp otherwise prints every tensor it loads
        llama_backend_init()
    }()

    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; loadedPath = nil
    }

    private func load(_ url: URL) -> Bool {
        if loadedPath == url.path, ctx != nil { return true }
        unload()
        _ = Self.backend
        let mp = llama_model_default_params()
        guard let m = llama_model_load_from_file(url.path, mp) else { return false }
        var cp = llama_context_default_params()
        cp.n_ctx = 2048
        cp.n_batch = 2048
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); return false }
        model = m; ctx = c; loadedPath = url.path
        return true
    }

    func generate(model url: URL, prompt: String, grammar: String, maxTokens: Int) -> String? {
        idle?.cancel()
        defer {
            idle = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.unload()
            }
        }
        guard load(url), let model, let ctx, let vocab = llama_model_get_vocab(model) else { return nil }
        llama_memory_clear(llama_get_memory(ctx), true)

        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
        let n = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
        guard n > 0, n < 2048 - Int32(maxTokens) else { return nil }
        tokens.removeLast(tokens.count - Int(n))
        let ok = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
        }
        guard ok else { return nil }

        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return nil }
        defer { llama_sampler_free(chain) }
        guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { return nil }
        llama_sampler_chain_add(chain, g)
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        var out: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            var tok = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            let len = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            if len > 0 { out.append(contentsOf: piece[0..<Int(len)].map { UInt8(bitPattern: $0) }) }
            let stepOK = withUnsafeMutablePointer(to: &tok) { llama_decode(ctx, llama_batch_get_one($0, 1)) == 0 }
            if !stepOK { break }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
