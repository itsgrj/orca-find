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
    You add topic tags to things a person saved from their screen (posts, products, recipes, articles, designs, videos).
    Reply with JSON only: {"tags": [...]} with one or two tags.
    A tag is a short, general topic in lowercase, one or two words, e.g. design, pricing, recipe, travel, gift idea, to read, how-to, funny, job, fitness, motion, copy, inspiration.
    When a tag from the person's existing list fits, use it exactly. Never use the collection name, the website or app name, or the person's own name.
    If nothing clear fits, reply {"tags": []}.
    """

    static func suggest(note: String, title: String, ocr: String, collection: String?, existing: [String]) async -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SentenceUnderstanding.status == .available else { return [] }
            var prompt = "What they said: \(note.isEmpty ? "(nothing)" : note)\nTitle: \(title)\n"
            if !ocr.isEmpty { prompt += "Text in the picture: \(String(ocr.replacingOccurrences(of: "\n", with: " ").prefix(600)))\n" }
            if let collection { prompt += "Collection (don't use as a tag): \(collection)\n" }
            prompt += "Existing tags: \(existing.prefix(40).joined(separator: ", "))"
            do {
                let session = LanguageModelSession(instructions: instructions)
                let r = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy))
                return parseSuggestion(r.content, collection: collection, existing: existing)
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
        var out: [String] = []
        for raw in list {
            guard let t = normalize(raw), t.split(separator: "-").count <= 2 else { continue }
            if let collection, same(collection, t) { continue }
            let c = canonical(t, existing: existing)
            if !out.contains(where: { same($0, c) }) { out.append(c) }
        }
        return Array(out.prefix(2))
    }
}
