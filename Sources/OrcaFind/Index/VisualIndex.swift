import AppKit
import Vision
import PDFKit
import ImageIO

/// What Orca "saw" in a picture or on a PDF's first page: Apple Vision's image labels and the
/// main named colours. Computed on this Mac during indexing and cached in SQLite.
struct VisualInfo: Sendable, Equatable {
    struct Weighted: Sendable, Hashable {
        let name: String
        let value: Float
    }
    var labels: [Weighted] = []    // strongest first
    var colours: [Weighted] = []   // share of the picture, largest first

    func label(_ id: String) -> Float { labels.first { $0.name == id }?.value ?? 0 }
    func colour(_ name: String) -> Float { colours.first { $0.name == name }?.value ?? 0 }

    // Compact text form for SQLite: "tiger:0.960,animal:0.960"
    static func encode(_ list: [Weighted]) -> String {
        list.map { "\($0.name):\(String(format: "%.3f", $0.value))" }.joined(separator: ",")
    }
    static func decode(_ s: String?) -> [Weighted] {
        guard let s, !s.isEmpty else { return [] }
        return s.split(separator: ",").compactMap { part in
            let kv = part.split(separator: ":")
            guard kv.count == 2, let v = Float(kv[1]) else { return nil }
            return Weighted(name: String(kv[0]), value: v)
        }
    }
}

enum VisualAnalyzer {
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]

    /// Every label Apple's built-in classifier knows (1,303 on macOS 26).
    static let vocabulary: Set<String> = {
        Set((try? VNClassifyImageRequest().supportedIdentifiers()) ?? [])
    }()

    /// Labels that describe almost everything ("document", "people", "outdoor"). They never
    /// become a filter on their own and aren't used as the headline reason for a match.
    static let generic: Set<String> = [
        "document", "people", "adult", "structure", "material", "art", "text", "screenshot", "sign",
        "printed_page", "illustrations", "conveyance", "machine", "portal", "wood_processed", "land",
        "liquid", "water_body", "outdoor", "indoor", "decoration", "interior_room", "furniture",
        "clothing", "consumer_electronics", "optical_equipment", "tool", "plant", "container", "textile",
        "animal", "mammal", "vehicle", "sky", "cloudy", "light", "child", "games", "shape"
    ]

    static func wants(_ item: FileItem) -> Bool {
        guard !item.isCloudOnly, !item.isFolder, item.size > 2_000 else { return false }
        if item.ext == "pdf" { return true }
        return item.category == .images && imageExts.contains(item.ext)
    }

    static func analyze(_ item: FileItem) -> VisualInfo? { look(item, labels: true, embed: false)?.info }

    /// One decode of the picture, then whichever passes are needed: Vision labels + colours, and/or
    /// the MobileCLIP embedding (nil when the model isn't available).
    static func look(_ item: FileItem, labels wantLabels: Bool, embed: Bool) -> (info: VisualInfo?, vector: [Float]?)? {
        autoreleasepool {
            guard let cg = item.ext == "pdf" ? pdfCover(item.url) : image(item.url) else { return nil }
            var info: VisualInfo?
            if wantLabels {
                let request = VNClassifyImageRequest()
                try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                let labels = (request.results ?? [])
                    .filter { $0.confidence >= 0.08 }
                    .prefix(14)
                    .map { VisualInfo.Weighted(name: $0.identifier, value: $0.confidence) }
                info = VisualInfo(labels: Array(labels), colours: colours(cg))
            }
            return (info, embed ? MobileCLIP.imageVector(cg) : nil)
        }
    }

    private static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func pdfCover(_ url: URL) -> CGImage? {
        guard let doc = PDFDocument(url: url), !doc.isLocked, let page = doc.page(at: 0) else { return nil }
        let thumb = page.thumbnail(of: NSSize(width: 512, height: 512), for: .mediaBox)
        return thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Share of pixels per named colour, from a 48×48 downsample bucketed by hue/saturation/brightness.
    static func colours(_ cg: CGImage) -> [VisualInfo.Weighted] {
        let n = 48
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))   // transparent PNGs read as white
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var counts: [String: Int] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            counts[colourName(r: px[i], g: px[i + 1], b: px[i + 2]), default: 0] += 1
        }
        let total = Float(n * n)
        return counts.map { VisualInfo.Weighted(name: $0.key, value: Float($0.value) / total) }
            .filter { $0.value >= 0.06 }
            .sorted { $0.value > $1.value }
    }

    static let colourWords = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "brown", "black", "white", "gray"]

    private static func colourName(r: UInt8, g: UInt8, b: UInt8) -> String {
        let c = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let deg = h * 360
        if v < 0.18 { return "black" }
        if s < 0.15 { return v > 0.85 ? "white" : "gray" }
        if deg < 45 && v < 0.55 && s > 0.3 { return "brown" }
        if deg < 15 || deg >= 345 { return "red" }
        if deg < 40 { return "orange" }
        if deg < 65 { return "yellow" }
        if deg < 160 { return "green" }
        if deg < 195 { return "teal" }
        if deg < 255 { return "blue" }
        if deg < 290 { return "purple" }
        return "pink"
    }

    // MARK: - Words

    /// "sunset_sunrise" → "sunset or sunrise", "blue_sky" → "blue sky"
    static func display(_ id: String) -> String {
        id == "sunset_sunrise" ? "sunset" : id.replacingOccurrences(of: "_", with: " ")
    }

    private static let massNouns: Set<String> = ["people", "food", "snow", "water", "sky", "blue_sky", "night_sky", "handwriting",
                                                 "grass", "sand", "fire", "smoke", "rain", "money", "jewelry", "furniture", "seaside", "scenery", "nature"]

    /// "a tiger", "an orange", "handwriting"
    static func phrase(_ id: String) -> String {
        let d = display(id)
        if massNouns.contains(id) || d.hasSuffix("s") { return d }
        return ("aeiou".contains(d.first ?? "x") ? "an " : "a ") + d
    }

    /// Everyday words → labels the classifier uses for them. Lets short queries like
    /// "seaside photos" work without any language model.
    static let aliases: [String: [String]] = [
        "seaside": ["beach", "ocean", "shore"], "sea": ["ocean", "beach", "shore"], "beach": ["beach", "shore", "ocean"],
        "ocean": ["ocean", "beach"], "lake": ["lake"], "river": ["river"],
        "bill": ["receipt"], "receipt": ["receipt"],
        "handwritten": ["handwriting"], "handwriting": ["handwriting"],
        "car": ["car", "automobile"], "dog": ["dog", "puppy"], "puppy": ["puppy", "dog"], "cat": ["cat", "kitten"], "kitten": ["kitten", "cat"],
        "sunset": ["sunset_sunrise"], "sunrise": ["sunset_sunrise"], "graph": ["chart", "diagram"],
        "mountain": ["mountain"], "hill": ["hill", "mountain"], "laptop": ["laptop", "computer"],
        "selfie": ["people"], "flower": ["flower"], "flowers": ["flower"], "tree": ["tree"],
        "whiteboard": ["whiteboard"], "chart": ["chart"], "diagram": ["diagram"], "passport": ["passport"],
        "cake": ["cake"], "pizza": ["pizza"], "food": ["food"], "baby": ["baby"], "snow": ["snow"], "night": ["night_sky"]
    ]
}

