import Foundation

enum SearchEngine {
    /// Lowercased, accent-free, separators removed: "Wi-Fi_Password" -> "wifipassword".
    static func squash(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        for u in folded.unicodeScalars where alnum.contains(u) { out.append(u) }
        return String(out)
    }
    private static let alnum = CharacterSet.alphanumerics

    static func passesFilters(_ item: FileItem, _ q: ParsedQuery) -> Bool {
        if q.hasTypeFilter {
            guard q.categories.contains(item.category) || q.extensions.contains(item.ext) else { return false }
        }
        if q.screenshots && !item.isScreenshot { return false }
        let d = item.activityDate
        if let a = q.after, d < a { return false }
        if let b = q.before, d >= b { return false }
        if let m = q.minSize, item.size < m { return false }
        if let m = q.maxSize, item.size > m { return false }
        if !q.sourceKeys.isEmpty || !q.sourceDomains.isEmpty || q.anySource {
            guard let s = item.source else { return false }
            let byKey = q.sourceKeys.contains(s.key)
            let byDomain = q.sourceDomains.contains { dom in
                s.name == dom || (s.host?.hasSuffix(dom) ?? false)
            }
            guard byKey || byDomain || (q.anySource && q.sourceKeys.isEmpty && q.sourceDomains.isEmpty) else { return false }
        }
        if !q.devices.isEmpty || q.anyCamera {
            guard let cam = item.camera?.lowercased(), !item.isScreenshot else { return false }
            if !q.devices.isEmpty && !q.devices.contains(where: { cam.contains($0) }) { return false }
        }
        if !q.locations.isEmpty && !q.locations.contains(item.rootName) { return false }
        if !q.folderPaths.isEmpty && !q.folderPaths.contains(where: { item.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return false }
        return true
    }

    /// Very small English stemmer so "invoices" finds "invoice.pdf" and "copies" finds "copy".
    static func stem(_ term: String) -> String {
        guard term.count > 3, term.allSatisfy({ $0.isLetter || $0 == " " }) else { return term }
        if term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
        if term.hasSuffix("sses") || term.hasSuffix("xes") || term.hasSuffix("ches") || term.hasSuffix("shes") {
            return String(term.dropLast(2))
        }
        if term.hasSuffix("s") && !term.hasSuffix("ss") && !term.hasSuffix("us") && !term.hasSuffix("is") {
            return String(term.dropLast())
        }
        return term
    }

    static func run(_ q: ParsedQuery, in items: [FileItem], limit: Int? = nil) -> [FileItem] {
        let stems = q.terms.map(stem)
        let terms = stems.map { ($0, squash($0)) }
        let contentHits: [Set<String>] = stems.map { Database.shared.paths(matching: $0) }
        let names = q.nameTerms.map(squash)
        // Looks: matched by what Orca saw in the picture, else by the word in the name or text.
        let looks = q.looks.map { l in (labels: l.labels, key: squash(l.word), content: Database.shared.paths(matching: stem(l.word))) }
        let colours = q.coverColours
        let store = VisualStore.shared
        // MobileCLIP: each look phrase, and the whole description, matched against picture embeddings.
        let clip = clipMatches(q)

        var scored: [(FileItem, Int)] = []
        scored.reserveCapacity(min(items.count, 5000))
        for item in items where !item.isFolder {
            guard passesFilters(item, q) else { continue }
            var score = 0
            var ok = true
            let nameKey = (names.isEmpty && terms.isEmpty) ? "" : squash(item.name)
            for n in names where !nameKey.contains(n) { ok = false; break }
            if !ok { continue }
            if !looks.isEmpty || !colours.isEmpty {
                let seen = store.get(item.path)
                for c in colours {
                    let share = seen?.colour(c) ?? 0
                    if share < 0.45 { ok = false; break }
                    score += Int(share * 10)
                }
                if !ok { continue }
                let key = looks.isEmpty ? "" : squash(item.name)
                // One described thing must match; with several ("dog at the beach"), at least half
                // must, and files showing more of them rank higher.
                let needed = looks.count <= 1 ? looks.count : (looks.count + 1) / 2
                var hits = 0
                for (i, l) in looks.enumerated() {
                    let conf = l.labels.map { seen?.label($0) ?? 0 }.max() ?? 0
                    // Seen by Vision or by MobileCLIP: whichever is surer counts.
                    let byLabel = conf >= 0.12 ? 6 + Int(conf * 20) : 0
                    let byClip = clip.looks[i][item.path].map { 6 + Int($0.weight * 20) } ?? 0
                    if max(byLabel, byClip) > 0 { score += max(byLabel, byClip); hits += 1 }
                    else if !l.key.isEmpty && key.contains(l.key) { score += 10; hits += 1 }
                    else if l.content.contains(item.path) { score += 4; hits += 1 }
                }
                // A picture that matches the whole description ("people around a whiteboard") has it all.
                if clip.scene[item.path] != nil { hits = max(hits, needed) }
                if hits < needed { continue }
            }
            let sceneHit = clip.scene[item.path]
            if let m = sceneHit { score += 8 + Int(m.weight * 24) }
            for (i, term) in terms.enumerated() {
                let inName = !term.1.isEmpty && nameKey.contains(term.1)
                let inTags = item.tags.contains { squash($0).contains(term.1) }
                let inSource = item.source.map { squash($0.name).contains(term.1) } ?? false
                let inContent = contentHits[i].contains(item.path)
                if inName {
                    score += nameKey.hasPrefix(term.1) ? 14 : 10
                } else if inTags {
                    score += 8
                } else if inContent || inSource {
                    score += 4
                } else if q.isVisual || sceneHit != nil {
                    // "people working on laptops": the picture is the point; extra words only boost.
                    continue
                } else {
                    ok = false; break
                }
            }
            if ok { scored.append((item, score)) }
        }

        if let sort = q.sort {
            let sorted = apply(sort, to: scored.map { $0.0 })
            return limit.map { Array(sorted.prefix($0)) } ?? sorted
        }
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.activityDate > b.0.activityDate
        }
        let out = scored.map { $0.0 }
        return limit.map { Array(out.prefix($0)) } ?? out
    }

