import Foundation
import CoreML
import Vision
import Accelerate

/// The picture model: turns a picture and a description into points in the same space, so "people around a
/// whiteboard" can find a photo even though no Vision label says that. Runs on this Mac; nothing leaves it.
///
/// Two models can fill this role; whichever is installed is used, SigLIP 2 first:
///   SigLIP 2 B/16-256 by Google (Apache 2.0, free for commercial use), converted to Core ML by Orca.
///   MobileCLIP-S2 by Apple (research / non-commercial licence), the original.
/// Embeddings are stored per model (`modelID`), so switching re-reads pictures once.
/// (The type keeps its old name so the rest of the app doesn't change.)
enum MobileCLIP {
    enum Backend: String, Sendable { case siglip, mobileclip }

    /// SigLIP 2 when its files are here; MobileCLIP-S2 otherwise. ORCA_PICTURE_MODEL=mobileclip forces the old one.
    static var backend: Backend {
        if ProcessInfo.processInfo.environment["ORCA_PICTURE_MODEL"] == "mobileclip" { return .mobileclip }
        return siglipInstalled ? .siglip : .mobileclip
    }
    static var modelID: String { backend == .siglip ? "siglip2-b16-256" : "mobileclip-s2" }
    static var dimensions: Int { backend == .siglip ? 768 : 512 }

    static var siglipInstalled: Bool {
        PrivateAI.find("siglip2_image.mlmodelc") != nil && PrivateAI.find("siglip2_text.mlmodelc") != nil
            && PrivateAI.find("siglip2-vocab.json") != nil && PrivateAI.find("siglip2-merges.txt") != nil
    }

    private enum Tokenizer { case clip(CLIPTokenizer), siglip(SigLIPTokenizer) }

