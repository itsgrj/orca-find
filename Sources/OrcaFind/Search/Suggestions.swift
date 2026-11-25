import Foundation

/// The "Try asking" chips on Home, made from what is actually on this Mac: what's in the pictures, the words
/// inside files, where downloads came from, the camera, recent activity and what was said in captures.
/// Every suggestion is searched before it's shown, so tapping one never ends in "nothing found".
struct Suggestion: Codable, Hashable, Sendable {
    var text: String
    var symbol: String
}

enum Suggestions {
    /// Shown until the first look at the Mac is done (and if it finds too little to say).
    static let general: [Suggestion] = [
        Suggestion(text: "that tiger photo I downloaded", symbol: "photo"),
        Suggestion(text: "photos of receipts", symbol: "sparkles"),
        Suggestion(text: "the PDF with the blue cover", symbol: "doc.richtext"),
        Suggestion(text: "whiteboard photos from last week", symbol: "rectangle.and.pencil.and.ellipsis"),
        Suggestion(text: "screenshots with wifi password", symbol: "text.viewfinder"),
    ]

    /// Everyday things people keep on a Mac and later need to find. A topic is only suggested when files here
    /// actually mention it.
    static let topics: [String] = [
        "invoice", "receipt", "contract", "agreement", "resume", "offer letter", "payslip", "salary", "bank statement",
        "income tax", "gst", "insurance", "passport", "boarding pass", "ticket", "itinerary", "booking", "hotel", "flight",
        "recipe", "menu", "warranty", "prescription", "certificate", "lease", "quotation", "proposal",
        "wifi password", "password", "meeting notes", "agenda", "syllabus", "assignment", "question paper",
        "driving licence", "aadhaar", "electricity bill", "order confirmation", "refund", "subscription", "budget", "timetable",
        "invitation", "wedding", "birthday", "report card", "admission", "interview", "appointment", "roadmap",
        "pricing", "brand guidelines", "wireframe", "portfolio", "loan", "medical report", "rental agreement",
    ]
    // Left out on purpose: words that are the start of many other words ("exam" → example, "visa" → visual,
    // "transcript" → transcription) or too common to mean anything ("order", "statement").

    /// Picture labels that are too everyday or too vague to make a good example.
    private static let dullLabels: Set<String> = VisualAnalyzer.generic.union([
        "suit", "necktie", "eyeglasses", "frame", "window", "lamp", "foliage", "brick", "decorative_plant", "wall",
        "ceiling", "floor", "road", "hand", "face", "cord", "paper", "fabric", "jacket", "shirt", "hat", "blazer",
        "curtain", "cabinet", "door", "headgear", "dial", "housewares", "jeans", "hoodie",
    ])

    private static let cameraBrands: [(needle: String, name: String)] = [
        ("iphone", "iPhone"), ("ipad", "iPad"), ("pixel", "Pixel"), ("samsung", "Samsung"), ("canon", "Canon"),
        ("nikon", "Nikon"), ("sony", "Sony"), ("fujifilm", "Fujifilm"), ("gopro", "GoPro"), ("dji", "DJI"),
        ("leica", "Leica"), ("olympus", "Olympus"), ("panasonic", "Panasonic"),
    ]

