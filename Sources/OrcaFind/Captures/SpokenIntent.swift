import Foundation

/// What Orca files from the words alone: "…for Friday's newsletter. Remind me Thursday to write it up."
/// No pickers — the collection and the Apple Reminder come from the sentence.
struct SpokenIntent: Equatable {
    var collection: String?
    var collectionPhrase: String?
    var reminderDate: Date?
    var reminderPhrase: String?
    /// What to do, e.g. "Write it up".
    var reminderTask: String?
    /// "tag it design and pricing" → ["design", "pricing"], with the words that set each one.
    var tags: [String] = []
    var tagPhrases: [String: String] = [:]

    static func parse(_ raw: String, existing: [String], existingTags: [String] = [], now: Date = Date()) -> SpokenIntent {
        var out = SpokenIntent()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return out }
        parseReminder(text, now: now, into: &out)
        var rest = text
        for (tag, phrase) in CaptureTags.spoken(in: text) {
            let t = CaptureTags.canonical(tag, existing: existingTags)
            out.tags.append(t)
            out.tagPhrases[t] = phrase
            // "tag it design" must not also file it into a collection called Design.
            rest = rest.replacingOccurrences(of: phrase, with: " ")
        }
        parseCollection(rest, existing: existing, into: &out)
        return out
    }

    // MARK: Reminders

    private static func parseReminder(_ text: String, now: Date, into out: inout SpokenIntent) {
        guard let r = text.range(of: #"\bremind (me|us)\b"#, options: [.regularExpression, .caseInsensitive]) else { return }
        // The rest of that sentence: "Thursday to write it up"
        var tail = String(text[r.upperBound...])
        if let end = tail.firstIndex(where: { ".!?\n".contains($0) }) { tail = String(tail[..<end]) }
        tail = tail.trimmingCharacters(in: .whitespaces)

        var due: Date?
        var dateText = ""
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = detector.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)), let d = m.date,
           let range = Range(m.range, in: tail) {
            dateText = String(tail[range])
            due = d
            if !mentionsTime(dateText) {
                due = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: d)
            }
            if let d = due, d < now { due = Calendar.current.date(byAdding: .day, value: 7, to: d) }
        }
        if due == nil {
            // "remind me later" / "remind me to …" with no day: tomorrow morning.
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!
            due = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
        out.reminderDate = due
        let spoken = String(text[r]).lowercased()
        out.reminderPhrase = dateText.isEmpty ? spoken : "\(spoken) \(dateText)"

        // The task: "to write it up" → "Write it up"
        var task = tail
        if !dateText.isEmpty { task = task.replacingOccurrences(of: dateText, with: " ") }
        task = task.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if let to = task.range(of: #"^(?:(?:on|at|in|this|next)\s+)?(?:to|about)\s+"#, options: [.regularExpression, .caseInsensitive]) {
            task = String(task[to.upperBound...])
        } else if let to = task.range(of: #"\bto\s+"#, options: [.regularExpression, .caseInsensitive]) {
            task = String(task[to.upperBound...])
        } else {
            task = ""
        }
        task = task.trimmingCharacters(in: .whitespaces)
        if !task.isEmpty { out.reminderTask = task.prefix(1).uppercased() + task.dropFirst() }
    }

    private static func mentionsTime(_ s: String) -> Bool {
        s.range(of: #"\d:\d|\d\s*(am|pm|a\.m|p\.m)|\bat\s+\d|\b(noon|midnight|morning|afternoon|evening|tonight|night|o'clock)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Collections

    private static let notCollections: Set<String> = [
        "it", "this", "that", "me", "you", "him", "her", "them", "us", "now", "later", "today", "tomorrow", "tonight",
        "a", "an", "the", "sure", "example", "instance", "real", "free", "fun", "good", "ever", "sale", "all", "one",
        "some", "a while", "a bit", "reference", "inspiration", "later on", "once", "years", "days", "weeks", "months"
    ]

    private static let stopAfter: Set<String> = [
        "and", "but", "so", "because", "to", "with", "on", "at", "in", "from", "by", "when", "if", "that", "which",
        "remind", "the", "is", "was", "next", "this", "later", "tomorrow", "today", "too", "please", "maybe", "later"
    ]

    private static func parseCollection(_ text: String, existing: [String], into out: inout SpokenIntent) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 1. Explicit: "add it to the summer trip", "save this in recipes", "put it under work"
        let explicit = #"\b(?:add|save|put|file|keep|throw)\s+(?:it|this|that)\s+(?:to|in|into|under|with)\s+(?:the\s+|my\s+|our\s+)?([\p{L}\d][\p{L}\d'’\- ]{0,40})"#
        if let m = try? NSRegularExpression(pattern: explicit, options: [.caseInsensitive]).firstMatch(in: text, range: full),
           let name = clean(ns.substring(with: m.range(at: 1)), existing: existing, requireExisting: false) {
            out.collection = name
            out.collectionPhrase = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            return
        }

        // 2. "for the newsletter", "for Friday's newsletter", "for my Norway trip"
        let forPattern = #"\bfor\s+((?:the|my|our)\s+|[\p{L}]+['’]s\s+)?([\p{L}\d][\p{L}\d'’\- ]{0,40})"#
        guard let re = try? NSRegularExpression(pattern: forPattern, options: [.caseInsensitive]) else { return }
        for m in re.matches(in: text, range: full) {
            let hasDeterminer = m.range(at: 1).location != NSNotFound
            let candidate = ns.substring(with: m.range(at: 2))
            // Without "the/my/X's" only an existing collection counts ("good for you" isn't a collection).
            if let name = clean(candidate, existing: existing, requireExisting: !hasDeterminer) {
                out.collection = name
                out.collectionPhrase = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: CharacterSet(charactersIn: ".,!?")).first
                return
            }
        }

        // 3. Just naming a collection you already have: "…in the sigma flow website…" → SigmaFlow.
        if let (name, phrase) = mentionedCollection(in: text, existing: existing) {
            out.collection = name
            out.collectionPhrase = phrase
        }
    }

    /// Finds an existing collection named anywhere in the text, ignoring case, spaces and hyphens
    /// ("sigma flow" = "SigmaFlow" = "Sigma-Flow"). Longest name wins.
    static func mentionedCollection(in text: String, existing: [String]) -> (String, String)? {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        var best: (name: String, phrase: String, len: Int)?
        for name in existing {
            let key = squash(name)
            guard key.count >= 3 else { continue }
            let span = max(1, name.split(whereSeparator: { $0 == " " || $0 == "-" }).count)
            // Try word runs up to one longer than the name's own word count ("sigma flow" for "SigmaFlow").
            for n in 1...min(span + 2, words.count) {
                for i in 0...(words.count - n) {
                    let run = words[i..<(i + n)]
                    if same(run.joined(), key), best.map({ key.count > $0.len }) ?? true {
                        best = (name, run.joined(separator: " "), key.count)
                    }
                }
            }
        }
        return best.map { ($0.name, $0.phrase) }
    }

    private static func squash(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Keeps the first one or two meaningful words; matches an existing collection when it can.
    private static func clean(_ raw: String, existing: [String], requireExisting: Bool) -> String? {
        var words: [String] = []
        for w in raw.components(separatedBy: CharacterSet(charactersIn: " ,.;:!?\n")) where !w.isEmpty {
            let lw = w.lowercased()
            if stopAfter.contains(lw) || words.count == 2 { break }
            if ["collection", "folder", "list", "board", "pile"].contains(lw) { break }
            words.append(w)
        }
        guard !words.isEmpty else { return nil }

        // Prefer an existing collection: the full phrase, then each word, singular/plural tolerant.
        let phrase = words.joined(separator: " ")
        for candidate in [phrase, words.last!, words.first!] {
            if let hit = existing.first(where: { same($0, candidate) }) { return hit }
        }
        if requireExisting { return nil }
        // New collection: "Friday's newsletter" was already split off; keep up to two words.
        if notCollections.contains(phrase.lowercased()) || phrase.count < 3 { return nil }
        if words.count == 2, notCollections.contains(words[1].lowercased()) { return nil }
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = squash(s)
            if t.hasSuffix("es") && t.count > 4 { t.removeLast(2) } else if t.hasSuffix("s") && t.count > 3 { t.removeLast() }
            return t
        }
        return norm(a) == norm(b)
    }
}
