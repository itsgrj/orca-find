import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import OrcaFind

/// SigLIP 2's tokenizer, token for token against Google's (ids generated with Hugging Face `tokenizers`).
/// `ORCA_SIGLIP_DIR=<folder with siglip2-vocab.json, siglip2-merges.txt, tokcheck.json> swift test --filter SigLIPTokenizerTests`
@Suite("Pictures: SigLIP tokenizer", .enabled(if: ProcessInfo.processInfo.environment["ORCA_SIGLIP_DIR"] != nil))
struct SigLIPTokenizerTests {
    struct Check: Decodable { let text: String; let ids: [Int32] }

    @Test func matchesGooglesTokenizer() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORCA_SIGLIP_DIR"]!)
        let tok = try SigLIPTokenizer(vocabURL: dir.appendingPathComponent("siglip2-vocab.json"),
                                      mergesURL: dir.appendingPathComponent("siglip2-merges.txt"))
        let checks = try JSONDecoder().decode([Check].self, from: Data(contentsOf: dir.appendingPathComponent("tokcheck.json")))
        var wrong = 0
        for c in checks {
            let got = tok.pieces(c.text) + [SigLIPTokenizer.eos]
            if got != c.ids { wrong += 1; print("MISMATCH \(c.text): \(got) want \(c.ids)") }
        }
        print("TOKENIZER \(checks.count - wrong)/\(checks.count) identical")
        #expect(wrong == 0)
        #expect(tok.encode("a photo of a dog").count == 64)
    }
}

/// Both picture models on 600 labelled photos (Imagenette), through the app's own encoding and matching.
/// `ORCA_IMAGENETTE=<imagenette2-160/val> [ORCA_MODELS_DIR=<siglip folder> | ORCA_PICTURE_MODEL=mobileclip] swift test --filter PictureModelEval`
@Suite("Pictures: model eval", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORCA_IMAGENETTE"] != nil))
struct PictureModelEval {
    static let classes: [(String, String)] = [
        ("n01440764", "tench"), ("n02102040", "english springer spaniel"), ("n02979186", "cassette player"), ("n03000684", "chainsaw"),
        ("n03028079", "church"), ("n03394916", "french horn"), ("n03417042", "garbage truck"), ("n03425413", "gas pump"),
        ("n03445777", "golf ball"), ("n03888257", "parachute")]
    static let absent = ["giraffe", "whiteboard", "birthday cake", "laptop", "beach", "pizza", "bicycle", "cat", "snow", "guitar"]

    func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    @Test func compare() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORCA_IMAGENETTE"]!)
        #expect(MobileCLIP.isAvailable)
        print("MODEL \(MobileCLIP.modelID)")
        var vectors: [(path: String, label: String, v: [Float])] = []
        let start = Date()
        for (dir, label) in Self.classes {
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path).sorted().prefix(60)
            for f in files {
                let u = root.appendingPathComponent(dir).appendingPathComponent(f)
                if let cg = load(u), let v = MobileCLIP.imageVector(cg) { vectors.append((u.path, label, v)) }
            }
        }
        let perPicture = Date().timeIntervalSince(start) / Double(max(vectors.count, 1)) * 1000
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        let labels = Self.classes.map(\.1)
        let tvs = labels.map { MobileCLIP.textVector(MobileCLIP.prompt($0))! }
        var right = 0
        for x in vectors {
            let best = tvs.indices.max { dot(x.v, tvs[$0]) < dot(x.v, tvs[$1]) }!
            if labels[best] == x.label { right += 1 }
        }
        print(String(format: "ACCURACY %.3f (%d pictures, %.0f ms each)", Double(right) / Double(vectors.count), vectors.count, perPicture))

        // Like a real library: each kind is 1% of the pictures (6 among 540 others), searched with the app's rule.
        let sweep: [MobileCLIP.Calibration] = ProcessInfo.processInfo.environment["ORCA_SWEEP"] == nil ? [MobileCLIP.calibration] :
            [0.085, 0.09, 0.095, 0.10, 0.105].flatMap { s in [1.5, 2.0, 2.5, 3.0].map { z in
                MobileCLIP.Calibration(minSimilarity: Float(s), minZ: Float(z), strongSimilarity: 0.13, strongZ: 3.0, weightFloor: 0.09, weightSpan: 0.08) } }
        for cal in sweep {
        if MobileCLIP.backend == .siglip { MobileCLIP.siglipCalibration = cal }
        var tp = 0, fp = 0, fn = 0, strong = 0, absentHits = 0
        for (i, label) in labels.enumerated() {
            let mine = vectors.filter { $0.label == label }.prefix(6)
            let others = vectors.filter { $0.label != label }
            let store = EmbeddingStore()
            var all: [String: [Float]] = [:]
            for x in mine { all[x.path] = x.v }
            for x in others { all[x.path] = x.v }
            store.replaceAll(all)
            let found = store.matches(tvs[i])
            let truth = Set(mine.map(\.path))
            tp += found.keys.filter { truth.contains($0) }.count
            fp += found.keys.filter { !truth.contains($0) }.count
            fn += truth.subtracting(found.keys).count
            strong += found.filter { truth.contains($0.key) && $0.value.strength == .strong }.count
            if i < Self.absent.count {
                let q = MobileCLIP.textVector(MobileCLIP.prompt(Self.absent[i]))!
                absentHits += store.matches(q).count
            }
        }
        print("CAL sim>=\(cal.minSimilarity) z>=\(cal.minZ)")
        print("LIBRARY precision \(String(format: "%.3f", Double(tp) / Double(max(tp + fp, 1)))) recall \(String(format: "%.3f", Double(tp) / Double(max(tp + fn, 1)))) strong \(strong)/\(tp) | searches for things not there: \(absentHits) false hits")

        }
        // Similarity spread, for setting thresholds.
        var real: [Float] = [], other: [Float] = [], gone: [Float] = []
        for (i, label) in labels.enumerated() {
            for x in vectors { (x.label == label ? { real.append(dot(x.v, tvs[i])) } : { other.append(dot(x.v, tvs[i])) })() }
        }
        for a in Self.absent { let q = MobileCLIP.textVector(MobileCLIP.prompt(a))!; for x in vectors { gone.append(dot(x.v, q)) } }
        func pct(_ a: [Float], _ p: Double) -> Float { let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
        print(String(format: "SPREAD real p05 %.3f p10 %.3f median %.3f | other p99 %.3f p99.9 %.3f max %.3f | absent p99.9 %.3f max %.3f",
                     pct(real, 0.05), pct(real, 0.10), pct(real, 0.5), pct(other, 0.99), pct(other, 0.999), other.max()!, pct(gone, 0.999), gone.max()!))
    }
}