    /// Five suggestions, one of each kind where possible, a little different each time.
    static func build(items: [FileItem], stats: HomeStats, seed: UInt64 = .random(in: 0 ... .max)) -> [Suggestion] {
        var rng = SeededRandom(seed: seed)
        let files = items.filter { !$0.isFolder }
        guard files.count >= 20 else { return general }
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        /// Keep a phrase only if searching it really finds something.
        func works(_ text: String, atLeast: Int = 2) -> Bool {
            let q = QueryParser.parse(text)
            if SearchEngine.run(q, in: files, limit: atLeast).count >= atLeast { return true }
            return CaptureSearch.find(q, limit: atLeast).count >= atLeast
        }
        /// Tries the candidates (best first, lightly shuffled) and returns the first that finds something.
        func first(_ candidates: [Suggestion], atLeast: Int = 2, freely: Bool = false) -> Suggestion? {
            let order = freely ? Array(candidates.prefix(6)).shuffled(using: &rng) + candidates.dropFirst(6) : lightlyShuffled(candidates, &rng)
            for s in order where works(s.text, atLeast: atLeast) { return s }
            return nil
        }

        var picks: [Suggestion] = []
        var spare: [Suggestion] = []
        func take(_ group: [Suggestion], atLeast: Int = 2, freely: Bool = false) {
            let group = group.filter { c in !picks.contains { $0.text == c.text } }
            guard let s = first(group, atLeast: atLeast, freely: freely) else { return }
            picks.append(s)
            spare.append(contentsOf: group.filter { $0 != s })
        }

        take(pictureIdeas(), atLeast: 3, freely: true)
        take(topicIdeas(byPath), freely: true)
        take(sourceIdeas(stats, files))
        take(timeIdeas(files), atLeast: 1)
        take(captureIdeas(), atLeast: 1)
        if picks.count < 5 { take(cameraIdeas(files)) }
        // Not enough kinds on this Mac: fill with more of what it does have.
        for s in lightlyShuffled(spare, &rng) where picks.count < 5 {
            if !picks.contains(where: { $0.text == s.text }) && works(s.text) { picks.append(s) }
        }
        for g in general where picks.count < 5 && !picks.contains(where: { $0.text == g.text }) {
            if works(g.text, atLeast: 1) { picks.append(g) }
        }
        return picks.count >= 3 ? picks : general
    }

    // MARK: - Kinds of idea

    /// What shows up most in the pictures here: "photos with a dog".
    static func pictureIdeas() -> [Suggestion] {
        VisualStore.shared.labelCounts(min: 0.5)
            .filter { !dullLabels.contains($0.label) && $0.count >= 3 }
            .prefix(8)
            .map { Suggestion(text: "photos with \(VisualAnalyzer.phrase($0.label))", symbol: "sparkles") }
    }

