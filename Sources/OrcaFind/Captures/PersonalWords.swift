import Foundation

/// The words this person uses that speech recognition doesn't know: their tags, their collections, the apps on
/// their Mac, and names they've corrected out loud ("not cloth, it's Claude"). The speech model listens for them,
/// and a note that says "clawed" where they meant "Claude" gets the right word back.
enum PersonalWords {

    // MARK: The list

    /// Everything, best first, without repeats (case, spaces and hyphens ignored). Capped so listening stays fast.
    @MainActor
    static func all(limit: Int = 150) -> [String] {
        let lib = CaptureLibrary.shared
        // A tag counts once it's on two captures or was added by hand: a misheard tag used once ("clawed")
        // mustn't become a word that blocks its own correction.
        let byHand = Set(lib.items.flatMap { c in c.tagList.filter { c.tagOrigins?[$0] == "you" } })
        let tags = lib.tags.filter { $0.count >= 2 || byHand.contains($0.name) }
            .map { $0.name.replacingOccurrences(of: "-", with: " ") }
        let collections = lib.collections.map(\.name)
        return merge([learned(), collections, tags, appNames(), ["OrcaFind"]], limit: limit)
    }

    static func merge(_ lists: [[String]], limit: Int) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for list in lists {
            for w in list {
                let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
                let k = squash(t)
                guard k.count >= 2, t.count <= 32, !seen.contains(k) else { continue }
                seen.insert(k)
                out.append(t)
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// Names of the apps people install (not Apple's own), because people talk about them: "save this for Figma".
    static func appNames() -> [String] {
        cachedApps.withLock { cache in
            if let c = cache, Date().timeIntervalSince(c.at) < 3600 { return c.names }
            let fm = FileManager.default
            let dirs = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            var names: [String] = []
            for d in dirs {
                for name in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where name.hasSuffix(".app") {
                    var n = String(name.dropLast(4))
                    // "T3 Code (Beta)" → "T3 Code"
                    if let r = n.range(of: #"\s*\(.*\)$"#, options: .regularExpression) { n.removeSubrange(r) }
                    if n.split(separator: " ").count <= 3 { names.append(n) }
                }
            }
            names.sort()
            cache = (Date(), names)
            return names
        }
    }
    private static let cachedApps = Locked<(at: Date, names: [String])?>(nil)

    // MARK: Learned

    private static let learnedKey = "personalWords.learned"

    static func learned() -> [String] { UserDefaults.standard.stringArray(forKey: learnedKey) ?? [] }

    /// Remembers a name the person corrected out loud, newest first.
    static func learn(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard w.count >= 3, w.count <= 32, w.split(separator: " ").count <= 3, w.contains(where: \.isLetter) else { return }
        var list = learned().filter { squash($0) != squash(w) }
        list.insert(w, at: 0)
        UserDefaults.standard.set(Array(list.prefix(100)), forKey: learnedKey)
    }

    // MARK: Sounding alike

    /// "Sigma-Flow" → "sigmaflow".
    static func squash(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A rough sound key: consonants in order, vowels dropped, letters that sound alike merged.
    /// "clawed", "clod" and "Claude" are all "KLT"; "change" is "XNK".
    static func sound(_ word: String) -> String {
        var w = word.lowercased().filter { $0.isASCII && $0.isLetter }
        guard !w.isEmpty else { return "" }
        for (a, b) in [("ph", "f"), ("th", "t"), ("sh", "x"), ("ch", "x"), ("ck", "k"), ("qu", "k"), ("wr", "r"), ("kn", "n")] {
            w = w.replacingOccurrences(of: a, with: b)
        }
        let chars = Array(w)
        var out: [Character] = []
        for (i, ch) in chars.enumerated() {
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            let soft = next.map { "eiy".contains($0) } ?? false
            var k: String
            switch ch {
            case "a", "e", "i", "o", "u": k = i == 0 ? "A" : ""
            case "h", "w", "y": k = i == 0 ? String(ch).uppercased() : ""   // "whisper" and "Wispr" keep their W
            case "c": k = soft ? "S" : "K"
            case "g": k = soft ? "J" : "K"
            case "b": k = "P"
            case "d": k = "T"
            case "v": k = "F"
            case "z": k = "S"
            case "q": k = "K"
            case "x": k = "KS"
            default: k = String(ch).uppercased()
            }
            for c in k where out.last != c { out.append(c) }
        }
        return String(out)
    }

    /// 0…1, from edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return x.count == y.count ? 1 : 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    // MARK: Finding misheard names

    struct Candidate: Equatable {
        /// The words as they are in the note.
        var heard: String
        /// The person's word they may stand for.
        var meant: String
        /// Same letters, only spacing or hyphens differ ("Sigma flow" → "SigmaFlow"): fixed without asking anyone.
        var spellingOnly: Bool
    }

    private static let edgeWords: Set<String> = [
        "the", "a", "an", "to", "in", "on", "at", "of", "and", "or", "not", "no", "it", "is", "tag", "this", "that", "hey",
        "for", "with", "under", "have", "has", "my", "our", "your", "its", "it's", "it’s", "as", "be", "i", "so", "but"
    ]

    /// Places in the note that may be one of `words`, misheard. Never more than `max`.
    static func candidates(in note: String, words: [String], max: Int = 4) -> [Candidate] {
        let tokens = note.components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'’-")).inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let known = Set(words.map(squash))
        var spelled: [(Range<Int>, Candidate)] = []
        var scored: [(score: Double, n: Int, range: Range<Int>, Candidate)] = []
        for term in words {
            let st = squash(term), kt = sound(term)
            guard st.count >= 4, kt.count >= 2 else { continue }
            let termWords = Set(term.lowercased().split(separator: " ").map(String.init))
            for n in 1...3 {
                guard tokens.count >= n else { break }
                for i in 0...(tokens.count - n) {
                    let ws = Array(tokens[i..<(i + n)])
                    guard !edgeWords.contains(ws[0].lowercased()), !edgeWords.contains(ws[n - 1].lowercased()) else { continue }
                    let span = ws.joined(separator: " ")
                    let ss = squash(span)
                    guard !ss.isEmpty, span.lowercased() != term.lowercased() else { continue }
                    if ss == st {
                        // Only spacing or hyphens differ. (Capitals alone never get here: "newsletter" is fine.)
                        spelled.append((i..<(i + n), Candidate(heard: span, meant: term, spellingOnly: true)))
                        continue
                    }
                    // A word that is itself one of theirs, or part of this name ("section" in "hero section"), is fine as it is.
                    if ws.contains(where: { known.contains(squash($0)) || termWords.contains($0.lowercased()) }) { continue }
                    guard abs(ss.count - st.count) <= Swift.max(2, st.count / 2) else { continue }
                    // Another form of the same word isn't a mishearing: "designed" / "design", "backgrounds".
                    if isInflection(ss, of: st) { continue }
                    let s1 = similarity(sound(span), kt), s2 = similarity(ss, st)
                    guard s1 >= 0.7, s2 >= 0.4 else { continue }
                    scored.append((s1 + s2, n, i..<(i + n), Candidate(heard: span, meant: term, spellingOnly: false)))
                }
            }
        }
        var used = Set<Int>()
        var out: [Candidate] = []
        for (r, c) in spelled where used.isDisjoint(with: r) {
            used.formUnion(r); out.append(c)
        }
        for s in scored.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.n < $1.n }) {
            guard used.isDisjoint(with: s.range), !out.contains(where: { squash($0.heard) == squash(s.3.heard) }) else { continue }
            used.formUnion(s.range); out.append(s.3)
        }
        return Array(out.prefix(max))
    }

    /// "designed" is "design" + "ed"; "claud" is not "claude" minus an ending.
    static func isInflection(_ a: String, of b: String) -> Bool {
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        guard long.hasPrefix(short) else { return false }
        return ["s", "es", "ed", "d", "ing", "er", "ers", "ly", "'s"].contains(String(long.dropFirst(short.count)))
    }

    /// Puts `meant` where `heard` was, every time, whole words only.
    static func replace(_ heard: String, with meant: String, in text: String) -> String {
        let p = #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: heard) + #"(?![\p{L}\d])"#
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: meant))
    }
}

/// A small lock around a value, for caches read from any thread.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
