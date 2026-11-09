import Foundation
import CoreML
import Vision
import Accelerate

/// Apple's MobileCLIP-S2 (bundled in Resources/Models): turns a picture and a description into
/// points in the same 512-number space, so "people around a whiteboard" can find a photo even
/// though no Vision label says that. Runs on this Mac; nothing leaves it.
/// Weights: Apple Machine Learning Research Model License (research / non-commercial only).
enum MobileCLIP {
    static let modelID = "mobileclip-s2"
    static let dimensions = 512

    private final class Models: @unchecked Sendable {
        let image: MLModel
        let text: MLModel
        let tokenizer: CLIPTokenizer
        let constraint: MLImageConstraint
        let imageLock = NSLock()
        let textLock = NSLock()
        init(image: MLModel, text: MLModel, tokenizer: CLIPTokenizer) throws {
            self.image = image; self.text = text; self.tokenizer = tokenizer
            guard let c = image.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
                throw CocoaError(.fileReadCorruptFile)
            }
            constraint = c
        }
    }

    /// The two encoders are downloaded once ("Understands your photos" in Orca's private AI) into
    /// Application Support; the small tokenizer files ship in the app. See PrivateAI.find.
    static var modelsInstalled: Bool {
        PrivateAI.find("mobileclip_s2_image.mlmodelc") != nil && PrivateAI.find("mobileclip_s2_text.mlmodelc") != nil
    }

    private static let loadLock = NSLock()
    nonisolated(unsafe) private static var loaded: Models?
    nonisolated(unsafe) private static var failedAt: Date?

    /// Loaded on first use; tries again after a download (see `reload`).
    private static var models: Models? {
        loadLock.lock(); defer { loadLock.unlock() }
        if let m = loaded { return m }
        if let f = failedAt, Date().timeIntervalSince(f) < 30 { return nil }
        guard let image = PrivateAI.find("mobileclip_s2_image.mlmodelc"), let text = PrivateAI.find("mobileclip_s2_text.mlmodelc"),
              let vocab = PrivateAI.find("clip-vocab.json"), let merges = PrivateAI.find("clip-merges.txt") else { failedAt = Date(); return nil }
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let tok = try CLIPTokenizer(vocabURL: vocab, mergesURL: merges)
            let m = try Models(image: MLModel(contentsOf: image, configuration: cfg), text: MLModel(contentsOf: text, configuration: cfg), tokenizer: tok)
            loaded = m
            return m
        } catch {
            NSLog("OrcaFind: MobileCLIP unavailable: \(error)")
            failedAt = Date()
            return nil
        }
    }

    /// After the model is downloaded or removed.
    static func reload() {
        loadLock.lock(); loaded = nil; failedAt = nil; loadLock.unlock()
    }

    static var isBundled: Bool { modelsInstalled }
    static var isAvailable: Bool { models != nil }

    /// Loads both encoders and runs each once, so the first real search doesn't pay ~0.5 s.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = textVector("a photo") }
    }

    // MARK: Encoding

    /// Unit-length embedding of a picture (center square, as MobileCLIP was trained).
    static func imageVector(_ cg: CGImage) -> [Float]? {
        guard let m = models else { return nil }
        return autoreleasepool {
            guard let fv = try? MLFeatureValue(cgImage: cg, constraint: m.constraint,
                                               options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]) else { return nil }
            m.imageLock.lock(); defer { m.imageLock.unlock() }
            guard let out = try? m.image.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": fv])),
                  let a = out.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
            return normalized(a)
        }
    }

    private static var textCache: [String: [Float]] = [:]
    private static let cacheLock = NSLock()

    /// Unit-length embedding of a description. Cached per phrase; ~3 ms when not.
    static func textVector(_ phrase: String) -> [Float]? {
        let key = phrase.lowercased()
        cacheLock.lock()
        if let hit = textCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        guard let m = models else { return nil }
        let ids = m.tokenizer.encode(key)
        guard let arr = try? MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32) else { return nil }
        let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
        for (i, v) in ids.enumerated() { p[i] = v }
        m.textLock.lock()
        let out = try? m.text.prediction(from: MLDictionaryFeatureProvider(dictionary: ["text": arr]))
        m.textLock.unlock()
        guard let a = out?.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
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
        guard d.count == dimensions * MemoryLayout<Float16>.size else { return nil }
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
        var weight: Float { min(1, max(0, (similarity - 0.17) / 0.17)) }
    }

    /// Pictures that look like the description. Calibrated on MobileCLIP-S2 against a labelled set
    /// on this Mac: real matches scored 0.21–0.34 and stood ≥ 3.9 sd above the rest; things that
    /// weren't there topped out at 0.19, gibberish stayed under 3 sd.
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
    private let dim = MobileCLIP.dimensions
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
        var out: [String: MobileCLIP.Match] = [:]
        for i in 0..<n {
            let s = sims[i]
            guard s >= 0.19 else { continue }
            let z = (s - mean) / sd
            guard z >= 3.5 else { continue }
            let strength: MobileCLIP.Strength = (s >= 0.24 && z >= 4.5) ? .strong : .likely
            out[paths[i]] = MobileCLIP.Match(similarity: s, z: z, strength: strength)
        }
        return out
    }
}