/// In-memory view of the visual cache, read by search from any thread.
final class VisualStore: @unchecked Sendable {
    static let shared = VisualStore()
    private var map: [String: VisualInfo] = [:]
    private let lock = NSLock()

    func replaceAll(_ new: [String: VisualInfo]) { lock.lock(); map = new; lock.unlock() }
    func set(_ path: String, _ info: VisualInfo) { lock.lock(); map[path] = info; lock.unlock() }
    func get(_ path: String) -> VisualInfo? { lock.lock(); defer { lock.unlock() }; return map[path] }
    func remove(_ paths: [String]) { lock.lock(); for p in paths { map[p] = nil }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }

    /// How many pictures show any of these labels at least this strongly.
    func count(labels: [String], min: Float) -> Int {
        lock.lock(); defer { lock.unlock() }
        return map.values.reduce(0) { n, v in n + (labels.contains { v.label($0) >= min } ? 1 : 0) }
    }

    /// Labels that tend to appear in the same pictures as these ones ("tiger" → feline, animal):
    /// used for "similar things" suggestions and close matches. Learned from this Mac's photos.
    func related(to labels: [String], limit: Int = 4) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var counts: [String: Int] = [:]
        let own = Set(labels)
        for v in map.values where labels.contains(where: { v.label($0) >= 0.4 }) {
            for w in v.labels where w.value >= 0.3 && !own.contains(w.name) { counts[w.name, default: 0] += 1 }
        }
        let skip: Set<String> = ["outdoor", "indoor", "structure", "material", "text", "document", "screenshot", "printed_page", "sky", "light"]
        return counts.filter { !skip.contains($0.key) }.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
}
