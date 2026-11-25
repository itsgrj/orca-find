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
        "then", "it", "this", "that", "save", "add", "put", "file", "which", "when", "maybe", "is", "was",
        // A correction ends the tag: "clawed, not cloth" is #clawed, never #clawed-not or #not-cloth.
        "not", "no", "never", "isn't", "isn’t", "it's", "it’s", "its", "sorry", "actually", "instead", "except", "mean", "meant",
        "tag", "label", "hashtag", "rather", "hmm"
    ]

    /// "…tag it design and pricing", "hashtag motion", "#onboarding", "tagged as reference".
    static func spoken(in text: String) -> [(tag: String, phrase: String)] {
        var out: [(String, String)] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let patterns = [
            // The verb only: "a tag that says whether…" talks about a tag, it doesn't ask for one.
            #"(?<!\ba\s)(?<!\bthe\s)(?<!\bthis\s)(?<!\bthat\s)(?<!\bone\s)(?<!\bno\s)\b(?:tag|label)\s+(?:it|this|that|them)\s+(?:as\s+|with\s+|under\s+)?((?:(?!\btag\s+it\b)[^.!?\n]){2,60})"#,
            #"\btagged\s+(?:as\s+|with\s+|under\s+)?([^.!?\n]{2,60})"#,
            #"\bhash\s?tags?\s+((?:(?!\bhash\s?tags?\b|\btag\s+it\b)[^.!?\n]){2,60})"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: full) {
                let captured = ns.substring(with: m.range(at: 1))
                let found = items(captured)
                // The phrase ends at the last tag word, so "…and put it in SigmaFlow" stays for the collection.
                var end = m.range.location + m.range.length
                let rest = (captured as NSString)
                if rest.range(of: #"(?i)\b(?:put|save|add|file|keep|move)\s+(?:it|this|that)\b"#, options: .regularExpression).location != NSNotFound,
                   let last = found.last?.split(separator: "-").last,
                   let r = (captured as NSString).range(of: String(last), options: .caseInsensitive) as NSRange?, r.location != NSNotFound {
                    end = m.range(at: 1).location + r.location + r.length
                }
                let phrase = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location)).trimmingCharacters(in: .whitespaces)
                for tag in found where !out.contains(where: { same($0.0, tag) }) {
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
        // People correct themselves out loud, as they would with a person: "not cloth, it's Claude" swaps the tag,
        // and anything said with "not" in front of it is never a tag.
        for (wrong, right) in corrections(in: text) {
            guard let i = out.firstIndex(where: { same($0.0, wrong) }) else { continue }
            if out.contains(where: { same($0.0, right) }) { out.remove(at: i) } else { out[i].0 = right }
        }
        let gone = rejected(in: text)
        out.removeAll { t in gone.contains { same($0, t.0) } }
        // "Tag it pricing. Actually never mind, no tag.": everything asked for before that is off.
        if let re = try? NSRegularExpression(pattern: #"(?i)\b(?:never\s?mind|forget\s+(?:it|that|the\s+tags?)|no\s+tags?|don['’]?t\s+tag\s+it)\b(?!\s+\w)|\bnever\s?mind\b"#),
           let last = re.matches(in: text, range: full).last, let m = Range(last.range, in: text) {
            out.removeAll { t in (text.range(of: t.1, options: .caseInsensitive)?.lowerBound ?? text.endIndex) < m.lowerBound }
        }
        return out
    }

    // MARK: Taking words back

    /// "not only", "not sure" aren't corrections.
    private static let notQualifiers: Set<String> = [
        "only", "just", "sure", "really", "very", "quite", "so", "too", "that", "even", "yet", "necessarily", "exactly",
        "bad", "great", "good", "much", "many", "all", "always", "now", "yet", "really", "working", "done", "for"
    ]

    /// Words said with "not" in front: "…not target claw, not cloth" → ["target-claw", "target", "claw", "cloth"].
    /// These are never tags, whichever way a tag would otherwise have come.
    static func rejected(in text: String) -> [String] {
        let p = #"\b(?:not|don['’]?t\s+tag\s+(?:it|this)|no)\s+(?:tag(?:ged)?\s+(?:it\s+)?)?(?:as\s+|under\s+|with\s+)?(?:a\s+|an\s+|the\s+)?#?([^.!?,;:\n]{2,40})"#
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var words: [String] = []
            for w in ns.substring(with: m.range(at: 1)).split(separator: " ").map(String.init) {
                let lw = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if words.isEmpty && notQualifiers.contains(lw) { break }
                if stopAfter.contains(lw) || words.count == 3 { break }
                words.append(lw)
            }
            guard !words.isEmpty else { continue }
            for t in [words.joined(separator: " ")] + words {
                if let n = normalize(t), !out.contains(n) { out.append(n) }
            }
        }
        return out
    }

    /// (wrong, right) pairs: "not cloth, it's Claude", "it's Claude, not cloth", "cloth — sorry, Claude", "cloth, I mean Claude".
    static func corrections(in text: String) -> [(wrong: String, right: String)] {
        let word = #"([\p{L}\d][\p{L}\d\-]*(?:\s+[\p{L}\d][\p{L}\d\-]*)?)"#
        let its = #"(?:it['’]?s|it\s+is|but|i\s+mean|i\s+meant|i\s+said)"#
        let art = #"(?:a\s+|an\s+|the\s+)?"#
        // Each pattern names which capture group is wrong and which is right.
        let patterns: [(String, Int, Int)] = [
            (#"\bnot\s+"# + art + #"([\p{L}\d][\p{L}\d\-]*)\s*[,.;—–-]?\s*"# + its + #"\s+"# + art + word, 1, 2),
            (#"\b(?:it['’]?s|it\s+is)\s+"# + art + #"([\p{L}\d][\p{L}\d\-]*)\s*,?\s*not\s+"# + art + word, 2, 1),
            (#"\b([\p{L}\d][\p{L}\d\-]*)\s*[,.;—–-]?\s*(?:sorry|i\s+mean|i\s+meant)\s*[,.—–-]?\s*"# + art + word, 1, 2),
            // "Hashtag recipes, no, hashtag desserts"; "tag it travel, or rather tag it vacation"
            (#"\b([\p{L}\d][\p{L}\d\-]*)\s*[,.;—–-]?\s*(?:no|or\s+rather|rather)\s*[,.—–-]?\s*(?:hash\s?tag|tag\s+it(?:\s+as|\s+under)?|make\s+it|label\s+it)\s+"# + art + word, 1, 2),
            (#"\b([\p{L}\d][\p{L}\d\-]*)\s*,?\s*or\s+rather\s+"# + art + word, 1, 2),
            // "Figma. No wait, Paper."
            (#"\b([\p{L}\d][\p{L}\d\-]*)\s*[,.;—–-]?\s*(?:no,?\s+wait|wait,?\s+no|no,?\s+no|scratch\s+that|make\s+that)\s*[,.—–-]?\s*(?:make\s+it\s+|tag\s+it\s+)?"# + art + word, 1, 2)
        ]
        let ns = text as NSString
        var out: [(String, String)] = []
        for (p, w, r) in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let wrong = normalize(ns.substring(with: m.range(at: w))),
                      let right = items(ns.substring(with: m.range(at: r))).first,
                      !same(wrong, right) else { continue }
                out.append((wrong, right))
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
    /// Two-word tags must appear as those two words in order; a tag never comes from words said with "not".
    static func mentioned(in text: String, existing: [String]) -> [String] {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let gone = rejected(in: text)
        return existing.filter { t in
            let parts = t.split(separator: "-").map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ $0.count > 2 && !notTags.contains($0) && !["not", "never"].contains($0) }),
                  !gone.contains(where: { g in same(g, t) || parts.contains { same($0, g) } }) else { return false }
            guard parts.count <= words.count else { return false }
            for i in 0...(words.count - parts.count) where zip(parts, words[i..<(i + parts.count)]).allSatisfy({ same($0, $1) }) {
                return true
            }
            return false
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
                return clean(later(in: note) + r.content.tags, collection: collection, existing: existing, avoid: [site(in: title)].compactMap { $0 } + rejected(in: note))
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