/// Could the picture alone suggest the person's own tags? Checked on the real captures.
/// `ORCA_PICTURE_TAGS=1 ORCA_MODELS_DIR=<siglip folder> swift test --filter PictureTagCheck`
@Suite("Pictures: tags from the picture", .enabled(if: ProcessInfo.processInfo.environment["ORCA_PICTURE_TAGS"] != nil))
struct PictureTagCheck {
    @Test @MainActor func ownTagsFromPictures() {
        CaptureLibrary.shared.reload()
        let lib = CaptureLibrary.shared
        let tags = lib.tags.filter { $0.count >= 2 }.map(\.name)
        let tvs = tags.map { MobileCLIP.textVector(MobileCLIP.prompt($0.replacingOccurrences(of: "-", with: " "))) }
        var right = 0, wrong = 0, none = 0
        for c in lib.items where !c.tagList.isEmpty {
            guard let img = CaptureThumbs.image(c.id, maxPixel: 800)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let v = MobileCLIP.imageVector(img) else { continue }
            let scored = tags.indices.compactMap { i -> (String, Float)? in
                guard let t = tvs[i] else { return nil }
                return (tags[i], zip(v, t).reduce(0) { $0 + $1.0 * $1.1 })
            }.sorted { $0.1 > $1.1 }
            // SigLIP's own probability: sigmoid(112.9 s − 16.8)
            let best = scored.first.map { ($0.0, 1 / (1 + exp(-(112.9 * $0.1 - 16.8)))) }
            guard let (tag, p) = best, p >= 0.1 else { none += 1; continue }
            if c.tagList.contains(where: { CaptureTags.same($0, tag) }) { right += 1 } else { wrong += 1 }
            print("PIC \(c.tagList) → \(tag) p=\(String(format: "%.2f", p))")
        }
        print("PICTURE TAGS right \(right) wrong \(wrong) no suggestion \(none)")
    }
}

/// Similarities for a few pictures and phrases (`ORCA_PROBE_FILES=a.png:b.jpg ORCA_PROBE_TEXT="x|y"`).
@Suite("Pictures: probe", .enabled(if: ProcessInfo.processInfo.environment["ORCA_PROBE_FILES"] != nil))
struct PictureProbe {
    @Test func probe() {
        let env = ProcessInfo.processInfo.environment
        let t0 = Date(); _ = MobileCLIP.textVector("warm up"); print("PROBE load+first text \(Int(Date().timeIntervalSince(t0) * 1000)) ms, model \(MobileCLIP.modelID)")
        for p in ["a photo of purple gradient", "a photo of people around a whiteboard", "a photo of a cat", "purple", "gradient"] {
            let t = Date(); _ = MobileCLIP.textVector(p); print("PROBE text \(p): \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        }
        let t = Date(); _ = MobileCLIP.matches(for: "purple gradient"); print("PROBE matches: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        for f in env["ORCA_PROBE_FILES"]!.split(separator: ":") {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: String(f)) as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), let v = MobileCLIP.imageVector(cg) else { continue }
            for t in env["ORCA_PROBE_TEXT"]!.split(separator: "|") {
                for phrase in [MobileCLIP.prompt(String(t)), String(t), "an image of " + t] {
                    let q = MobileCLIP.textVector(phrase)!
                    print(String(format: "PROBE %@ | %@ → %.3f", (String(f) as NSString).lastPathComponent, phrase, zip(v, q).reduce(0) { $0 + $1.0 * $1.1 }))
                }
            }
        }
    }
}
