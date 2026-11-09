import Foundation
import CoreML
import CryptoKit
import Observation

/// "Orca's private AI": the heavy on-device models people unlock once. They're downloads (not
/// bundled) because they run on this Mac instead of a server: the AI comes to the files.
///   Understands your photos — Apple MobileCLIP-S2 (picture search by description)
///   Pro eraser             — LaMa (best-quality object removal; the quick eraser is built in)
///   Hears you clearly       — the speech model in SpeechModel (owned there; driven from here)
/// The UI names what each one does, never the model.
@MainActor
@Observable
final class PrivateAI {
    static let shared = PrivateAI()

    enum Skill: String, CaseIterable, Identifiable {
        case photos, eraser, voice
        var id: String { rawValue }

        var title: String {
            switch self {
            case .photos: return "Understands your photos"
            case .eraser: return "Pro eraser"
            case .voice: return "Hears you clearly"
            }
        }
        var pitch: String {
            switch self {
            case .photos: return "Search “our holiday by the sea” and find those photos, even when they’re called IMG_4122."
            case .eraser: return "Remove people, wires and clutter from photos in one stroke."
            case .voice: return "Voice notes and voice search that get names and numbers right."
            }
        }
        var symbol: String {
            switch self { case .photos: return "sparkles"; case .eraser: return "eraser"; case .voice: return "mic" }
        }
        @MainActor var bytes: Int64 {
            switch self { case .photos: return 190_000_000; case .eraser: return 210_000_000; case .voice: return SpeechModel.downloadBytes }
        }
        @MainActor var sizeLabel: String {
            switch self { case .photos: return "190 MB"; case .eraser: return "200 MB"; case .voice: return SpeechModel.downloadLabel }
        }
        var unlockedToast: String {
            switch self {
            case .photos: return "Photo understanding unlocked. Try “our holiday by the sea”."
            case .eraser: return "Pro eraser unlocked. Open a photo and paint over anything."
            case .voice: return "Voice unlocked. Voice notes now get names and numbers right."
            }
        }
        /// The voice model only runs on Apple silicon and only understands English.
        @MainActor var isSupported: Bool { self == .voice ? SpeechModel.isSupported : true }
    }

    enum State: Equatable {
        case locked
        case unlocking(Double)      // 0…1
        case preparing              // macOS readying it for this Mac's chip
        case unlocked
        case failed(String)
    }

    private var own: [Skill: State] = [:]
    private var queue: [Skill] = []
    @ObservationIgnored private var job: Task<Void, Never>?

    private init() {
        for s in [Skill.photos, .eraser] { own[s] = Self.isInstalled(s) ? .unlocked : .locked }
        let d = UserDefaults.standard
        if d.object(forKey: Keys.firstSeen) == nil { d.set(Date(), forKey: Keys.firstSeen) }
    }

    // MARK: State

    func state(_ s: Skill) -> State {
        if s == .voice {
            switch SpeechModel.shared.state {
            case .notInstalled: return queue.contains(.voice) ? .unlocking(0) : .locked
            case .downloading(let f): return .unlocking(f)
            case .preparing: return .preparing
            case .ready: return .unlocked
            case .failed(let m): return .failed(m)
            }
        }
        if case .locked = own[s] ?? .locked, queue.contains(s) { return .unlocking(0) }
        return own[s] ?? .locked
    }

    func isUnlocked(_ s: Skill) -> Bool { state(s) == .unlocked }

    var available: [Skill] { Skill.allCases.filter(\.isSupported) }
    var locked: [Skill] { available.filter { if case .unlocked = state($0) { return false }; return !isWorking($0) } }
    var unlockedCount: Int { available.filter(isUnlocked).count }

    func isWorking(_ s: Skill) -> Bool {
        switch state(s) { case .unlocking, .preparing: return true; default: return false }
    }
    var isBusy: Bool { available.contains(where: isWorking) }