    /// Ways forward when a search finds nothing (S11): loosen one thing at a time and say how much it helps.
    struct WaysOut: Sendable {
        var anyDate = 0              // matches if the date is dropped
        var asText: (word: String, count: Int)?
        var close: [FileItem] = []   // look partly like what was asked
        var closeReasons: [String: String] = [:]
    }

    static func waysOut(_ q: ParsedQuery, in items: [FileItem]) -> WaysOut {
        var out = WaysOut()
        if q.after != nil || q.before != nil {
            var noDate = q; noDate.after = nil; noDate.before = nil
            out.anyDate = run(noDate, in: items, limit: 500).count
        }
        if let first = q.looks.first {
            var asText = q; asText.looks.removeFirst(); asText.terms.append(first.word)
            out.asText = (first.word, run(asText, in: items, limit: 500).count)
        }
        // Close matches: same filters, but the look matched through related labels (tiger → feline).
        if !q.looks.isEmpty {
            var loose = q
            var broader: [String: [String]] = [:]
            for i in loose.looks.indices {
                let rel = VisualStore.shared.related(to: loose.looks[i].labels, limit: 3)
                broader[loose.looks[i].word] = rel
                loose.looks[i].labels = rel
            }
            let found = run(loose, in: items, limit: 8)
            out.close = found
            for item in found {
                guard let seen = VisualStore.shared.get(item.path) else { continue }
                for l in q.looks {
                    if let best = (broader[l.word] ?? []).map({ ($0, seen.label($0)) }).max(by: { $0.1 < $1.1 }), best.1 >= 0.12 {
                        out.closeReasons[item.id] = "✦ Partly like \(VisualAnalyzer.phrase(l.word.replacingOccurrences(of: " ", with: "_"))) · \(VisualAnalyzer.display(best.0)) \(Int((best.1 * 100).rounded()))%"
                        break
                    }
                }
            }
            out.close.removeAll { out.closeReasons[$0.id] == nil }
        }
        return out
    }

