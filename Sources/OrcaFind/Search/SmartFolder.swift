import Foundation

/// A search that stays open: a list of rules that fill the folder as matching files arrive.
/// Files never move — a smart folder is only a view, so deleting one never deletes a file.
struct SmartFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var rules: [SmartRule]
    var matchAll = true
    var showOnHome = false
    var created = Date()
    /// When the folder was last opened; files added after this are "new".
    var lastSeen = Date()
}

struct SmartRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var field: Field
    /// Kind / date / size / other: a phrase the query parser understands ("pdfs", "this year", "over 100 mb").
    /// Name / text / looks / colour: the word itself. Source: a source key ("gmail", "web:apple.com", "*").
    /// Folder: an absolute path, or a root name like "Downloads".
    var value: String
    /// Looks only: classifier labels (kept from Apple Intelligence's reading, so the folder matches the same way).
    var labels: [String]?

    enum Field: String, Codable, CaseIterable, Identifiable {
        case kind, name, text, looks, colour, source, date, size, folder, other
        var id: String { rawValue }
        static let editable: [Field] = [.kind, .name, .text, .looks, .colour, .source, .date, .size, .folder]

        var title: String {
            switch self {
            case .kind: return "Kind"
            case .name: return "Name"
            case .text: return "Text inside"
            case .looks: return "Looks like"
            case .colour: return "Colour"
            case .source: return "Came from"
            case .date: return "Date"
            case .size: return "Size"
            case .folder: return "Folder"
            case .other: return "Also"
            }
        }
        var op: String {
            switch self {
            case .kind, .source, .date, .size: return "is"
            case .name, .text: return "contains"
            case .looks, .other: return ""
            case .colour: return "mostly"
            case .folder: return "inside"
            }
        }
        var symbol: String {
            switch self {
            case .kind: return "square.stack.3d.up"
            case .name: return "textformat"
            case .text: return "text.viewfinder"
            case .looks, .colour: return "sparkles"
            case .source: return "arrow.down.circle"
            case .date: return "calendar"
            case .size: return "scalemass"
            case .folder: return "folder"
            case .other: return "line.3.horizontal.decrease"
            }
        }
        /// Fields whose value is typed rather than picked.
        var isTyped: Bool { self == .name || self == .text || self == .looks }
    }

    // MARK: Choices for the rule editor

    struct Option: Hashable { let label: String; let value: String }

    static let kindOptions: [Option] = [
        Option(label: "Images", value: "images"), Option(label: "Screenshots", value: "screenshots"),
        Option(label: "Videos", value: "videos"), Option(label: "Screen recordings", value: "screen recordings"),
        Option(label: "Music & audio", value: "music"), Option(label: "Documents", value: "documents"),
        Option(label: "PDFs", value: "pdfs"), Option(label: "Word docs", value: "word docs"),
        Option(label: "Spreadsheets", value: "spreadsheets"), Option(label: "Presentations", value: "presentations"),
        Option(label: "Text files", value: "text files"), Option(label: "eBooks", value: "ebooks"),
        Option(label: "Archives", value: "archives"), Option(label: "Installers", value: "installers"),
        Option(label: "Apps", value: "apps"), Option(label: "Fonts", value: "fonts"),
    ]
    static let dateOptions: [Option] = [
        Option(label: "Today", value: "today"), Option(label: "Yesterday", value: "yesterday"),
        Option(label: "Past week", value: "past week"), Option(label: "Past month", value: "past month"),
        Option(label: "Last 3 months", value: "last 3 months"), Option(label: "This year", value: "this year"),
        Option(label: "Last year", value: "last year"), Option(label: "Older than a year", value: "older than 1 year"),
    ]
    static let sizeOptions: [Option] = [
        Option(label: "Under 1 MB", value: "under 1 mb"), Option(label: "Under 10 MB", value: "under 10 mb"),
        Option(label: "Over 10 MB", value: "over 10 mb"), Option(label: "Over 100 MB", value: "over 100 mb"),
        Option(label: "Over 1 GB", value: "over 1 gb"),
    ]
    static let colourOptions = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "brown", "black", "white", "gray"]

    static func blank(_ field: Field) -> SmartRule {
        switch field {
        case .kind: return SmartRule(field: field, value: kindOptions[0].value)
        case .date: return SmartRule(field: field, value: "past month")
        case .size: return SmartRule(field: field, value: "over 100 mb")
        case .colour: return SmartRule(field: field, value: "blue")
        case .source: return SmartRule(field: field, value: "*")
        case .folder: return SmartRule(field: field, value: "Downloads")
        default: return SmartRule(field: field, value: "")
        }
    }

    var isEmpty: Bool { value.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Display

    /// What the value chip says: "PDFs", "This year", "“acme”", "Gmail".
    func valueLabel(sources: [SourceSummary] = []) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        switch field {
        case .kind:
            return Self.kindOptions.first { $0.value == v }?.label ?? QueryParser.parse(v).chips.first { $0.kind == .type }?.label ?? v
        case .date:
            return Self.dateOptions.first { $0.value == v }?.label ?? QueryParser.parse(v).chips.first { $0.kind == .date }?.label ?? v
        case .size:
            return Self.sizeOptions.first { $0.value == v }?.label ?? QueryParser.parse(v).chips.first { $0.kind == .size }?.label ?? v
        case .name, .text: return v.isEmpty ? "…" : "“\(v)”"
        case .looks: return v.isEmpty ? "…" : v
        case .colour: return v.capitalized
        case .source: return Self.sourceName(v, sources: sources)
        case .folder: return v.hasPrefix("/") ? FileManager.default.displayName(atPath: v) : v
        case .other: return QueryParser.parse(v).chips.first?.label ?? v
        }
    }

    /// One-line summary used on chips outside the editor: "PDFs", "Text: “acme”", "From Gmail".
    func summary(sources: [SourceSummary] = []) -> String {
        let v = valueLabel(sources: sources)
        switch field {
        case .kind, .date, .size, .other: return v
        case .name: return "Name: \(v)"
        case .text: return "Text: \(v)"
        case .looks: return "Looks like: \(v)"
        case .colour: return "Mostly \(value.lowercased())"
        case .source: return value == "*" ? "Downloaded" : "From \(v)"
        case .folder: return "In \(v)"
        }
    }

    static func sourceName(_ key: String, sources: [SourceSummary]) -> String {
        if key == "*" { return "Anywhere online" }
        if let s = sources.first(where: { $0.id == key }) { return s.source.name }
        if let k = DownloadSource.catalog.first(where: { $0.key == key }) { return k.name }
        return key.hasPrefix("web:") ? String(key.dropFirst(4)) : key
    }

    // MARK: Compile

    /// The part of a query this rule asks for, or nil when the rule is still blank.
    func query() -> ParsedQuery? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        var q = ParsedQuery()
        switch field {
        case .kind:
            let p = QueryParser.parse(v)
            guard p.hasTypeFilter || p.screenshots else { return nil }
            q.categories = p.categories; q.extensions = p.extensions; q.screenshots = p.screenshots; q.nameTerms = p.nameTerms
        case .date:
            let p = QueryParser.parse(v)
            guard p.after != nil || p.before != nil else { return nil }
            q.after = p.after; q.before = p.before
        case .size:
            let p = QueryParser.parse(v)
            guard p.minSize != nil || p.maxSize != nil else { return nil }
            q.minSize = p.minSize; q.maxSize = p.maxSize
        case .name:
            q.nameTerms = [v]
        case .text:
            q.terms = v.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        case .looks:
            if let l = labels, !l.isEmpty { q.looks = [LookTerm(word: v.lowercased(), labels: l)] }
            else if let l = QueryParser.lookTerm(for: v) { q.looks = [l] }
        case .colour:
            q.coverColours = [v.lowercased()]
        case .source:
            if v == "*" { q.anySource = true } else { q.sourceKeys = [v] }
        case .folder:
            if v.hasPrefix("/") { q.folderPaths = [v] } else { q.locations = [v] }
        case .other:
            q = QueryParser.parse(v)
            q.chips = []
        }
        return q
    }
}