    /// 0…1 across everything being unlocked right now (for the top-bar pill).
    var overallProgress: Double {
        let working = available.filter { isWorking($0) || (isUnlocked($0) && sessionSkills.contains($0)) }
        let total = working.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return 0 }
        let done = working.reduce(0.0) { acc, s in
            switch state(s) {
            case .unlocked: return acc + Double(s.bytes)
            case .preparing: return acc + Double(s.bytes) * 0.97
            case .unlocking(let f): return acc + Double(s.bytes) * f
            default: return acc
            }
        }
        return done / Double(total)
    }
    /// Skills unlocked or started in this batch, so the pill's percentage doesn't jump back.
    private var sessionSkills: Set<Skill> = []

    /// For snapshots: show a skill mid-download without downloading.
    func debugShow(_ s: Skill, _ st: State) { own[s] = st; if case .unlocking = st { sessionSkills.insert(s) } }

    // MARK: Unlocking

    func unlock(_ skills: [Skill]) {
        let todo = skills.filter { $0.isSupported && !isUnlocked($0) && !isWorking($0) && !queue.contains($0) }
        guard !todo.isEmpty else { return }
        let need = todo.reduce(Int64(0)) { $0 + $1.bytes } * 2
        if SpeechModel.freeBytes < need {
            AppState.shared.showToast("Not enough space: Orca’s private AI needs about \(Fmt.size(need)) free")
            return
        }
        if !isBusy { sessionSkills = [] }
        queue.append(contentsOf: todo)
        sessionSkills.formUnion(todo)
        UserDefaults.standard.set(true, forKey: Keys.everStarted)
        runNext()
    }

    func cancel(_ s: Skill) {
        queue.removeAll { $0 == s }
        if s == .voice { SpeechModel.shared.cancel(); return }
        if current == s { job?.cancel() }
        own[s] = Self.isInstalled(s) ? .unlocked : .locked
    }

    func remove(_ s: Skill) {
        cancel(s)
        switch s {
        case .voice: SpeechModel.shared.remove()
        case .photos:
            for f in ["mobileclip_s2_image.mlmodelc", "mobileclip_s2_text.mlmodelc"] { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(f)) }
            MobileCLIP.reload()
        case .eraser:
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("LaMa.mlmodelc"))
            Eraser.reload()
        }
        if s != .voice { own[s] = Self.isInstalled(s) ? .unlocked : .locked }
    }

    private var current: Skill?
    /// The dev self-test turns this off so it doesn't rescan the real home folders.
    @ObservationIgnored var rescanAfterPhotos = true

    private func runNext() {
        guard current == nil, let s = queue.first else { return }
        current = s
        job = Task { [weak self] in
            guard let self else { return }
            do {
                switch s {
                case .voice: try await self.runVoice()
                case .photos, .eraser: try await self.fetch(s)
                }
                self.finished(s, error: nil)
            } catch {
                self.finished(s, error: error)
            }
        }
    }

    private func finished(_ s: Skill, error: Error?) {
        queue.removeAll { $0 == s }
        current = nil
        job = nil
        if let error {
            if !(error is CancellationError) {
                if s != .voice { own[s] = .failed("Couldn’t finish. Check the connection and try again.") }
                NSLog("OrcaFind: private AI \(s.rawValue) failed: \(error)")
            }
        } else if isUnlocked(s) {
            AppState.shared.showToast(s.unlockedToast)
            if s == .photos {
                MobileCLIP.reload()
                MobileCLIP.warmUp()
                if rescanAfterPhotos { FileIndex.shared.rescan() }   // embeds every photo so descriptions find them
            }
            if s == .eraser { Eraser.reload() }
        }
        runNext()
    }

    /// The voice model has its own downloader; wait for it to finish.
    private func runVoice() async throws {
        let m = SpeechModel.shared
        m.download()
        while true {
            try await Task.sleep(nanoseconds: 400_000_000)
            switch m.state {
            case .ready: return
            case .failed(let msg): throw EditError.message(msg)
            case .notInstalled: throw CancellationError()
            default: continue
            }
        }
    }

    // MARK: Downloading Core ML packages

    private struct Package { let base: URL; let name: String; let compiled: String }

    /// Hosted on our own Hugging Face organisation (grj-models), pinned to the exact upload this
    /// version was tested with, so later changes to those repos never affect it.
    private static let photosRepo = URL(string: "https://huggingface.co/grj-models/mobileclip-s2-coreml/resolve/76a7536dfca8aa54420c40b0d3fa25126d7679fd")!
    private static let eraserRepo = URL(string: "https://huggingface.co/grj-models/lama-coreml/resolve/843e74d03f23115141a84db365289ae8f9034c2f")!

    private static func packages(_ s: Skill) -> [Package] {
        switch s {
        case .photos:
            return ["image", "text"].map { Package(base: photosRepo, name: "mobileclip_s2_\($0).mlpackage", compiled: "mobileclip_s2_\($0).mlmodelc") }
        case .eraser:
            return [Package(base: eraserRepo, name: "LaMa.mlpackage", compiled: "LaMa.mlmodelc")]
        case .voice: return []
        }
    }

    /// SHA-256 of every file we download; anything else is thrown away.
    private static let fingerprints: [String: String] = [
        "mobileclip_s2_image.mlpackage/Manifest.json": "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6",
        "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel": "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b",
        "mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00",
        "mobileclip_s2_text.mlpackage/Manifest.json": "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0",
        "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/model.mlmodel": "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80",
        "mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce",
        "LaMa.mlpackage/Manifest.json": "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58",
        "LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel": "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953",
        "LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184",
    ]

    /// Streams the file through SHA-256 (weights are hundreds of MB).
    nonisolated static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let packageFiles = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]

    private func fetch(_ s: Skill) async throws {
        own[s] = .unlocking(0)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("orca-private-ai-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var done: Int64 = 0
        let total = Double(s.bytes)
        for p in Self.packages(s) {
            let pkg = tmp.appendingPathComponent(p.name)
            for f in Self.packageFiles {
                let dest = pkg.appendingPathComponent(f)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = done
                let got = try await FileDownloader.fetch(p.base.appendingPathComponent(p.name).appendingPathComponent(f), to: dest) { written in
                    Task { @MainActor in
                        if case .unlocking = self.own[s] { self.own[s] = .unlocking(min(0.97, Double(base + written) / total)) }
                    }
                }
                done += got
                let key = p.name + "/" + f
                let digest = await Task.detached(priority: .utility) { Self.sha256(dest) }.value
                guard let want = Self.fingerprints[key], digest == want else {
                    throw EditError.message("A downloaded file didn’t match. Try again.")
                }
            }
        }
        try Task.checkCancellation()
        own[s] = .preparing
        for p in Self.packages(s) {
            let compiled = try await MLModel.compileModel(at: tmp.appendingPathComponent(p.name))
            let target = Self.folder.appendingPathComponent(p.compiled)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: compiled, to: target)
        }
        own[s] = Self.isInstalled(s) ? .unlocked : .failed("The download didn’t finish. Try again.")
    }

    // MARK: Where the models live

    /// Next to the voice model: ~/Library/Application Support/OrcaFind/Models.
    /// `ORCA_MODELS_DIR` points it elsewhere for testing.
    static var folder: URL {
        if let o = ProcessInfo.processInfo.environment["ORCA_MODELS_DIR"] { return URL(fileURLWithPath: o, isDirectory: true) }
        return SpeechModel.modelsFolder
    }

    static func isInstalled(_ s: Skill) -> Bool {
        switch s {
        case .photos: return MobileCLIP.modelsInstalled
        case .eraser: return Eraser.isAvailable(.best)
        case .voice: return SpeechModel.isInstalled
        }
    }

    /// Where to look for a compiled model: the downloads folder, the app bundle, then (when run
    /// from `.build`) the project's Resources/Models, unless ORCA_NO_DEV_MODELS is set.
    nonisolated static func find(_ name: String) -> URL? {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let o = ProcessInfo.processInfo.environment["ORCA_MODELS_DIR"] { dirs.append(URL(fileURLWithPath: o)) }
        else if let a = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(a.appendingPathComponent("OrcaFind/Models"))
        }
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Models")) }
        // ORCA_NO_DEV_MODELS hides the project's big models (to test unlocking), not the small bundled files.
        if ProcessInfo.processInfo.environment["ORCA_NO_DEV_MODELS"] == nil || !name.hasSuffix(".mlmodelc") {
            var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<5 { dirs.append(dir.appendingPathComponent("Resources/Models")); dir = dir.deletingLastPathComponent() }
        }
        for d in dirs {
            let u = d.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    // MARK: Reminders: one Home card 3 days in, once more 2 weeks after "Maybe later", then never

    enum Keys {
        static let firstSeen = "privateAI.firstSeen"
        static let remindCount = "privateAI.remindCount"
        static let lastRemind = "privateAI.lastRemind"
        static let noReminders = "privateAI.noReminders"
        static let everStarted = "privateAI.everStarted"
    }

    var remindersOn: Bool {
        get { access(keyPath: \.remindersOn); return !UserDefaults.standard.bool(forKey: Keys.noReminders) }
        set { withMutation(keyPath: \.remindersOn) { UserDefaults.standard.set(!newValue, forKey: Keys.noReminders) } }
    }
    private var reminderTick = 0

    /// The skills the Home card offers (the voice one only to people who'd use it).
    var reminderSkills: [Skill] { locked.filter { $0 != .voice } }

    var showsReminder: Bool {
        _ = reminderTick
        guard remindersOn, !isBusy, !reminderSkills.isEmpty else { return false }
        let d = UserDefaults.standard
        let first = d.object(forKey: Keys.firstSeen) as? Date ?? Date()
        let count = d.integer(forKey: Keys.remindCount)
        if ProcessInfo.processInfo.environment["ORCA_SHOW_REMINDER"] != nil { return true }
        switch count {
        case 0: return Date().timeIntervalSince(first) > 3 * 86_400
        case 1: return Date().timeIntervalSince(d.object(forKey: Keys.lastRemind) as? Date ?? first) > 14 * 86_400
        default: return false
        }
    }

    func reminderLater() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: Keys.remindCount) + 1, forKey: Keys.remindCount)
        d.set(Date(), forKey: Keys.lastRemind)
        reminderTick += 1
    }

    func reminderNever() { remindersOn = false; reminderTick += 1 }
}

/// One file over HTTPS with progress; cancels with the surrounding task.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Int64, Error>?
    private let dest: URL
    private let progress: @Sendable (Int64) -> Void
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var bytes: Int64 = 0

    private init(dest: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.dest = dest; self.progress = progress
    }

    /// Returns the number of bytes received.
    static func fetch(_ url: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let d = FileDownloader(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                d.continuation = c
                let t = session.downloadTask(with: url)
                d.task = t
                t.resume()
            }
        } onCancel: { d.task?.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = EditError.message("The server said \(http.statusCode)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation; continuation = nil
        if let error { c?.resume(throwing: (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error) }
        else if let moveError { c?.resume(throwing: moveError) }
        else { c?.resume(returning: bytes) }
    }
}