    /// Everyday topics the files here mention, said the way the files mostly are: "invoice PDFs".
    static func topicIdeas(_ byPath: [String: FileItem]) -> [Suggestion] {
        var found: [(Suggestion, Int)] = []
        for topic in topics {
            let paths = Database.shared.paths(matching: SearchEngine.stem(topic))
            let hits = paths.compactMap { byPath[$0] }
            guard hits.count >= 2 else { continue }
            let shots = hits.filter(\.isScreenshot).count
            let pdfs = hits.filter { $0.ext == "pdf" }.count
            let downloaded = hits.filter { $0.source != nil }.count
            let text: String, symbol: String
            if shots * 2 >= hits.count {
                text = "screenshots with \(topic)"; symbol = "text.viewfinder"
            } else if pdfs * 2 >= hits.count {
                text = downloaded * 2 >= pdfs ? "\(topic) PDFs I downloaded" : "\(topic) PDFs"; symbol = "doc.richtext"
            } else {
                text = "\(topic) documents"; symbol = "doc.text"
            }
            found.append((Suggestion(text: text, symbol: symbol), hits.count))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(10).map(\.0)
    }

    /// The places most downloads came from: "PDFs from Gmail".
    static func sourceIdeas(_ stats: HomeStats, _ files: [FileItem]) -> [Suggestion] {
        let top = stats.sources.filter { $0.count >= 3 && !$0.source.name.isEmpty && $0.source.key != "extensions" }.prefix(6)
        return top.compactMap { s in
            var tally: [String: Int] = [:]
            for f in files where f.source?.key == s.source.key { tally[kindWord(f), default: 0] += 1 }
            // Pictures and documents make better examples than zips and apps.
            let plain = tally.filter { !["zip files", "apps"].contains($0.key) }
            guard let kind = (plain.isEmpty ? tally : plain).max(by: { $0.value < $1.value })?.key else { return nil }
            let from = s.source.isWebsite ? (s.source.host.map(DownloadSource.registrableDomain) ?? s.source.name) : s.source.name
            return Suggestion(text: "\(kind) from \(from)", symbol: "arrow.down.circle")
        }
    }

    /// Recent things: "screenshots from last week".
    static func timeIdeas(_ files: [FileItem]) -> [Suggestion] {
        let week = Date().addingTimeInterval(-7 * 86_400), month = Date().addingTimeInterval(-30 * 86_400)
        var out: [Suggestion] = []
        if files.contains(where: { $0.isScreenshot && $0.activityDate > week }) { out.append(.init(text: "screenshots from last week", symbol: "calendar")) }
        if files.contains(where: { $0.source != nil && $0.ext == "pdf" && $0.activityDate > week }) { out.append(.init(text: "PDFs I downloaded this week", symbol: "calendar")) }
        if files.contains(where: { $0.category == .images && !$0.isScreenshot && $0.activityDate > month }) { out.append(.init(text: "photos from last month", symbol: "calendar")) }
        if files.contains(where: { $0.category == .videos && $0.activityDate > month }) { out.append(.init(text: "videos from last month", symbol: "calendar")) }
        if files.contains(where: { $0.category == .documents && $0.activityDate > week }) { out.append(.init(text: "documents from yesterday", symbol: "calendar")) }
        return out
    }

    /// What the person saved and talked about: "what I saved about pricing".
    static func captureIdeas() -> [Suggestion] {
        let store = CaptureStore.shared
        var names = store.collections().sorted { $0.count > $1.count }.map(\.name)
        var tagCounts: [String: Int] = [:]
        for c in store.all(limit: 400) { for t in c.tagList { tagCounts[t, default: 0] += 1 } }
        names += tagCounts.sorted { $0.value > $1.value }.map { $0.key.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        var seen = Set<String>()
        return names.prefix(8).compactMap { n in
            // "Work | personal branding" → "personal branding": the part after a separator is the topic.
            let part = n.components(separatedBy: CharacterSet(charactersIn: "|/›>:")).last ?? n
            let n = part.trimmingCharacters(in: .whitespaces).lowercased()
            guard n.count >= 3, n.count <= 28, n.contains(where: \.isLetter), seen.insert(n).inserted else { return nil }
            return Suggestion(text: "what I saved about \(n)", symbol: "mic")
        }
    }

    /// The camera most photos here came from: "photos from my Canon".
    static func cameraIdeas(_ files: [FileItem]) -> [Suggestion] {
        var tally: [String: Int] = [:]
        for f in files where !f.isScreenshot {
            guard let cam = f.camera?.lowercased() else { continue }
            if let b = cameraBrands.first(where: { cam.contains($0.needle) }) { tally[b.name, default: 0] += 1 }
        }
        return tally.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.prefix(2)
            .map { Suggestion(text: "photos from my \($0.key)", symbol: "camera") }
    }

    // MARK: - Helpers

    private static func kindWord(_ f: FileItem) -> String {
        if f.isScreenshot { return "screenshots" }
        if f.ext == "pdf" { return "PDFs" }
        switch f.category {
        case .images: return "images"
        case .videos: return "videos"
        case .music: return "songs"
        case .archives: return "zip files"
        case .apps: return "apps"
        default: return "documents"
        }
    }

    /// Mostly keeps the best first, but swaps neighbours now and then so the chips change from day to day.
    private static func lightlyShuffled<T>(_ list: [T], _ rng: inout SeededRandom) -> [T] {
        var out = list
        guard out.count > 1 else { return out }
        for i in 0 ..< out.count - 1 where Bool.random(using: &rng) {
            let j = min(out.count - 1, i + Int.random(in: 1 ... 2, using: &rng))
            out.swapAt(i, j)
        }
        return out
    }
}

/// Small repeatable random numbers, so a set of suggestions can be rebuilt the same way in tests.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    /// SplitMix64: well mixed even from small seeds like 1, 2, 3.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