extension ParsedQuery {
    /// Everything in `self` and `other` must hold (dates and sizes narrow; kinds and sources widen).
    func combined(with o: ParsedQuery) -> ParsedQuery {
        var q = self
        q.categories.formUnion(o.categories)
        q.extensions.formUnion(o.extensions)
        q.screenshots = q.screenshots || o.screenshots
        if let a = o.after { q.after = max(q.after ?? a, a) }
        if let b = o.before { q.before = min(q.before ?? b, b) }
        if let m = o.minSize { q.minSize = max(q.minSize ?? m, m) }
        if let m = o.maxSize { q.maxSize = min(q.maxSize ?? m, m) }
        q.sourceKeys.formUnion(o.sourceKeys)
        q.sourceDomains += o.sourceDomains
        q.anySource = q.anySource || o.anySource
        q.devices += o.devices
        q.anyCamera = q.anyCamera || o.anyCamera
        q.locations.formUnion(o.locations)
        q.folderPaths += o.folderPaths
        q.nameTerms += o.nameTerms
        q.terms += o.terms
        q.looks += o.looks
        q.coverColours += o.coverColours
        if q.sort == nil { q.sort = o.sort }
        return q
    }
}

extension SmartFolder {
    /// Files in the folder right now, newest first.
    static func run(rules: [SmartRule], matchAll: Bool, in items: [FileItem]) -> [FileItem] {
        let parts = rules.compactMap { $0.query() }
        guard !parts.isEmpty else { return [] }
        var found: [FileItem]
        if matchAll || parts.count == 1 {
            var q = parts[0]
            for p in parts.dropFirst() { q = q.combined(with: p) }
            q.sort = nil
            guard !q.isEmpty else { return [] }
            found = SearchEngine.run(q, in: items)
        } else {
            var seen = Set<String>()
            found = []
            for var p in parts {
                p.sort = nil
                guard !p.isEmpty else { continue }
                for item in SearchEngine.run(p, in: items) where seen.insert(item.id).inserted { found.append(item) }
            }
        }
        return SearchEngine.apply(SortSpec(field: .date, ascending: false), to: found)
    }

