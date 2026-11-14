import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tags say what a capture is about, across collections (#design in SigmaFlow, Newsletter and Wedding).
/// They come from what was said ("tag it design", "hashtag pricing"), from Apple Intelligence reading the
/// words and the picture, or by hand. Existing tags are always reused so #design never splits into #designs.
enum CaptureTags {

    // MARK: Spelling

    private static let notTags: Set<String> = [
        "it", "this", "that", "them", "me", "us", "you", "a", "an", "the", "is", "was", "in", "on", "at", "to", "for",
        "and", "or", "as", "with", "under", "please", "too", "also", "now", "later", "here", "there", "so", "one"
    ]

    /// "#Landing Page!" → "landing-page". nil for words that can't be a tag.
    static func normalize(_ raw: String) -> String? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces).subtracting(CharacterSet(charactersIn: "-")))
        t = t.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        while t.contains("--") { t = t.replacingOccurrences(of: "--", with: "-") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard t.count >= 2, t.count <= 24, !notTags.contains(t), t.contains(where: { $0.isLetter }) else { return nil }
        return t
    }

    /// Case, spaces, hyphens and simple plurals don't matter: "Designs" = "design", "landing page" = "landing-page".
    static func same(_ a: String, _ b: String) -> Bool { SpokenIntent.same(a, b) }

    /// Reuse the spelling already in the library when there is one.
    static func canonical(_ t: String, existing: [String]) -> String {
        existing.first { same($0, t) } ?? t
    }

    /// Like `canonical`, and a one-word suggestion also picks up an existing two-word tag led by that word
    /// ("gift" → "gift-idea", "read" → "to-read"), but not one where it's the second word ("design" ≠ "product-design").
    static func reuse(_ t: String, existing: [String]) -> String {
        if let e = existing.first(where: { same($0, t) }) { return e }
        guard !t.contains("-") else { return t }
        return existing.first { e in
            let parts = e.split(separator: "-").map(String.init)
            guard parts.count == 2 else { return false }
            return same(parts[0] == "to" ? parts[1] : parts[0], t)
        } ?? t
    }

    // MARK: From what was said

    private static let stopAfter: Set<String> = [
        "and", "but", "so", "because", "for", "to", "remind", "the", "in", "on", "at", "please", "also", "too",
        "then", "it", "this", "that", "save", "add", "put", "file", "which", "when", "maybe", "is", "was"
    ]

    /// "…tag it design and pricing", "hashtag motion", "#onboarding", "tagged as reference".
    static func spoken(in text: String) -> [(tag: String, phrase: String)] {
        var out: [(String, String)] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let patterns = [
            #"\b(?:tag|label)\s+(?:it|this|that|them)\s+(?:as\s+|with\s+|under\s+)?([^.!?\n]{2,60})"#,
            #"\btagged\s+(?:as\s+|with\s+|under\s+)?([^.!?\n]{2,60})"#,
            #"\bhash\s?tags?\s+([^.!?\n]{2,60})"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: full) {
                let phrase = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                for tag in items(ns.substring(with: m.range(at: 1))) where !out.contains(where: { same($0.0, tag) }) {
                    out.append((tag, phrase))
                }
            }
        }
        // Typed or transcribed hashtags: "#design"
        if let re = try? NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\d][\p{L}\d\-]{1,23})"#) {
            for m in re.matches(in: text, range: full) {
                if let t = normalize(ns.substring(with: m.range(at: 1))), !out.contains(where: { same($0.0, t) }) {
                    out.append((t, "#" + t))
                }
            }
        }
        return out
    }

    /// "design and pricing, motion" → ["design", "pricing", "motion"]; each item keeps at most two words.
    private static func items(_ raw0: String) -> [String] {
        // "to read", "to watch" are tags people use; keep them together.
        let raw = raw0.replacingOccurrences(of: #"\bto\s+(read|watch|buy|try|do|cook|visit|listen)\b"#, with: "to-$1",
                                            options: [.regularExpression, .caseInsensitive])
        var out: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty, let t = normalize(current.joined(separator: " ")) { out.append(t) }
            current = []
        }
        for chunk in raw.components(separatedBy: ",") {
            for w in chunk.split(separator: " ").map(String.init) {
                let lw = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if lw == "and" || lw == "&" { flush(); continue }
                if stopAfter.contains(lw) { flush(); return out }
                if current.count == 2 { flush(); return out }
                current.append(w)
            }
            flush()
            if out.count >= 4 { break }
        }
        return Array(out.prefix(4))
    }

    /// Tags the person already uses that appear as words in the note ("…the design is…" with #design).
    static func mentioned(in text: String, existing: [String]) -> [String] {
        let words = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        return existing.filter { t in
            let parts = t.split(separator: "-").map(String.init)
            return parts.allSatisfy { p in words.contains(where: { same($0, p) }) }
        }
    }

    // MARK: Apple Intelligence

    private static let instructions = """
    You add topic tags to things a person saved from their screen: posts, products, recipes, articles, designs, videos. \
    First say what the saved thing is about, then tag it. Fewer tags are better than a wrong one.
    """

    static func suggest(note: String, title: String, ocr: String, collection: String?, existing: [String]) async -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SentenceUnderstanding.status == .available else { return [] }
            var prompt = "What they said: \(note.isEmpty ? "(nothing)" : note)\nTitle: \(title)\n"
            if !ocr.isEmpty { prompt += "Text in the picture: \(String(ocr.replacingOccurrences(of: "\n", with: " ").prefix(600)))\n" }
            if let collection { prompt += "Collection (never a tag): \(collection)\n" }
            // The person's existing tags are matched afterwards (`clean`); shown to the model, they get copied onto everything.
            do {
                let session = LanguageModelSession(instructions: instructions)
                // Filled straight into `TagReading`, so the answer always has the right shape and can't ramble.
                let r = try await session.respond(to: prompt, generating: TagReading.self,
                                                  options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120))
                return clean(later(in: note) + r.content.tags, collection: collection, existing: existing, avoid: [site(in: title)].compactMap { $0 })
            } catch {
                return []
            }
        }
        #endif
        return []
    }

    static func parseSuggestion(_ raw: String, collection: String?, existing: [String]) -> [String] {
        var s = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") { s = String(s[a...b]) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let list = obj["tags"] as? [String] else { return [] }
        return clean(list, collection: collection, existing: existing)
    }

    /// "read this later", "watch it tonight", "want to try this" → "to-read", "to-watch", "to-try".
    /// A rule rather than the model: told about it, the model put "to try" on every recipe.
    static func later(in note: String) -> [String] {
        let verbs = ["read": "to-read", "watch": "to-watch", "listen": "to-listen", "buy": "to-buy", "try": "to-try", "cook": "to-cook", "visit": "to-visit"]
        let p = #"\b(read|watch|listen(?:\s+to)?|buy|try|cook|visit)\b(?:\s+(?:it|this|that|them|these))?\s+(?:later|tonight|this\s+weekend|someday|some\s?time|when\s+i\s+(?:can|get\s+a\s+chance))\b|\b(?:want|wanna|need|have|got)\s+to\s+(read|watch|buy|try|cook|visit)\b|\bto\s+(read|watch|buy|try|cook|visit)\s+list\b"#
        guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { return [] }
        let ns = note as NSString
        var out: [String] = []
        for m in re.matches(in: note, range: NSRange(location: 0, length: ns.length)) {
            for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound {
                let verb = ns.substring(with: m.range(at: g)).lowercased().split(separator: " ").first.map(String.init) ?? ""
                if let tag = verbs[verb], !out.contains(tag) { out.append(tag) }
            }
        }
        return out
    }

    /// "Pricing – Linear" → "Linear": the site or app name that ends many page titles.
    static func site(in title: String) -> String? {
        for sep in [" – ", " — ", " | ", " - ", " · "] {
            guard let r = title.range(of: sep, options: .backwards) else { continue }
            let tail = title[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, tail.split(separator: " ").count <= 3 { return tail }
        }
        return nil
    }

    /// What a capture is, not what it's about.
    private static let fileKinds: Set<String> = [
        "screenshot", "screenshots", "screen", "photo", "photos", "image", "images", "picture", "pictures", "video", "videos",
        "file", "files", "pdf", "document", "page", "webpage", "website", "post", "capture", "clip", "screen-recording"
    ]

    /// Spell like the library, never the collection's name, one or two words, at most two tags.
    static func clean(_ list: [String], collection: String?, existing: [String], avoid: [String] = []) -> [String] {
        var out: [String] = []
        for raw in list {
            guard let t = normalize(raw), t.split(separator: "-").count <= 2, !fileKinds.contains(t) else { continue }
            if let collection, same(collection, t) { continue }
            if avoid.contains(where: { a in normalize(a).map { same($0, t) } ?? false }) { continue }
            let c = reuse(t, existing: existing)
            if !out.contains(where: { same($0, c) }) { out.append(c) }
        }
        return Array(out.prefix(2))
    }
}

#if canImport(FoundationModels)
/// What Apple Intelligence fills in for a capture. Fields are generated in this order, so the tags follow from `about`.
@available(macOS 26.0, *)
@Generable(description: "Topic tags for something a person saved")
struct TagReading {
    @Guide(description: "What kind of thing it is and what it's about, in two to six plain words, e.g. \"a pasta recipe\", \"a sofa to buy\", \"an app's pricing page\", \"a joke about coding\".")
    var about: String

    @Guide(description: """
    Zero, one or two short general topics in lowercase, one or two words each, that describe what it is about: \
    e.g. design, pricing, recipe, travel, gift idea, how-to, job, fitness, motion, furniture. \
    A joke or meme is "funny". Never split one phrase into two tags ("terms of service" is "legal", not "terms" and "service"). \
    Never the collection, a website, app or brand name, the person's name, or the kind of file (screenshot, photo, video). \
    Empty when nothing clear fits.
    """, .maximumCount(2))
    var tags: [String]
}
#endif