    private final class Models: @unchecked Sendable {
        let backend: Backend
        let image: MLModel
        let text: MLModel
        let tokenizer: Tokenizer
        let constraint: MLImageConstraint
        let imageLock = NSLock()
        let textLock = NSLock()
        init(backend: Backend, image: MLModel, text: MLModel, tokenizer: Tokenizer) throws {
            self.backend = backend; self.image = image; self.text = text; self.tokenizer = tokenizer
            guard let c = image.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
                throw CocoaError(.fileReadCorruptFile)
            }
            constraint = c
        }
        var output: String { backend == .siglip ? "embedding" : "final_emb_1" }
        /// SigLIP 2 was trained on the whole picture squeezed to a square; MobileCLIP on the centre square.
        var crop: VNImageCropAndScaleOption { backend == .siglip ? .scaleFill : .centerCrop }
    }

    /// The encoders are downloaded once ("Understands your photos" in Orca's private AI) into
    /// Application Support; MobileCLIP's small tokenizer files ship in the app. See PrivateAI.find.
    static var modelsInstalled: Bool {
        siglipInstalled || (PrivateAI.find("mobileclip_s2_image.mlmodelc") != nil && PrivateAI.find("mobileclip_s2_text.mlmodelc") != nil)
    }

    private static let loadLock = NSLock()
    nonisolated(unsafe) private static var loaded: Models?
    nonisolated(unsafe) private static var failedAt: Date?

    /// Loaded on first use; tries again after a download (see `reload`).
    private static var models: Models? {
        loadLock.lock(); defer { loadLock.unlock() }
        let want = backend
        if let m = loaded, m.backend == want { return m }
        if let f = failedAt, Date().timeIntervalSince(f) < 30 { return nil }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let m: Models
            switch want {
            case .siglip:
                guard let image = PrivateAI.find("siglip2_image.mlmodelc"), let text = PrivateAI.find("siglip2_text.mlmodelc"),
                      let vocab = PrivateAI.find("siglip2-vocab.json"), let merges = PrivateAI.find("siglip2-merges.txt") else { failedAt = Date(); return nil }
                let tk = try SigLIPTokenizer(vocabURL: vocab, mergesURL: merges)
                let im = try MLModel(contentsOf: image, configuration: cfg)
                // The text side on the CPU: 7 ms a phrase, ready in ~1 s. On the Neural Engine macOS re-prepares this
                // 270 MB model on every launch (~12 s before the first search); the GPU path crashed.
                let tcfg = MLModelConfiguration()
                tcfg.computeUnits = .cpuOnly
                let tx = try MLModel(contentsOf: text, configuration: tcfg)
                m = try Models(backend: .siglip, image: im, text: tx, tokenizer: .siglip(tk))
            case .mobileclip:
                guard let image = PrivateAI.find("mobileclip_s2_image.mlmodelc"), let text = PrivateAI.find("mobileclip_s2_text.mlmodelc"),
                      let vocab = PrivateAI.find("clip-vocab.json"), let merges = PrivateAI.find("clip-merges.txt") else { failedAt = Date(); return nil }
                m = try Models(backend: .mobileclip, image: MLModel(contentsOf: image, configuration: cfg), text: MLModel(contentsOf: text, configuration: cfg),
                               tokenizer: .clip(CLIPTokenizer(vocabURL: vocab, mergesURL: merges)))
                // Still on the old model: move this Mac to SigLIP 2 in the background.
                Task { @MainActor in PrivateAI.shared.upgradePhotosIfNeeded() }
            }
            loaded = m
            return m
        } catch {
            NSLog("OrcaFind: picture model unavailable: \(error)")
            failedAt = Date()
            return nil
        }
    }

    /// After a model is downloaded or removed.
    static func reload() {
        loadLock.lock(); loaded = nil; failedAt = nil; loadLock.unlock()
        cacheLock.lock(); textCache.removeAll(); cacheLock.unlock()
        matchLock.lock(); matchCache.removeAll(); matchLock.unlock()
    }

    static var isBundled: Bool { modelsInstalled }
    static var isAvailable: Bool { models != nil }

    /// Loads both encoders and runs each once, so the first real search doesn't pay ~0.5 s.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = textVector("a photo") }
    }

    // MARK: Encoding

    /// Unit-length embedding of a picture.
    static func imageVector(_ cg: CGImage) -> [Float]? {
        guard let m = models else { return nil }
        return autoreleasepool {
            guard let fv = try? MLFeatureValue(cgImage: cg, constraint: m.constraint,
                                               options: [.cropAndScale: m.crop.rawValue]) else { return nil }
            m.imageLock.lock(); defer { m.imageLock.unlock() }
            guard let out = try? m.image.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": fv])),
                  let a = out.featureValue(for: m.output)?.multiArrayValue else { return nil }
            return normalized(a)
        }
    }

    private static var textCache: [String: [Float]] = [:]
    private static let cacheLock = NSLock()

    /// Unit-length embedding of a description. Cached per phrase; a few ms when not.
    static func textVector(_ phrase: String) -> [Float]? {
        let key = phrase.lowercased()
        cacheLock.lock()
        if let hit = textCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let m = models else { return nil }
        let ids: [Int32], length: Int
        switch m.tokenizer {
        case .clip(let t): ids = t.encode(key); length = CLIPTokenizer.contextLength
        case .siglip(let t): ids = t.encode(key); length = SigLIPTokenizer.contextLength
        }
        guard let arr = try? MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32) else { return nil }
        let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length { p[i] = i < ids.count ? ids[i] : 0 }
        m.textLock.lock()
        let out = try? m.text.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": arr]))
        m.textLock.unlock()
        guard let a = out?.featureValue(for: m.output)?.multiArrayValue else { return nil }
        let v = normalized(a)
        cacheLock.lock(); textCache[key] = v; cacheLock.unlock()
        return v
    }

    private static func normalized(_ a: MLMultiArray) -> [Float] {
        var v = [Float](repeating: 0, count: a.count)
        if a.dataType == .float32 {
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            for i in 0..<a.count { v[i] = p[i] }
        } else {
            for i in 0..<a.count { v[i] = a[i].floatValue }
        }
        var sq: Float = 0
        vDSP_svesq(v, 1, &sq, vDSP_Length(v.count))
        var s = 1 / max(sq.squareRoot(), 1e-6)
        vDSP_vsmul(v, 1, &s, &v, 1, vDSP_Length(v.count))
        return v
    }

    // MARK: Storage form (half floats, 1 KB per picture)

    static func encode(_ v: [Float]) -> Data {
        let half = v.map { Float16($0) }
        return half.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ d: Data) -> [Float]? {
        guard d.count == dimensions * MemoryLayout<Float16>.size else { return nil }   // another model's: re-read
        return d.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map { Float($0) } }
    }

    // MARK: Matching

    /// How sure a description match is. Cosine similarity isn't a probability, so the card says it in words.
    enum Strength: Int, Comparable, Sendable {
        case likely = 1, strong = 2
        static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
        var words: String { self == .strong ? "strong match" : "likely match" }
    }

    struct Match: Sendable {
        let similarity: Float
        let z: Float          // how far above this Mac's typical picture, in standard deviations
        let strength: Strength
        /// 0…1 for ranking alongside Vision label confidences.
        let weight: Float
    }

    /// Where a match starts, per model. Similarity scales differ: SigLIP 2's are smaller but calibrated
    /// (its own probability is sigmoid(112.9 × similarity − 16.8)).
    struct Calibration: Sendable {
        let minSimilarity: Float, minZ: Float, strongSimilarity: Float, strongZ: Float
        /// Ranking weight 0…1 rises from `weightFloor` over `weightSpan`.
        let weightFloor: Float, weightSpan: Float
        func weight(_ s: Float) -> Float { min(1, max(0, (s - weightFloor) / weightSpan)) }
    }
    /// MobileCLIP-S2, on this Mac's labelled set: real matches scored 0.21–0.34 and stood ≥ 3.9 sd above the rest;
    /// things that weren't there topped out at 0.19, gibberish stayed under 3 sd.
    static let mobileclipCalibration = Calibration(minSimilarity: 0.19, minZ: 3.5, strongSimilarity: 0.24, strongZ: 4.5,
                                                    weightFloor: 0.17, weightSpan: 0.17)
    /// SigLIP 2, on 600 labelled photos searched as a library where each kind is 1% (PictureModelEval):
    /// 96.6% of results right, 93% of matches found, 7 hits for things not there (MobileCLIP-S2 on the same set:
    /// 96.7%, 97%, 12). Real matches' similarity: p10 0.099, median 0.140; unrelated pictures' p99.9: 0.085.
    /// minZ is lower than MobileCLIP's: a library full of similar pictures (a folder of purple avatars) mustn't
    /// hide them from "purple gradient"; on the labelled set z between 1.5 and 3 changed nothing.
    static var siglipCalibration = Calibration(minSimilarity: 0.10, minZ: 2.0, strongSimilarity: 0.13, strongZ: 3.0,
                                                weightFloor: 0.09, weightSpan: 0.08)
    static var calibration: Calibration { backend == .siglip ? siglipCalibration : mobileclipCalibration }

    /// Pictures that look like the description (thresholds: `calibration`).
    static func matches(for phrase: String) -> [String: Match] {
        let p = prompt(phrase)
        let version = EmbeddingStore.shared.version
        matchLock.lock()
        if let hit = matchCache[p], hit.version == version { matchLock.unlock(); return hit.matches }
        matchLock.unlock()
        guard let q = textVector(p) else { return [:] }
        let found = EmbeddingStore.shared.matches(q)
        matchLock.lock()
        if matchCache.count > 32 { matchCache.removeAll() }
        matchCache[p] = (version, found)
        matchLock.unlock()
        return found
    }

    // Search, card reasons and the inspector all ask about the same phrases; answer once per index state.
    private static var matchCache: [String: (version: Int, matches: [String: Match])] = [:]
    private static let matchLock = NSLock()

    /// "tiger" → "a photo of a tiger", "business card" → "a photo of business card". On this Mac's
    /// labelled set the template lifted real matches (business card z 4.8 → 6.5) without lifting
    /// things that weren't there.
    static func prompt(_ phrase: String) -> String {
        let p = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        let what = p.contains(" ") ? p : VisualAnalyzer.phrase(p)
        return "a photo of " + what
    }
}