    func run(in items: [FileItem]) -> [FileItem] { Self.run(rules: rules, matchAll: matchAll, in: items) }

    /// When a file arrived, for "new since you last looked".
    static func arrival(_ item: FileItem) -> Date { item.added ?? item.created ?? item.activityDate }

    /// Turns an understood search into editable rules: one rule per chip.
    static func rules(from q: ParsedQuery) -> [SmartRule] {
        var out: [SmartRule] = []
        func phrase(_ chip: QueryChip) -> String {
            let ns = q.raw as NSString
            let typed = chip.ranges.filter { $0.location + $0.length <= ns.length }.sorted { $0.location < $1.location }
                .map { ns.substring(with: $0) }.joined(separator: " ").lowercased()
            return typed.isEmpty ? chip.label.lowercased() : typed
        }
        for chip in q.chips {
            switch chip.kind {
            case .type:
                out.append(SmartRule(field: .kind, value: phrase(chip)))
            case .date:
                var p = phrase(chip)
                let parsed = QueryParser.parse(p)
                if parsed.after == nil && parsed.before == nil { p = chip.label.lowercased() }
                out.append(SmartRule(field: .date, value: p))
            case .size:
                out.append(SmartRule(field: .size, value: phrase(chip)))
            case .device, .sort:
                out.append(SmartRule(field: .other, value: phrase(chip)))
            case .location:
                for l in q.locations.sorted() { out.append(SmartRule(field: .folder, value: l)) }
            case .name:
                for n in q.nameTerms where n != "screen recording" { out.append(SmartRule(field: .name, value: n)) }
            case .text:
                if !q.terms.isEmpty { out.append(SmartRule(field: .text, value: q.terms.joined(separator: " "))) }
            case .looks:
                if let l = q.looks.first(where: { "Looks like: " + $0.word == chip.label }) {
                    out.append(SmartRule(field: .looks, value: l.word, labels: l.labels.isEmpty ? nil : l.labels))
                }
            case .colour:
                for c in q.coverColours { out.append(SmartRule(field: .colour, value: c)) }
            case .source:
                for k in q.sourceKeys.sorted() { out.append(SmartRule(field: .source, value: k)) }
                if !q.sourceDomains.isEmpty { out.append(SmartRule(field: .other, value: phrase(chip))) }
                else if q.anySource && q.sourceKeys.isEmpty { out.append(SmartRule(field: .source, value: "*")) }
            }
        }
        return out
    }

    /// A name from the words someone searched for: "screenshots with wifi password" → "Screenshots with wifi password".
    static func suggestedName(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first else { return "New smart folder" }
        return String(f).uppercased() + t.dropFirst()
    }
}

/// Numbers shown on a smart folder's tile.
struct SmartFolderStats {
    var count = 0
    var size: Int64 = 0
    var newCount = 0
    var preview: [FileItem] = []
    var kind: FileCategory = .documents
}
