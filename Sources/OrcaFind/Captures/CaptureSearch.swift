import Foundation

/// V7 — finding a capture from the main search, the way you remember it ("that pricing thread I saved for the
/// newsletter"). Uses the words the query parser kept, and says why each capture matched.
enum CaptureSearch {
    enum Why: Equatable {
        case said(String)          // a bit of what you said around the match
        case title(String)
        case picture(String)       // text Orca read in the picture
        case collection(String)
        case tag(String)
        case link(String)
    }

    /// Captures are pictures, so a search that's clearly about other kinds of files (PDFs, music, apps, sizes)
    /// doesn't look at them.
    static func applies(_ q: ParsedQuery) -> Bool {
        if !q.categories.isEmpty && !q.categories.contains(.images) && !q.categories.contains(.videos) { return false }
        if !q.extensions.isEmpty || q.minSize != nil || q.maxSize != nil || !q.folderPaths.isEmpty { return false }
        return !q.terms.isEmpty || q.raw.contains("#")
    }

    static func find(_ q: ParsedQuery, limit: Int = 9) -> [Capture] {
        guard applies(q) else { return [] }
        let tags = q.raw.split(separator: " ").compactMap { $0.hasPrefix("#") ? CaptureTags.normalize(String($0)) : nil }
        let terms = q.terms.filter { t in !tags.contains { CaptureTags.same($0, t) } }
        let store = CaptureStore.shared
        var list: [Capture]
        if terms.isEmpty {
            list = store.all()
        } else {
            list = store.search(terms.joined(separator: " "), matchAll: true, limit: 60)
            // A long, remembered sentence rarely has every word right: allow all but one.
            if list.isEmpty && terms.count >= 3 {
                list = store.search(terms.joined(separator: " "), matchAll: false, limit: 120)
                    .filter { hits(terms, in: $0) >= terms.count - 1 }
            }
        }
        for t in tags { list = list.filter { $0.hasTag(t) } }
        if let a = q.after { list = list.filter { $0.created >= a } }
        if let b = q.before { list = list.filter { $0.created < b } }
        return Array(list.prefix(limit))
    }

    private static func haystack(_ c: Capture) -> String {
        ([c.note, c.title, c.ocr, c.collection ?? "", c.links.joined(separator: " ")] + c.tagList).joined(separator: " ").lowercased()
    }

    static func hits(_ terms: [String], in c: Capture) -> Int {
        let words = Set(haystack(c).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        return terms.filter { t in words.contains { $0.hasPrefix(t.lowercased()) } }.count
    }

    /// The best single reason, preferring what the person said.
    static func why(_ c: Capture, terms: [String]) -> Why? {
        if let s = snippet(c.note, terms) { return .said(s) }
        if let t = terms.first(where: { t in c.tagList.contains { $0.hasPrefix(t.lowercased()) } }),
           let tag = c.tagList.first(where: { $0.hasPrefix(t.lowercased()) }) { return .tag(tag) }
        if let col = c.collection, terms.contains(where: { col.lowercased().contains($0.lowercased()) }) { return .collection(col) }
        if let s = snippet(c.title, terms) { return .title(s) }
        if let s = snippet(c.ocr.replacingOccurrences(of: "\n", with: " "), terms) { return .picture(s) }
        if let l = c.links.first(where: { l in terms.contains { l.lowercased().contains($0.lowercased()) } }) { return .link(l) }
        if let col = c.collection { return .collection(col) }
        return nil
    }

    /// Up to ~160 characters around the first matching word, with … where it was cut.
    static func snippet(_ text: String, _ terms: [String], radius: Int = 80) -> String? {
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        var first: String.Index?
        for t in terms {
            var search = lower.startIndex..<lower.endIndex
            while let r = lower.range(of: t.lowercased(), range: search) {
                // Word start only: "pricing" in "repricing" doesn't count.
                if r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter {
                    if first.map({ r.lowerBound < $0 }) ?? true { first = r.lowerBound }
                    break
                }
                search = r.upperBound..<lower.endIndex
            }
        }
        guard let hit = first else { return nil }
        let startOffset = max(0, lower.distance(from: lower.startIndex, to: hit) - radius)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(start, offsetBy: min(radius * 2, text.distance(from: start, to: text.endIndex)))
        var s = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > text.startIndex { s = "…" + s }
        if end < text.endIndex { s += "…" }
        return s
    }

    /// Matching words underlined, the rest as is.
    static func highlighted(_ text: String, _ terms: [String]) -> AttributedString {
        var out = AttributedString(text)
        let lower = text.lowercased()
        for t in terms where t.count >= 2 {
            var search = lower.startIndex..<lower.endIndex
            while let r = lower.range(of: t.lowercased(), range: search) {
                let wordStart = r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter
                // Extend to the end of the word ("thread" → "threads").
                var e = r.upperBound
                while e < lower.endIndex, lower[e].isLetter { e = lower.index(after: e) }
                if wordStart,
                   let a = AttributedString.Index(text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound)), within: out),
                   let b = AttributedString.Index(text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: e)), within: out) {
                    out[a..<b].underlineStyle = .single
                    out[a..<b].inlinePresentationIntent = .stronglyEmphasized
                }
                search = e..<lower.endIndex
            }
        }
        return out
    }
}