/// Every picture's MobileCLIP embedding, as one contiguous matrix so a search is a single
/// matrix × vector product (~1 ms for 10,000 pictures).
final class EmbeddingStore: @unchecked Sendable {
    static let shared = EmbeddingStore()
    /// Width of the rows held now (512 or 768, by model). Changes only when everything is replaced.
    private var dim = MobileCLIP.dimensions
    private var paths: [String] = []
    private var row: [String: Int] = [:]
    private var matrix: [Float] = []
    private let lock = NSLock()
    /// Bumped on every change, so cached matches know when they're stale.
    private var changes = 0
    var version: Int { lock.lock(); defer { lock.unlock() }; return changes }

    var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
    func contains(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return row[path] != nil }

    func replaceAll(_ new: [String: [Float]]) {
        lock.lock(); defer { lock.unlock() }
        changes += 1
        dim = MobileCLIP.dimensions
        paths = []; row = [:]; matrix = []
        paths.reserveCapacity(new.count); matrix.reserveCapacity(new.count * dim)
        for (p, v) in new where v.count == dim {
            row[p] = paths.count; paths.append(p); matrix += v
        }
    }

    func set(_ path: String, _ v: [Float]) {
        guard v.count == dim else { return }
        lock.lock(); defer { lock.unlock() }
        changes += 1
        if let i = row[path] {
            matrix.replaceSubrange(i * dim..<(i + 1) * dim, with: v)
        } else {
            row[path] = paths.count; paths.append(path); matrix += v
        }
    }

