import Foundation

struct QueryChip: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case type, looks, colour, date, size, source, device, location, name, text, sort }
    let kind: Kind
    let label: String
    let symbol: String
    var ranges: [NSRange]
    /// Made by Apple Intelligence rather than by a phrase in the text (removing it can't edit the text).
    var isGuess = false
    var id: String { kind.rawValue + ":" + label }
}

/// Something the file should look like, matched against what Orca saw in pictures (Vision labels),
/// falling back to the file's name and text. `labels` are alternatives (any one is enough).
struct LookTerm: Equatable {
    var word: String          // what the person said: "tiger", "seaside"
    var labels: [String]      // classifier labels: ["beach", "ocean", "shore"]
    var ranges: [NSRange] = []
    var isGuess = false
}

enum SortField: String, CaseIterable, Codable, Identifiable {
    case relevance, name, date, size, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relevance: return "Relevance"
        case .name: return "Name"
        case .date: return "Date"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

struct SortSpec: Equatable, Codable {
    var field: SortField
    var ascending: Bool
}

struct ParsedQuery: Equatable {
    var raw = ""
    var categories: Set<FileCategory> = []
    var extensions: Set<String> = []
    var screenshots = false
    var after: Date?
    var before: Date?
    var minSize: Int64?
    var maxSize: Int64?
    var sourceKeys: Set<String> = []
    var sourceDomains: [String] = []
    var anySource = false
    var devices: [String] = []
    var anyCamera = false
    var locations: Set<String> = []
    /// Only files inside these folders (smart folder "Folder" rules).
    var folderPaths: [String] = []
    var nameTerms: [String] = []
    var terms: [String] = []
    var looks: [LookTerm] = []
    /// Main colours the picture / PDF cover should mostly be ("blue").
    var coverColours: [String] = []
    var sort: SortSpec?
    var chips: [QueryChip] = []

    var hasTypeFilter: Bool { !categories.isEmpty || !extensions.isEmpty }
    var hasFilters: Bool {
        hasTypeFilter || screenshots || after != nil || before != nil || minSize != nil || maxSize != nil
            || !sourceKeys.isEmpty || !sourceDomains.isEmpty || anySource || !devices.isEmpty || anyCamera
            || !locations.isEmpty || !folderPaths.isEmpty || !coverColours.isEmpty
    }
    var isEmpty: Bool { !hasFilters && terms.isEmpty && nameTerms.isEmpty && looks.isEmpty }
    var isVisual: Bool { !looks.isEmpty || !coverColours.isEmpty }
    /// The whole description, for MobileCLIP ("people around a whiteboard"), when it says more than
    /// a single look does. Pictures that match it count even if no Vision label or word does.
    var scene: String?
}

/// Rule-based natural-language parser. Every recognised phrase becomes a chip, so the user can see
/// (and undo) exactly how the query was understood. Whatever is left over is matched against
/// file names, tags and the text found inside files.
enum QueryParser {
    // MARK: Vocabulary

    private struct TypeWord {
        var categories: Set<FileCategory> = []
        var exts: Set<String> = []
        var screenshot = false
        var nameHint: String?
        var label: String
    }

    private static let typeWords: [(words: [String], type: TypeWord)] = [
        (["screenshots", "screenshot", "screen shots", "screen shot", "screengrabs", "screengrab", "screen captures", "screen capture", "screenies"],
         TypeWord(categories: [.images], screenshot: true, label: "Screenshots")),
        (["screen recordings", "screen recording", "screencasts", "screencast"],
         TypeWord(categories: [.videos], nameHint: "screen recording", label: "Screen recordings")),
        (["word documents", "word document", "word docs", "word doc", "word files", "docx"],
         TypeWord(exts: ["doc", "docx"], label: "Word docs")),
        (["spreadsheets", "spreadsheet", "excel files", "excel", "sheets", "xlsx", "xls"],
         TypeWord(exts: ["xls", "xlsx", "csv", "numbers", "ods"], label: "Spreadsheets")),
        (["presentations", "presentation", "slide decks", "slide deck", "slides", "decks", "deck", "powerpoints", "powerpoint", "pptx", "ppt", "keynotes", "keynote"],
         TypeWord(exts: ["ppt", "pptx", "key", "odp"], label: "Presentations")),
        (["pdfs", "pdf", "pdf's"], TypeWord(exts: ["pdf"], label: "PDFs")),
        (["csvs", "csv"], TypeWord(exts: ["csv", "tsv"], label: "CSVs")),
        (["text files", "txt files", "txt"], TypeWord(exts: ["txt", "md", "rtf"], label: "Text files")),
        (["markdown"], TypeWord(exts: ["md", "markdown"], label: "Markdown")),
        (["ebooks", "ebook", "epubs", "epub", "books"], TypeWord(exts: ["epub", "mobi", "azw3"], label: "eBooks")),
        (["pngs", "png"], TypeWord(exts: ["png"], label: "PNGs")),
        (["jpgs", "jpg", "jpegs", "jpeg"], TypeWord(exts: ["jpg", "jpeg"], label: "JPEGs")),
        (["heics", "heic", "heif"], TypeWord(exts: ["heic", "heif"], label: "HEIC photos")),
        (["gifs", "gif"], TypeWord(exts: ["gif"], label: "GIFs")),
        (["svgs", "svg"], TypeWord(exts: ["svg"], label: "SVGs")),
        (["webps", "webp"], TypeWord(exts: ["webp"], label: "WebP")),
        (["raw photos", "raws", "dng"], TypeWord(exts: ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "raw"], label: "RAW photos")),
        (["psds", "psd", "photoshop files"], TypeWord(exts: ["psd"], label: "PSDs")),
        (["images", "image", "photos", "photo", "pictures", "picture", "pics", "pic", "pix", "imgs", "img", "graphics", "wallpapers", "wallpaper", "selfies", "selfie", "memes", "meme"],
         TypeWord(categories: [.images], label: "Images")),
        (["movs", "mov"], TypeWord(exts: ["mov"], label: "MOVs")),
        (["mp4s", "mp4"], TypeWord(exts: ["mp4", "m4v"], label: "MP4s")),
        (["mkv", "avi", "webm"], TypeWord(exts: ["mkv", "avi", "webm"], label: "Videos")),
        (["videos", "video", "movies", "movie", "clips", "clip", "films", "film", "footage", "vids", "vid"],
         TypeWord(categories: [.videos], label: "Videos")),
        (["recordings", "recording"], TypeWord(categories: [.videos, .music], label: "Recordings")),
        (["mp3s", "mp3"], TypeWord(exts: ["mp3"], label: "MP3s")),
        (["wavs", "wav"], TypeWord(exts: ["wav"], label: "WAVs")),
        (["flac", "m4a", "aac", "aiff"], TypeWord(exts: ["flac", "m4a", "aac", "aiff", "aif"], label: "Audio")),
        (["music", "songs", "song", "tracks", "track", "audio", "podcasts", "podcast", "sounds", "sound", "voice memos", "voice memo", "tunes"],
         TypeWord(categories: [.music], label: "Music")),
        (["documents", "document", "docs", "doc"], TypeWord(categories: [.documents], label: "Documents")),
        (["installers", "installer", "dmgs", "dmg", "disk images", "disk image", "pkgs", "pkg"],
         TypeWord(exts: ["dmg", "pkg", "mpkg"], label: "Installers")),
        (["zips", "zip files", "zip", "zipped"], TypeWord(exts: ["zip"], label: "ZIPs")),
        (["rars", "rar", "7z", "tarballs", "tars", "tar", "gz"], TypeWord(exts: ["rar", "7z", "tar", "gz", "tgz"], label: "Archives")),
        (["archives", "archive", "compressed files", "compressed"], TypeWord(categories: [.archives], label: "Archives")),
        (["apps", "app", "applications", "application", "programs"], TypeWord(categories: [.apps], label: "Apps")),
        (["fonts", "font"], TypeWord(exts: ["ttf", "otf", "woff", "woff2", "ttc"], label: "Fonts")),
    ]