    /// The short "why it matched" line shown on a card, when the match came from looking at the file.
    static func reason(for item: FileItem, _ q: ParsedQuery) -> String? {
        guard q.isVisual || q.scene != nil else { return nil }
        let clip = clipMatches(q)
        // The whole description is the most specific thing we can say.
        if let s = q.scene, let m = clip.scene[item.path] { return "✦ Looks like \(s) · \(m.strength.words)" }
        guard let seen = VisualStore.shared.get(item.path) ?? (clip.isEmpty ? nil : VisualInfo()) else { return nil }
        if let c = q.coverColours.first {
            let share = seen.colour(c)
            guard share >= 0.45 else { return nil }
            let doc = item.ext == "pdf"
            return "✦ \(doc ? "Cover is" : "Mostly") \(Int((share * 100).rounded()))% \(c)"
        }
        for l in q.looks {
            // Highest confidence wins; ties go to the label listed first (the most specific guess).
            let ranked = l.labels.enumerated().map { ($0.element, seen.label($0.element), $0.offset) }
            if let best = ranked.max(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 > $1.2 }), best.1 >= 0.12 {
                // Say it in the person's words for guesses ("a beach"), in the label's words otherwise.
                let what = l.isGuess ? VisualAnalyzer.phrase(l.word.replacingOccurrences(of: " ", with: "_")) : VisualAnalyzer.phrase(best.0)
                return "✦ Looks like \(what) · \(Int((best.1 * 100).rounded()))%"
            }
        }
        for (i, l) in q.looks.enumerated() {
            if let m = clip.looks[i][item.path] {
                return "✦ Looks like \(VisualAnalyzer.phrase(l.word.replacingOccurrences(of: " ", with: "_"))) · \(m.strength.words)"
            }
        }
        return nil
    }

    struct ClipMatches {
        var looks: [[String: MobileCLIP.Match]]   // one per q.looks, same order
        var scene: [String: MobileCLIP.Match]
        var isEmpty: Bool { scene.isEmpty && looks.allSatisfy(\.isEmpty) }
    }

    /// Pictures MobileCLIP thinks fit each look and the whole description. Empty when the model or
    /// the embeddings aren't there yet (the search then works exactly as before).
    static func clipMatches(_ q: ParsedQuery) -> ClipMatches {
        let none = ClipMatches(looks: q.looks.map { _ in [:] }, scene: [:])
        guard (q.isVisual || q.scene != nil), Preferences.smartPicturesValue,
              MobileCLIP.isBundled, EmbeddingStore.shared.count > 0, MobileCLIP.isAvailable else { return none }
        // With a description, MobileCLIP judges the whole of it; single words out of it are ambiguous
        // ("bar" in "a bar chart") and stay with Vision's labels. Without one (a lone "tiger", or Apple
        // Intelligence's look phrases), each look is matched on its own.
        if let s = q.scene {
            var found = MobileCLIP.matches(for: s)
            if !QueryParser.isAboutPictures(q) { found = found.filter { $0.value.strength == .strong } }
            return ClipMatches(looks: q.looks.map { _ in [:] }, scene: found)
        }
        return ClipMatches(looks: q.looks.map { MobileCLIP.matches(for: $0.word) }, scene: [:])
    }

    static func apply(_ sort: SortSpec, to items: [FileItem]) -> [FileItem] {
        let asc = sort.ascending
        switch sort.field {
        case .relevance:
            return items
        case .name:
            return items.sorted {
                let r = $0.name.localizedStandardCompare($1.name)
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        case .date:
            return items.sorted { asc ? $0.activityDate < $1.activityDate : $0.activityDate > $1.activityDate }
        case .size:
            return items.sorted { asc ? $0.size < $1.size : $0.size > $1.size }
        case .kind:
            return items.sorted {
                if $0.ext != $1.ext { return asc ? $0.ext < $1.ext : $0.ext > $1.ext }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}

enum Fmt {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    static func size(_ bytes: Int64) -> String { byteFormatter.string(fromByteCount: bytes) }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    static func relative(_ date: Date?) -> String {
        guard let date, date > .distantPast else { return "—" }
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
    static func date(_ date: Date?) -> String {
        guard let date, date > .distantPast else { return "—" }
        return dateFormatter.string(from: date)
    }

    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s > 0 else { return "" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
    static func count(_ n: Int) -> String { numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func plural(_ n: Int, _ word: String, _ plural: String? = nil) -> String {
        "\(count(n)) \(n == 1 ? word : (plural ?? word + "s"))"
    }
}