    func remove(_ gone: [String]) {
        lock.lock(); defer { lock.unlock() }
        for p in gone {
            guard let i = row[p] else { continue }
            changes += 1
            let last = paths.count - 1
            if i != last {   // move the last row into the hole
                let lp = paths[last]
                paths[i] = lp; row[lp] = i
                for k in 0..<dim { matrix[i * dim + k] = matrix[last * dim + k] }
            }
            paths.removeLast(); matrix.removeLast(dim); row[p] = nil
        }
    }

    func vector(_ path: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let i = row[path] else { return nil }
        return Array(matrix[i * dim..<(i + 1) * dim])
    }

    func matches(_ q: [Float]) -> [String: MobileCLIP.Match] {
        lock.lock(); defer { lock.unlock() }
        let n = paths.count
        guard n >= 2, q.count == dim else { return [:] }
        var sims = [Float](repeating: 0, count: n)
        matrix.withUnsafeBufferPointer { m in
            q.withUnsafeBufferPointer { v in
                sims.withUnsafeMutableBufferPointer { out in
                    // out[n] = M[n×dim] · q[dim]
                    vDSP_mmul(m.baseAddress!, 1, v.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(n), 1, vDSP_Length(dim))
                }
            }
        }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(sims, 1, nil, 1, &mean, &sd, vDSP_Length(n))
        sd = max(sd, 0.01)
        let c = MobileCLIP.calibration
        var out: [String: MobileCLIP.Match] = [:]
        for i in 0..<n {
            let s = sims[i]
            guard s >= c.minSimilarity else { continue }
            let z = (s - mean) / sd
            guard z >= c.minZ else { continue }
            let strength: MobileCLIP.Strength = (s >= c.strongSimilarity && z >= c.strongZ) ? .strong : .likely
            out[paths[i]] = MobileCLIP.Match(similarity: s, z: z, strength: strength, weight: c.weight(s))
        }
        return out
    }
}