    static let stopwords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "all", "any", "some", "of", "from", "in", "on", "at", "to", "for",
        "with", "without", "and", "or", "that", "which", "who", "whose", "where", "when", "is", "are", "was",
        "were", "be", "been", "have", "has", "had", "show", "find", "search", "get", "give", "list", "open",
        "display", "look", "looking", "files", "file", "stuff", "things", "thing", "containing", "contain",
        "contains", "include", "including", "includes", "mentioning", "mention", "mentions", "about", "saying",
        "says", "said", "text", "word", "words", "please", "can", "you", "could", "would", "like", "want",
        "need", "those", "these", "there", "here", "it", "its", "taken", "shot", "made", "created", "modified",
        "saved", "sent", "received", "got", "ago", "old", "new", "by", "than", "more", "less", "over", "under",
        "into", "inside", "folder", "let", "see", "where's", "wheres", "what", "whats", "what's", "did", "do",
        "just", "only", "every", "everything", "one", "ones", "kind", "type", "sort", "sorted", "first", "up",
        // conversational filler, so "hey, there's that photo I think I saved" doesn't require these words
        "hey", "hi", "hello", "ok", "okay", "um", "uh", "hmm", "there's", "theres", "remember", "think", "maybe",
        "somewhere", "pls", "thanks", "thank", "i'm", "im", "i've", "ive", "few", "some", "edited", "opened", "used",
        "back", "ago", "recently", "earlier", "lately", "got", "get",
        // telling the story of the file ("the photo I took", "we saw", "a while back")
        "our", "we", "us", "took", "saw", "drew", "scanned", "while"
    ]

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "couple": 2, "couple of": 2, "few": 3
    ]

    private static let months: [(names: [String], number: Int)] = [
        (["january", "jan"], 1), (["february", "feb"], 2), (["march", "mar"], 3), (["april", "apr"], 4),
        (["may"], 5), (["june", "jun"], 6), (["july", "jul"], 7), (["august", "aug"], 8),
        (["september", "sept", "sep"], 9), (["october", "oct"], 10), (["november", "nov"], 11), (["december", "dec"], 12)
    ]

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static let devices: [(word: String, needles: [String], label: String)] = [
        ("iphone", ["iphone"], "iPhone"), ("ipad", ["ipad"], "iPad"),
        ("android", ["pixel", "samsung", "sm-", "oneplus", "xiaomi", "redmi", "huawei", "motorola", "moto ", "oppo", "vivo", "galaxy", "nokia"], "Android"),
        ("pixel", ["pixel"], "Pixel"), ("samsung", ["samsung", "sm-", "galaxy"], "Samsung"), ("galaxy", ["samsung", "sm-", "galaxy"], "Samsung"),
        ("canon", ["canon"], "Canon"), ("nikon", ["nikon"], "Nikon"), ("sony", ["sony", "ilce", "dsc-"], "Sony"),
        ("fujifilm", ["fujifilm"], "Fujifilm"), ("fuji", ["fujifilm"], "Fujifilm"), ("gopro", ["gopro", "hero"], "GoPro"),
        ("dji", ["dji", "fc"], "DJI"), ("drone", ["dji", "fc"], "Drone"), ("leica", ["leica"], "Leica"),
        ("olympus", ["olympus", "om digital"], "Olympus"), ("panasonic", ["panasonic", "dmc-", "dc-"], "Panasonic"),
        ("lumix", ["panasonic", "dmc-", "dc-"], "Lumix"), ("camera", [], "Any camera"),
    ]

    private static let locationWords: [(pattern: String, root: String)] = [
        ("downloads?(?:\\s+folder)?", "Downloads"), ("desktop", "Desktop"), ("documents(?:\\s+folder)?", "Documents"),
        ("pictures(?:\\s+folder)?", "Pictures"), ("movies(?:\\s+folder)?", "Movies"), ("music\\s+folder", "Music"),
        ("applications(?:\\s+folder)?", "Applications")
    ]

    // MARK: Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let r = cache[pattern] { return r }
        let r = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        cache[pattern] = r
        return r
    }

    private static let N = "(\\d+(?:\\.\\d+)?|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|couple(?:\\s+of)?|few)"
    private static let TU = "(minutes?|mins?|hours?|hrs?|days?|weeks?|wks?|months?|mos?|years?|yrs?)"
    private static let SU = "(kb|kilobytes?|mb|megabytes?|megs?|gb|gigabytes?|gigs?|tb|terabytes?|bytes?)"
    private static let NUM = "(\\d+(?:\\.\\d+)?)"

    private final class Ctx {
        let work: NSMutableString
        var q = ParsedQuery()
        var ranges: [QueryChip.Kind: [NSRange]] = [:]
        var typeLabels: [String] = []
        var dateLabel: String?
        var sourceLabels: [String] = []
        var deviceLabels: [String] = []
        var sortLabel: String?
        let now: Date
        let cal: Calendar

        init(_ text: String, now: Date, cal: Calendar) {
            work = NSMutableString(string: text)
            self.now = now
            self.cal = cal
        }

        /// Runs a rule over the not-yet-consumed text. `body` gets the lowercased capture groups
        /// and returns true to accept (consume) the match.
        func each(_ kind: QueryChip.Kind, _ pattern: String, _ body: ([String?]) -> Bool) {
            let re = QueryParser.regex(pattern)
            let snapshot = work as String
            for m in re.matches(in: snapshot, range: NSRange(location: 0, length: work.length)) {
                var groups: [String?] = []
                for g in 0..<m.numberOfRanges {
                    let r = m.range(at: g)
                    groups.append(r.location == NSNotFound ? nil : (snapshot as NSString).substring(with: r).lowercased())
                }
                // Skip matches that overlap text consumed earlier in this same loop.
                let current = work.substring(with: m.range)
                if current.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if current.lowercased() != groups[0] { continue }
                if body(groups) {
                    ranges[kind, default: []].append(m.range)
                    work.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
                }
            }
        }

        func number(_ s: String?) -> Double? {
            guard let s else { return nil }
            if let d = Double(s) { return d }
            return QueryParser.numberWords[s.replacingOccurrences(of: "  ", with: " ")]
        }

        func component(_ unit: String) -> Calendar.Component {
            if unit.hasPrefix("min") { return .minute }
            if unit.hasPrefix("h") { return .hour }
            if unit.hasPrefix("d") { return .day }
            if unit.hasPrefix("w") { return .weekOfYear }
            if unit.hasPrefix("mo") { return .month }
            return .year
        }

        func unitWord(_ c: Calendar.Component, _ n: Double) -> String {
            let plural = n == 1 ? "" : "s"
            switch c {
            case .minute: return "minute\(plural)"
            case .hour: return "hour\(plural)"
            case .day: return "day\(plural)"
            case .weekOfYear: return "week\(plural)"
            case .month: return "month\(plural)"
            default: return "year\(plural)"
            }
        }

        func subtract(_ n: Double, _ c: Calendar.Component) -> Date {
            cal.date(byAdding: c, value: -Int(n.rounded()), to: now) ?? now
        }

        func bytes(_ n: Double, _ unit: String?) -> Int64 {
            let u = unit ?? "mb"
            let mult: Double
            if u.hasPrefix("k") { mult = 1e3 }
            else if u.hasPrefix("m") { mult = 1e6 }
            else if u.hasPrefix("g") { mult = 1e9 }
            else if u.hasPrefix("t") { mult = 1e12 }
            else { mult = 1 }
            return Int64(n * mult)
        }
    }

    // MARK: Parse

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        let ctx = Ctx(text, now: now, cal: calendar)
        ctx.q.raw = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ctx.q }

        parseQuoted(ctx)
        parseNames(ctx)
        parseSort(ctx)
        parseSizes(ctx)
        parseDates(ctx)
        parseDevices(ctx)
        parseLocations(ctx)
        parseSources(ctx)
        parseTypes(ctx)
        parseColours(ctx)
        parseLooks(ctx)
        parseTerms(ctx)

        if ctx.q.isEmpty {
            // Nothing recognised and only filler words left: fall back to a plain name search.
            ctx.q.terms = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        ctx.q.chips = buildChips(ctx)
        ctx.q.scene = scene(for: ctx.q)
        return ctx.q
    }

    /// What's left of the query once kinds, dates, sizes, sources and places are taken out, kept in
    /// the person's word order: "photos of people around a whiteboard from last week" → "people
    /// around a whiteboard". Nil unless it has two or more real words and could be about a picture.
    /// The query says it's after a picture (a look, a colour, photos / screenshots / PDFs). If not,
    /// only strong MobileCLIP matches join the results, so word searches stay word searches.
    static func isAboutPictures(_ q: ParsedQuery) -> Bool {
        q.isVisual || q.screenshots || q.categories.contains(.images) || !q.extensions.isDisjoint(with: VisualAnalyzer.imageExts.union(["pdf"]))
    }

    static func scene(for q: ParsedQuery) -> String? {
        guard MobileCLIP.isBundled else { return nil }
        let pictureKinds: Set<FileCategory> = [.images, .documents]
        let pictureExts = VisualAnalyzer.imageExts.union(["pdf"])
        if q.hasTypeFilter && q.categories.isDisjoint(with: pictureKinds) && q.extensions.isDisjoint(with: pictureExts) { return nil }
        let ns = NSMutableString(string: q.raw)
        // Blank out what other chips explain (keep looks and loose words), and anything in quotes.
        let blank = q.chips.filter { ![.looks, .text].contains($0.kind) }.flatMap(\.ranges)
            + regex("[\"“”][^\"“”]*[\"“”]").matches(in: q.raw, range: NSRange(location: 0, length: ns.length)).map(\.range)
        for r in blank.sorted(by: { $0.location > $1.location }) where r.location + r.length <= ns.length {
            ns.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        let kindWords: Set<String> = ["photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot",
                                      "screenshots", "pdf", "pdfs", "scan", "scans", "document", "documents", "doc", "docs"]
        // Little words that shape the scene ("on", "with", "a") stay inside it; filler goes.
        let glue: Set<String> = ["a", "an", "the", "of", "with", "without", "on", "in", "at", "and", "or", "by", "over", "under", "into", "inside", "near", "around", "behind", "next"]
        var words = (ns as String).lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
        words = words.filter { glue.contains($0) || (!stopwords.contains($0) && !kindWords.contains($0)) }
        while let f = words.first, glue.contains(f) || kindWords.contains(f) { words.removeFirst() }
        while let l = words.last, glue.contains(l) || kindWords.contains(l) { words.removeLast() }
        let content = words.filter { !glue.contains($0) }
        guard content.count >= 2 else { return nil }
        return words.joined(separator: " ")
    }

    private static func parseQuoted(_ c: Ctx) {
        c.each(.text, "[\"“”]([^\"“”]+)[\"“”]") { g in
            guard let phrase = g[1]?.trimmingCharacters(in: .whitespaces), !phrase.isEmpty else { return false }
            c.q.terms.append(phrase)
            return true
        }
    }

    private static func parseNames(_ c: Ctx) {
        c.each(.name, "\\b(?:named|called|titled|name\\s+contains|with\\s+(?:the\\s+)?name)\\s+(?:'([^']+)'|(\\S+))") { g in
            guard let n = g[1] ?? g[2] else { return false }
            c.q.nameTerms.append(n)
            return true
        }
    }

    private static func parseSort(_ c: Ctx) {
        c.each(.sort, "\\b(largest|biggest|heaviest)(?:\\s+first)?\\b") { _ in
            c.q.sort = SortSpec(field: .size, ascending: false); c.sortLabel = "Largest first"; return true
        }
        c.each(.sort, "\\bsmallest(?:\\s+first)?\\b") { _ in
            c.q.sort = SortSpec(field: .size, ascending: true); c.sortLabel = "Smallest first"; return true
        }
        c.each(.sort, "\\b(newest|latest|most\\s+recent|recent\\s+first)(?:\\s+first)?\\b") { _ in
            c.q.sort = SortSpec(field: .date, ascending: false); c.sortLabel = "Newest first"; return true
        }
        c.each(.sort, "\\boldest(?:\\s+first)?\\b") { _ in
            c.q.sort = SortSpec(field: .date, ascending: true); c.sortLabel = "Oldest first"; return true
        }
        c.each(.sort, "\\b(?:sorted|sort|ordered|order)\\s+by\\s+(name|size|date|kind|type)\\b") { g in
            switch g[1] {
            case "name": c.q.sort = SortSpec(field: .name, ascending: true); c.sortLabel = "By name"
            case "size": c.q.sort = SortSpec(field: .size, ascending: false); c.sortLabel = "By size"
            case "date": c.q.sort = SortSpec(field: .date, ascending: false); c.sortLabel = "By date"
            default: c.q.sort = SortSpec(field: .kind, ascending: true); c.sortLabel = "By kind"
            }
            return true
        }
        c.each(.sort, "\\b(?:a\\s*-\\s*z|alphabetical(?:ly)?)\\b") { _ in
            c.q.sort = SortSpec(field: .name, ascending: true); c.sortLabel = "A–Z"; return true
        }
    }

    private static func parseSizes(_ c: Ctx) {
        c.each(.size, "\\bbetween\\s+\(NUM)\\s*\(SU)?\\s*(?:and|to|-)\\s*\(NUM)\\s*\(SU)\\b") { g in
            guard let a = c.number(g[1]), let b = c.number(g[3]) else { return false }
            c.q.minSize = c.bytes(a, g[2] ?? g[4]); c.q.maxSize = c.bytes(b, g[4]); return true
        }
        c.each(.size, "(?:\\b(?:over|above|more\\s+than|bigger\\s+than|larger\\s+than|greater\\s+than|heavier\\s+than|at\\s+least|exceeding|min(?:imum)?)\\s*|>=?\\s*)\(NUM)\\s*\(SU)\\b") { g in
            guard let n = c.number(g[1]) else { return false }
            c.q.minSize = c.bytes(n, g[2]); return true
        }
        c.each(.size, "(?:\\b(?:under|below|less\\s+than|smaller\\s+than|lighter\\s+than|at\\s+most|up\\s+to|max(?:imum)?)\\s*|<=?\\s*)\(NUM)\\s*\(SU)\\b") { g in
            guard let n = c.number(g[1]) else { return false }
            c.q.maxSize = c.bytes(n, g[2]); return true
        }
        c.each(.size, "\\b\(NUM)\\s*\(SU)\\s*(?:\\+|or\\s+(?:more|bigger|larger|above|over)|and\\s+(?:up|above|over|bigger))") { g in
            guard let n = c.number(g[1]) else { return false }
            c.q.minSize = c.bytes(n, g[2]); return true
        }
        c.each(.size, "\\b(?:around|about|roughly|approximately|~)\\s*\(NUM)\\s*\(SU)\\b") { g in
            guard let n = c.number(g[1]) else { return false }
            let v = c.bytes(n, g[2])
            c.q.minSize = Int64(Double(v) * 0.8); c.q.maxSize = Int64(Double(v) * 1.2); return true
        }
        c.each(.size, "\\b\(NUM)\\s*\(SU)\\b") { g in
            guard let n = c.number(g[1]) else { return false }
            c.q.minSize = c.bytes(n, g[2]); return true
        }
        // Size adjectives only when they describe the file ("big videos", "huge files"), not the
        // thing in it ("a big striped cat", "a small dog").
        let F = "(?=\\s+(?:files?|videos?|movies?|clips?|zips?|archives?|pdfs?|photos?|images?|pictures?|folders?|downloads?|apps?|installers?|dmgs?|documents?|docs?|ones?|stuff|recordings?)\\b|\\s*$)"
        c.each(.size, "\\b(huge|massive|giant|enormous|gigantic)\\b\(F)") { _ in c.q.minSize = 1_000_000_000; return true }
        c.each(.size, "\\b(big|large|heavy|bulky)\\b\(F)") { _ in c.q.minSize = 100_000_000; return true }
        c.each(.size, "\\btiny\\b\(F)") { _ in c.q.maxSize = 100_000; return true }
        c.each(.size, "\\b(small|little)\\b\(F)") { _ in c.q.maxSize = 1_000_000; return true }
    }

    private static func monthStart(_ month: Int, year: Int?, c: Ctx) -> Date? {
        var y = year ?? c.cal.component(.year, from: c.now)
        if year == nil, month > c.cal.component(.month, from: c.now) { y -= 1 }
        return c.cal.date(from: DateComponents(year: y, month: month, day: 1))
    }

    private static func parseDates(_ c: Ctx) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM yyyy"

        c.each(.date, "\\bolder\\s+than\\s+\(N)\\s*\(TU)\\b") { g in
            guard let n = c.number(g[1]), let u = g[2] else { return false }
            let comp = c.component(u)
            c.q.before = c.subtract(n, comp); c.dateLabel = "Older than \(Int(n)) \(c.unitWord(comp, n))"; return true
        }
        c.each(.date, "\\b(?:more\\s+than|over|at\\s+least)\\s+\(N)\\s+\(TU)\\s+(?:old|ago)\\b") { g in
            guard let n = c.number(g[1]), let u = g[2] else { return false }
            let comp = c.component(u)
            c.q.before = c.subtract(n, comp); c.dateLabel = "Older than \(Int(n)) \(c.unitWord(comp, n))"; return true
        }
        // "not opened in 6 months", "I haven't opened in a year", "never touched in the past year",
        // "haven't watched in months". Must run before "past year" / "last month", which mean the opposite.
        c.each(.date, "\\b(?:not|never|haven['’]?t|hasn['’]?t|didn['’]?t|have\\s+not|has\\s+not|did\\s+not)\\s+(?:been\\s+)?(?:opened|used|touched|modified|changed|edited|watched|played|viewed|read|listened\\s+to|looked\\s+at)\\s+(?:(?:it|them)\\s+)?(?:in|for)(?:\\s+(?:over|more\\s+than))?(?:\\s+(?:the\\s+)?(?:last|past))?(?:\\s+\(N))?\\s+\(TU)\\b") { g in
            guard let u = g[2] else { return false }
            let comp = c.component(u)
            // No number: "the past year" is one; "in months" / "in years" is a vague few.
            let plural = u.hasSuffix("s")
            let vague: Double = comp == .month ? 3 : comp == .day ? 7 : 2
            guard let n = g[1] == nil ? (plural ? vague : 1) : c.number(g[1]) else { return false }
            c.q.before = c.subtract(n, comp); c.dateLabel = "Untouched for \(Int(n)) \(c.unitWord(comp, n))"; return true
        }
        c.each(.date, "\\b(?:a\\s+)?(few|couple(?:\\s+of)?)\\s+\(TU)\\s+ago\\b") { g in
            // People are vague here: "a few days ago" means roughly the past week, not exactly 3 days.
            guard let u = g[2] else { return false }
            switch c.component(u) {
            case .day: c.q.after = c.subtract(7, .day); c.dateLabel = "Past week"
            case .weekOfYear: c.q.after = c.subtract(1, .month); c.dateLabel = "Past month"
            case .month: c.q.after = c.subtract(6, .month); c.dateLabel = "Past 6 months"
            case .year: c.q.after = c.subtract(5, .year); c.dateLabel = "Past 5 years"
            default: c.q.after = c.subtract(1, .day); c.dateLabel = "Today"
            }
            return true
        }
        c.each(.date, "\\b\(N)\\s+\(TU)\\s+ago\\b") { g in
            guard let n = c.number(g[1]), let u = g[2] else { return false }
            let comp = c.component(u)
            let point = c.subtract(n, comp)
            let unit: Calendar.Component = comp == .minute || comp == .hour ? .day : comp
            guard let iv = c.cal.dateInterval(of: unit, for: point) else { return false }
            c.q.after = iv.start; c.q.before = iv.end
            c.dateLabel = "\(Int(n)) \(c.unitWord(comp, n)) ago"; return true
        }
        c.each(.date, "\\b(?:newer\\s+than|less\\s+than|within(?:\\s+the)?(?:\\s+(?:last|past))?|in\\s+the\\s+(?:last|past)|from\\s+the\\s+(?:last|past)|during\\s+the\\s+(?:last|past)|over\\s+the\\s+(?:last|past)|the\\s+(?:last|past)|past|last)\\s+\(N)\\s*\(TU)(?:\\s+old)?\\b") { g in
            guard let n = c.number(g[1]), let u = g[2] else { return false }
            let comp = c.component(u)
            c.q.after = c.subtract(n, comp); c.dateLabel = "Last \(Int(n)) \(c.unitWord(comp, n))"; return true
        }
        c.each(.date, "\\b(?:past|last)\\s+(day|24\\s+hours)\\b") { _ in
            c.q.after = c.subtract(1, .day); c.dateLabel = "Last 24 hours"; return true
        }
        c.each(.date, "\\b(?:the\\s+)?past\\s+(week|month|year)\\b") { g in
            guard let u = g[1] else { return false }
            let comp = c.component(u)
            c.q.after = c.subtract(1, comp); c.dateLabel = "Past \(u)"; return true
        }
        c.each(.date, "\\b(?:the\\s+)?other\\s+day\\b") { _ in
            c.q.after = c.subtract(7, .day); c.dateLabel = "Past week"; return true
        }
        c.each(.date, "\\b(?:recently|lately)\\b") { _ in
            c.q.after = c.subtract(14, .day); c.dateLabel = "Past 2 weeks"; return true
        }
        c.each(.date, "\\btoday\\b") { _ in
            c.q.after = c.cal.startOfDay(for: c.now); c.dateLabel = "Today"; return true
        }
        c.each(.date, "\\byesterday\\b") { _ in
            let start = c.cal.startOfDay(for: c.subtract(1, .day))
            c.q.after = start; c.q.before = c.cal.startOfDay(for: c.now); c.dateLabel = "Yesterday"; return true
        }
        c.each(.date, "\\b(?:this|current)\\s+(week|month|year)\\b") { g in
            guard let u = g[1], let iv = c.cal.dateInterval(of: c.component(u), for: c.now) else { return false }
            c.q.after = iv.start; c.dateLabel = "This \(u)"; return true
        }
        c.each(.date, "\\b(?:last|previous|prior)\\s+(week|month|year)\\b") { g in
            guard let u = g[1] else { return false }
            let comp = c.component(u)
            guard let iv = c.cal.dateInterval(of: comp, for: c.subtract(1, comp)) else { return false }
            c.q.after = iv.start
            // "last week" stays generous (up to now); last month/year mean that calendar period.
            c.q.before = comp == .weekOfYear ? nil : iv.end
            c.dateLabel = "Last \(u)"; return true
        }
        c.each(.date, "\\b(?:(on|last|this\\s+past)\\s+)?(\(weekdays.joined(separator: "|")))\\b") { g in
            guard let w = g[2], let idx = weekdays.firstIndex(of: w) else { return false }
            let today = c.cal.component(.weekday, from: c.now) - 1
            var back = (today - idx + 7) % 7
            if g[1] == "last" && back == 0 { back = 7 }
            let day = c.cal.startOfDay(for: c.subtract(Double(back), .day))
            c.q.after = day; c.q.before = c.cal.date(byAdding: .day, value: 1, to: day)
            c.dateLabel = w.capitalized; return true
        }
        let monthNames = months.flatMap { $0.names }.joined(separator: "|")
        c.each(.date, "\\b(?:(in|from|during|since|before|after|of|on)\\s+)?(\(monthNames))(?:\\s+((?:19|20)\\d{2}))?\\b") { g in
            guard let name = g[2], let month = months.first(where: { $0.names.contains(name) })?.number else { return false }
            let isFull = months.first(where: { $0.names.first == name }) != nil
            let ambiguous = !isFull || name == "may" || name == "march"
            if ambiguous && g[1] == nil && g[3] == nil { return false }
            guard let start = monthStart(month, year: g[3].flatMap { Int($0) }, c: c),
                  let end = c.cal.date(byAdding: .month, value: 1, to: start) else { return false }
            let label = fmt.string(from: start)
            switch g[1] {
            case "since", "after": c.q.after = g[1] == "after" ? end : start; c.dateLabel = "Since \(label)"
            case "before": c.q.before = start; c.dateLabel = "Before \(label)"
            default: c.q.after = start; c.q.before = end; c.dateLabel = label
            }
            return true
        }
        c.each(.date, "\\b(in|from|during|since|before|after)\\s+((?:19|20)\\d{2})\\b") { g in
            guard let y = g[2].flatMap({ Int($0) }),
                  let start = c.cal.date(from: DateComponents(year: y, month: 1, day: 1)),
                  let end = c.cal.date(from: DateComponents(year: y + 1, month: 1, day: 1)) else { return false }
            switch g[1] {
            case "since": c.q.after = start; c.dateLabel = "Since \(y)"
            case "after": c.q.after = end; c.dateLabel = "After \(y)"
            case "before": c.q.before = start; c.dateLabel = "Before \(y)"
            default: c.q.after = start; c.q.before = end; c.dateLabel = "\(y)"
            }
            return true
        }
        c.each(.date, "\\b(recent(?:ly)?|lately)\\b") { _ in
            c.q.after = c.subtract(30, .day); c.dateLabel = "Recent"; return true
        }
    }

    private static func parseDevices(_ c: Ctx) {
        let words = devices.map { $0.word }.joined(separator: "|")
        c.each(.device, "\\b(?:(from|on|with|by|taken\\s+(?:on|with|by)|shot\\s+(?:on|with)|captured\\s+(?:on|with))\\s+)?(?:my\\s+|an?\\s+|the\\s+)?(\(words))s?\\b") { g in
            guard let w = g[2], let d = devices.first(where: { $0.word == w }) else { return false }
            if w == "camera" {
                guard g[1] != nil else { return false }
                c.q.anyCamera = true
            } else {
                c.q.devices.append(contentsOf: d.needles)
            }
            if !c.deviceLabels.contains(d.label) { c.deviceLabels.append(d.label) }
            return true
        }
    }

    private static func parseLocations(_ c: Ctx) {
        for (pattern, root) in locationWords {
            c.each(.location, "\\b(?:in|on|inside|from|within|under)\\s+(?:my\\s+|the\\s+)?\(pattern)\\b") { _ in
                c.q.locations.insert(root); return true
            }
        }
        c.each(.location, "\\bdownloads\\b") { _ in c.q.locations.insert("Downloads"); return true }
        c.each(.location, "\\bdesktop\\b") { _ in c.q.locations.insert("Desktop"); return true }
    }

    private static func parseSources(_ c: Ctx) {
        let prep = "(?:(?:downloaded\\s+|saved\\s+|got\\s+|grabbed\\s+)?(from|via|on|off|through|in)\\s+)?(?:my\\s+|the\\s+)?"
        for k in DownloadSource.catalog {
            let strong = k.aliases.sorted { $0.count > $1.count }
            let weak = k.weakAliases
            if !strong.isEmpty {
                let alt = strong.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
                c.each(.source, "\\b\(prep)(\(alt))(?:\\.(?:com|net|org|io|ai|so|app))?\\b") { _ in
                    c.q.sourceKeys.insert(k.key)
                    if !c.sourceLabels.contains(k.name) { c.sourceLabels.append(k.name) }
                    return true
                }
            }
            if !weak.isEmpty {
                let alt = weak.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
                c.each(.source, "\\b\(prep)(\(alt))\\b") { g in
                    guard g[1] != nil else { return false }
                    c.q.sourceKeys.insert(k.key)
                    if !c.sourceLabels.contains(k.name) { c.sourceLabels.append(k.name) }
                    return true
                }
            }
        }
        c.each(.source, "\\b(?:air\\s?drop(?:ped)?)\\b") { _ in
            c.q.sourceKeys.insert(DownloadSource.airdrop.key)
            c.sourceLabels.append("AirDrop"); return true
        }
        c.each(.source, "\\b(?:downloaded\\s+)?(?:from|via|on|off)\\s+(?:the\\s+)?((?:[a-z0-9-]+\\.)+[a-z]{2,})\\b") { g in
            guard let d = g[1] else { return false }
            c.q.sourceDomains.append(DownloadSource.registrableDomain(d))
            c.sourceLabels.append(d); return true
        }
        c.each(.source, "\\b(?:from|off)\\s+(?:the\\s+)?(?:internet|web|browser|online)\\b") { _ in
            c.q.anySource = true; c.sourceLabels.append("the web"); return true
        }
        c.each(.source, "\\bdownloaded\\b") { _ in
            c.q.anySource = true; if c.sourceLabels.isEmpty { c.sourceLabels.append("the web") }; return true
        }
    }

    private static func parseTypes(_ c: Ctx) {
        for (words, type) in typeWords {
            // A file can't be an app and also a screenshot / video / PDF, so with another kind already
            // named, "app" is what's in it ("screenshots of a dark mode app") and stays a search word.
            if type.categories == [.apps], c.q.hasTypeFilter || c.q.screenshots { continue }
            let alt = words.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            c.each(.type, "\\b(\(alt))\\b") { _ in
                c.q.categories.formUnion(type.categories)
                c.q.extensions.formUnion(type.exts)
                if type.screenshot { c.q.screenshots = true }
                if let hint = type.nameHint { c.q.nameTerms.append(hint) }
                if !c.typeLabels.contains(type.label) { c.typeLabels.append(type.label) }
                return true
            }
        }
        // "Screenshots" already implies images; don't also show a separate Images chip.
        if c.q.screenshots, c.typeLabels.contains("Images") {
            c.typeLabels.removeAll { $0 == "Images" }
        }
    }

    // MARK: Colours and looks

    private static let colourAlt = "red|orange|yellow|green|teal|blue|navy|purple|violet|pink|brown|black|white|gr[ae]y"

    /// "the PDF where the cover page is blue", "blue cover", "mostly green photos"
    private static func parseColours(_ c: Ctx) {
        // "a dark mode app", "light theme": the screen is mostly black / white.
        c.each(.colour, "\\b(?:(dark|light)\\s+(?:mode|theme|ui)|night\\s+mode)\\b") { g in
            let name = g[1] == "light" ? "white" : "black"
            if !c.q.coverColours.contains(name) { c.q.coverColours.append(name) }
            return true
        }
        let text = (c.work as String).lowercased()
        let context = regex("\\b(cover|colou?r(?:ed)?|background|mostly)\\b")
        guard context.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else { return }
        c.each(.colour, "\\b(\(colourAlt))(?:ish)?\\b") { g in
            guard var name = g[1] else { return false }
            if name == "navy" { name = "blue" } else if name == "violet" { name = "purple" } else if name == "grey" { name = "gray" }
            if !c.q.coverColours.contains(name) { c.q.coverColours.append(name) }
            return true
        }
        guard !c.q.coverColours.isEmpty else { return }
        c.each(.colour, "\\b(?:(?:front|cover|first)\\s+page|cover|colou?r(?:ed)?|background|mostly)\\b") { _ in true }
    }

    /// Words for things that can be seen: "tiger", "seaside", "receipt", "blue sky".
    private static func parseLooks(_ c: Ctx) {
        let vocab = VisualAnalyzer.vocabulary
        guard !vocab.isEmpty else { return }
        // Only when the query isn't limited to kinds that can't be looked at.
        let visualKinds: Set<FileCategory> = [.images, .documents]
        if !c.q.categories.isEmpty && c.q.categories.isDisjoint(with: visualKinds) && !c.q.extensions.contains("pdf") { return }
        let re = regex("[\\p{L}][\\p{L}'’-]*")
        let snapshot = c.work as String
        let matches = re.matches(in: snapshot, range: NSRange(location: 0, length: c.work.length))
        let words = matches.map { (snapshot as NSString).substring(with: $0.range).lowercased() }
        // "the document about my car insurance": what it's about is found as words, not as a picture of a car.
        let topicStart = topicClause(c.q.raw)?.location ?? Int.max
        var i = 0
        while i < words.count {
            let w = words[i]
            if stopwords.contains(w) || matches[i].range.location >= topicStart { i += 1; continue }
            // two-word labels first: "blue sky", "night sky"
            if i + 1 < words.count {
                let pair = w + "_" + SearchEngine.stem(words[i + 1])
                if vocab.contains(pair) {
                    let r = NSUnionRange(matches[i].range, matches[i + 1].range)
                    c.q.looks.append(LookTerm(word: VisualAnalyzer.display(pair), labels: [pair], ranges: [r]))
                    c.work.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
                    i += 2; continue
                }
            }
            let stemmed = SearchEngine.stem(w)
            var labels = VisualAnalyzer.aliases[w] ?? VisualAnalyzer.aliases[stemmed] ?? []
            if labels.isEmpty, vocab.contains(stemmed), !VisualAnalyzer.generic.contains(stemmed) { labels = [stemmed] }
            if !labels.isEmpty {
                let r = matches[i].range
                c.q.looks.append(LookTerm(word: stemmed, labels: labels, ranges: [r]))
                c.work.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
            }
            i += 1
        }
    }

    private static func parseTerms(_ c: Ctx) {
        // "the deck I was working on": how the person used it, not words inside the file.
        // ("working draft" on its own is still searched.)
        let story = regex("\\b(?:(?:was|were|been|am|are|i'?m|i’m)\\s+)?(?:working|worked)\\s+on\\b")
        for m in story.matches(in: c.work as String, range: NSRange(location: 0, length: c.work.length)) {
            c.work.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
        }
        let re = regex("[\\p{L}\\p{N}][\\p{L}\\p{N}._'’&+-]*")
        let snapshot = c.work as String
        for m in re.matches(in: snapshot, range: NSRange(location: 0, length: c.work.length)) {
            var token = (snapshot as NSString).substring(with: m.range).lowercased()
            while let last = token.last, ".'’-".contains(last) { token.removeLast() }
            guard !token.isEmpty, !stopwords.contains(token) else { continue }
            if token.count < 2 && !token.allSatisfy(\.isNumber) { continue }
            c.q.terms.append(token)
            c.ranges[.text, default: []].append(m.range)
        }
    }

    private static func sizeLabel(_ q: ParsedQuery) -> String? {
        switch (q.minSize, q.maxSize) {
        case let (min?, max?): return "\(Fmt.size(min)) – \(Fmt.size(max))"
        case let (min?, nil): return "> \(Fmt.size(min))"
        case let (nil, max?): return "< \(Fmt.size(max))"
        default: return nil
        }
    }

    private static func buildChips(_ c: Ctx) -> [QueryChip] {
        var chips: [QueryChip] = []
        func add(_ kind: QueryChip.Kind, _ label: String?, _ symbol: String) {
            guard let label, !label.isEmpty else { return }
            chips.append(QueryChip(kind: kind, label: label, symbol: symbol, ranges: c.ranges[kind] ?? []))
        }
        add(.type, c.typeLabels.isEmpty ? nil : c.typeLabels.joined(separator: ", "), c.q.screenshots ? "camera.viewfinder" : "square.stack.3d.up")
        chips += lookChips(c.q)
        if !c.q.coverColours.isEmpty {
            chips.append(QueryChip(kind: .colour, label: colourLabel(c.q), symbol: "sparkles", ranges: c.ranges[.colour] ?? []))
        }
        add(.date, c.dateLabel, "calendar")
        add(.size, sizeLabel(c.q), "scalemass")
        add(.source, c.sourceLabels.isEmpty ? nil : "From " + c.sourceLabels.joined(separator: ", "), "arrow.down.circle")
        add(.device, c.deviceLabels.isEmpty ? nil : c.deviceLabels.joined(separator: ", "), "camera")
        add(.location, c.q.locations.isEmpty ? nil : "In " + c.q.locations.sorted().joined(separator: ", "), "folder")
        add(.name, c.q.nameTerms.isEmpty || c.ranges[.name] == nil ? nil : "Name: " + c.q.nameTerms.joined(separator: ", "), "textformat")
        add(.text, c.q.terms.isEmpty ? nil : "“" + c.q.terms.joined(separator: " ") + "”", "text.magnifyingglass")
        add(.sort, c.sortLabel, "arrow.up.arrow.down")
        return chips
    }

    /// A look for a word someone typed into the "Looks like" editor (or picked from suggestions).
    static func lookTerm(for raw: String) -> LookTerm? {
        let w = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return nil }
        let id = w.replacingOccurrences(of: " ", with: "_")
        let stemmed = SearchEngine.stem(w)
        var labels = VisualAnalyzer.aliases[w] ?? VisualAnalyzer.aliases[stemmed] ?? []
        if labels.isEmpty {
            if VisualAnalyzer.vocabulary.contains(id) { labels = [id] }
            else if VisualAnalyzer.vocabulary.contains(stemmed) { labels = [stemmed] }
        }
        // Unknown to the classifier: still a look, matched by MobileCLIP, name and text.
        return LookTerm(word: VisualAnalyzer.display(id), labels: labels)
    }

    /// Rebuilds the looks / colour / text chips after looks or terms were changed by hand.
    static func refreshChips(_ q: inout ParsedQuery, previous: [QueryChip]) {
        var chips = previous.filter { ![.looks, .text].contains($0.kind) }
        let insertAt = chips.firstIndex { $0.kind != .type } ?? chips.count
        chips.insert(contentsOf: lookChips(q), at: insertAt)
        if !q.terms.isEmpty {
            let old = previous.first { $0.kind == .text }
            chips.append(QueryChip(kind: .text, label: "“" + q.terms.joined(separator: " ") + "”", symbol: old?.symbol ?? "text.magnifyingglass", ranges: old?.ranges ?? []))
        }
        q.chips = chips
    }

    static func lookChips(_ q: ParsedQuery) -> [QueryChip] {
        q.looks.map { QueryChip(kind: .looks, label: "Looks like: " + $0.word, symbol: "sparkles", ranges: $0.ranges, isGuess: $0.isGuess) }
    }

    static func colourLabel(_ q: ParsedQuery) -> String {
        let names = q.coverColours.joined(separator: " & ")
        let docs = q.extensions.contains("pdf") || q.categories.contains(.documents)
        return docs ? "Cover: mostly \(names)" : "Mostly \(names)"
    }

    /// Folds Apple Intelligence's reading of the sentence into the rule-based result. Only adds what
    /// the rules can't do well: what the file looks like (with everyday synonyms expanded to labels),
    /// vague dates, and dropping words that were just part of the description. File kinds from the
    /// model are ignored: it often calls a photo of a receipt a "document".
    static func merge(_ q: ParsedQuery, _ r: SentenceRefinement, dismissed: Set<String>, now: Date = Date()) -> ParsedQuery {
        var out = q
        let vocab = VisualAnalyzer.vocabulary
        var guesses: [LookTerm] = []
        // Words the rules already explained or set aside: the topic after "about" ("the document about my car
        // insurance") is found as words, and a camera, app or place ("taken with my Canon") isn't in the picture.
        let ns = q.raw as NSString
        let wordsIn: (NSRange) -> [String] = { r in ns.substring(with: r).lowercased().split { !$0.isLetter }.map { SearchEngine.stem(String($0)) } }
        let topicWords = Set(topicClause(q.raw).map(wordsIn) ?? [])
        let explained = Set(q.chips.filter { ![.looks, .text].contains($0.kind) }.flatMap(\.ranges)
            .filter { $0.location + $0.length <= ns.length }.flatMap(wordsIn))
        let setAside = topicWords.union(explained)
        for g in r.looks {
            let phrase = g.phrase.lowercased().trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty, !dismissed.contains("Looks like: " + phrase) else { continue }
            if phrase.split(separator: " ").allSatisfy({ setAside.contains(SearchEngine.stem(String($0))) }) { continue }
            // Skip what the rules already cover: colours/covers ("blue cover") and file kinds ("screenshots").
            let words = phrase.split(separator: " ").map(String.init)
            let notThings: Set<String> = ["cover", "page", "front", "background", "colour", "color", "coloured", "colored",
                                          "screenshot", "screenshots", "photo", "photos", "picture", "pictures", "image", "images",
                                          "pdf", "pdfs", "file", "files", "document", "documents", "video", "videos", "scan", "scans"]
            if words.allSatisfy({ notThings.contains($0) || !colourWordsIn($0).isEmpty }) { continue }
            // Must come from what was typed (guards against the model echoing its instructions).
            let typed = Set(q.raw.lowercased().split { !$0.isLetter }.map { SearchEngine.stem(String($0)) })
            if !words.contains(where: { typed.contains(SearchEngine.stem($0)) }) { continue }
            var labels = g.words.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }.filter { vocab.contains($0) }
            // A guess needs at least one specific label; "document" or "people" alone would match everything.
            // With MobileCLIP the phrase itself can be matched ("slide with a bar chart"), so labels are optional.
            labels = labels.filter { !VisualAnalyzer.generic.contains($0) }
            guard !labels.isEmpty || MobileCLIP.isBundled else { continue }
            var seen = Set<String>(); labels = labels.filter { seen.insert($0).inserted }   // keep the model's order
            guesses.append(LookTerm(word: phrase, labels: labels, isGuess: true))
        }
        if !guesses.isEmpty {
            // A guess replaces the rule look it covers ("tiger" → "tiger" with more labels).
            let guessWords = Set(guesses.flatMap { $0.word.split(separator: " ").map { SearchEngine.stem(String($0)) } })
            // Rule looks the model didn't see as visual ("restaurant" in "the restaurant bill") only boost.
            let guessLabels = Set(guesses.flatMap(\.labels))
            for l in out.looks where !guessWords.contains(l.word) && guessLabels.isDisjoint(with: l.labels) { out.terms.append(l.word) }
            var kept = out.looks.filter { !guessWords.contains($0.word) && !guessLabels.isDisjoint(with: $0.labels) }
            for g in guesses where !kept.contains(where: { $0.word == g.word }) { kept.append(g) }
            out.looks = kept
            let covered = guessWords.union(guesses.flatMap(\.labels))
            out.terms.removeAll { covered.contains(SearchEngine.stem($0)) }
            // Apple Intelligence already cut the description into look phrases; each is matched on its own.
            out.scene = nil
        }
        if out.coverColours.isEmpty {
            // Only phrases about the whole picture or page ("blue cover", "green background"). In "red car"
            // the colour belongs to the car, which may be a small part of the photo: that's a look, not a filter.
            let wholeWords: Set<String> = ["cover", "page", "front", "background", "colour", "color", "coloured", "colored", "mostly", "all"]
            let colours = r.looks.map { $0.phrase.lowercased() }.filter { p in
                let words = p.split { !$0.isLetter }.map(String.init)
                return words.contains(where: wholeWords.contains) && words.allSatisfy { wholeWords.contains($0) || !colourWordsIn($0).isEmpty }
            }.flatMap(colourWordsIn)
            if !colours.isEmpty && (out.extensions.contains("pdf") || out.categories.contains(.documents) || out.categories.contains(.images)) {
                out.coverColours = Array(Set(colours)).sorted()
            }
        }
        // Vague time the rules didn't catch ("the other day", "recently").
        var dateGuess: String?
        // Only time said relative to now ("a while back", "last summer", "the other day"); a bare "year" or
        // "day" is often part of a name ("new year's eve", "valentine's day") and isn't a when.
        let timeHint = regex("\\b(ago|yesterday|recent|recently|lately|earlier|back|last|past|previous|other\\s+day|this\\s+(?:morning|afternoon|evening|week|weekend|month|year|summer|winter|spring)|tonight|few\\s+(?:days|weeks|months))\\b")
        let hasTime = timeHint.firstMatch(in: q.raw.lowercased(), range: NSRange(location: 0, length: (q.raw as NSString).length)) != nil
        if out.after == nil && out.before == nil && r.withinDays > 0 && hasTime && !dismissed.contains("date") {
            out.after = Calendar.current.date(byAdding: .day, value: -r.withinDays, to: now)
            dateGuess = r.withinDays <= 1 ? "Today" : r.withinDays <= 8 ? "Past week" : r.withinDays <= 32 ? "Past month" : "Past \(r.withinDays) days"
        }
        // Rebuild chips: keep rule chips, swap in the new looks/colour/text/date chips.
        var chips = out.chips.filter { ![.looks, .colour, .text].contains($0.kind) && !(dateGuess != nil && $0.kind == .date) }
        let insertAt = chips.firstIndex { $0.kind != .type } ?? chips.count
        var extra = lookChips(out)
        if !out.coverColours.isEmpty {
            let old = q.chips.first { $0.kind == .colour }
            extra.append(QueryChip(kind: .colour, label: colourLabel(out), symbol: "sparkles", ranges: old?.ranges ?? [], isGuess: old == nil))
        }
        if let dateGuess { extra.append(QueryChip(kind: .date, label: dateGuess, symbol: "calendar", ranges: [], isGuess: true)) }
        chips.insert(contentsOf: extra, at: insertAt)
        if !out.terms.isEmpty, let old = q.chips.first(where: { $0.kind == .text }) {
            chips.append(QueryChip(kind: .text, label: "“" + out.terms.joined(separator: " ") + "”", symbol: old.symbol, ranges: old.ranges))
        }
        out.chips = chips
        return out
    }

    /// Where "about …" / "regarding …" says what a file is about, up to the next comma or full stop.
    static func topicClause(_ text: String) -> NSRange? {
        // Not an amount: "about 2 weeks ago", "about a month ago", "about 5 MB".
        let amount = "(?!\\d|(?:a|an|one|two|three|four|five|six|seven|eight|nine|ten|a\\s+few|a\\s+couple)\\s+(?:of\\s+)?(?:minutes?|hours?|days?|weeks?|months?|years?|kb|mb|gb|megs?|gigs?)\\b)"
        let m = regex("\\b(?:about|regarding|on\\s+the\\s+topic\\s+of)\\s+\(amount)([^,.;]+)").firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        return m?.range(at: 1)
    }

    private static func colourWordsIn(_ s: String) -> [String] {
        s.split { !$0.isLetter }.map(String.init).compactMap { w in
            switch w {
            case "navy": return "blue"
            case "grey": return "gray"
            case "violet": return "purple"
            default: return VisualAnalyzer.colourWords.contains(w) ? w : nil
            }
        }
    }

    /// Removes the words that produced a chip from the query text.
    /// Little words left hanging just before what was removed ("pdfs from last week" → "pdfs", not "pdfs from").
    private static let danglers: Set<String> = ["from", "in", "on", "at", "of", "since", "during", "with", "by", "via", "a", "an", "the", "my", "that", "taken", "shot"]

    static func removing(_ chip: QueryChip, from text: String) -> String {
        let ns = NSMutableString(string: text)
        for r in chip.ranges.sorted(by: { $0.location > $1.location }) where r.location + r.length <= ns.length {
            var start = r.location
            // Only when the removed words were the end of their phrase (nothing but space or a comma follows).
            let after = ns.substring(from: r.location + r.length).trimmingCharacters(in: .whitespaces)
            let endsPhrase = after.isEmpty || after.hasPrefix(",")
            if endsPhrase {
                let word = regex("([\\p{L}]+)\\s+$")
                while start > 0, let m = word.firstMatch(in: ns as String, range: NSRange(location: 0, length: start)),
                      danglers.contains(ns.substring(with: m.range(at: 1)).lowercased()) {
                    start = m.range.location
                }
            }
            ns.replaceCharacters(in: NSRange(location: start, length: r.location + r.length - start), with: "")
        }
        return (ns as String).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
