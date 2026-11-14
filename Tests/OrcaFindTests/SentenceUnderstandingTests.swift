import Foundation
import Testing
@testable import OrcaFind

/// Long, chatty searches read by Apple Intelligence on this Mac, then folded into the rules
/// (exactly what the search box does). Checks the final result a person sees: chips, looks, dates.
/// Skipped where the on-device model isn't available. Run on its own: `swift test --filter SentenceUnderstandingTests`.
@Suite("Search: AppleModel sentences", .serialized, .enabled(if: SentenceUnderstanding.status == .available))
struct SentenceUnderstandingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let text: String
        let check: @Sendable (ParsedQuery) -> [String]
        var testDescription: String { text }
        init(_ text: String, _ check: @escaping @Sendable (ParsedQuery) -> [String]) { self.text = text; self.check = check }
    }

    // MARK: Checks (each returns what's wrong, empty when right)

    /// Something it should look like: any of these words, as the look's word or one of its labels.
    static func looks(_ any: String...) -> @Sendable (ParsedQuery) -> [String] {
        { q in
            let all = q.looks.flatMap { [$0.word] + $0.word.split(separator: " ").map(String.init) + $0.labels }.map { $0.lowercased() }
            return any.contains { a in all.contains { $0 == a || SearchEngine.stem($0) == SearchEngine.stem(a) } } ? [] : ["no look for \(any.joined(separator: "/"))"]
        }
    }
    static func noLook(_ word: String) -> @Sendable (ParsedQuery) -> [String] {
        { q in q.looks.contains { $0.word == word || $0.word.split(separator: " ").contains(Substring(word)) } ? ["shouldn't look for \(word)"] : [] }
    }
    static func date(_ label: String) -> @Sendable (ParsedQuery) -> [String] {
        { q in
            let got = q.chips.first { $0.kind == .date }?.label
            return got == label ? [] : ["date \(got ?? "none"), wanted \(label)"]
        }
    }
    static let noDate: @Sendable (ParsedQuery) -> [String] = { q in q.after == nil && q.before == nil ? [] : ["unexpected date"] }
    static let noSize: @Sendable (ParsedQuery) -> [String] = { q in q.minSize == nil && q.maxSize == nil ? [] : ["unexpected size"] }
    static let noColour: @Sendable (ParsedQuery) -> [String] = { q in q.coverColours.isEmpty ? [] : ["unexpected 'mostly \(q.coverColours.joined())'"] }
    static func colour(_ c: String) -> @Sendable (ParsedQuery) -> [String] { { q in q.coverColours.contains(c) ? [] : ["no colour \(c)"] } }
    static func kind(_ c: FileCategory) -> @Sendable (ParsedQuery) -> [String] { { q in q.categories.contains(c) ? [] : ["kind isn't \(c)"] } }
    static func ext(_ e: String) -> @Sendable (ParsedQuery) -> [String] { { q in q.extensions.contains(e) ? [] : ["kind isn't \(e)"] } }
    static func notKind(_ c: FileCategory) -> @Sendable (ParsedQuery) -> [String] { { q in q.categories.contains(c) ? ["kind shouldn't be \(c)"] : [] } }
    static let screenshots: @Sendable (ParsedQuery) -> [String] = { q in q.screenshots ? [] : ["not screenshots"] }
    static func word(_ w: String) -> @Sendable (ParsedQuery) -> [String] { { q in q.terms.contains(w) ? [] : ["'\(w)' isn't searched as a word"] } }
    static func device(_ d: String) -> @Sendable (ParsedQuery) -> [String] { { q in q.devices.contains(d) ? [] : ["device isn't \(d)"] } }
    static func place(_ p: String) -> @Sendable (ParsedQuery) -> [String] { { q in q.locations.contains(p) ? [] : ["not in \(p)"] } }
    static let downloaded: @Sendable (ParsedQuery) -> [String] = { q in q.anySource || !q.sourceKeys.isEmpty ? [] : ["not marked downloaded"] }

    /// Every look chip should read like a thing ("car"), not a sentence ("photos of my car taken with my canon").
    static func tidyChips(_ q: ParsedQuery) -> [String] {
        let kindWords: Set<String> = ["photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot", "screenshots", "my", "a", "the"]
        return q.looks.compactMap { l in
            let w = l.word.split(separator: " ").map(String.init)
            return w.count > 3 || w.contains(where: kindWords.contains) ? "untidy look “\(l.word)”" : nil
        }
    }

    static func all(_ checks: (@Sendable (ParsedQuery) -> [String])...) -> @Sendable (ParsedQuery) -> [String] {
        { q in checks.flatMap { $0(q) } }
    }

    // MARK: The sentences

    static let cases: [Case] = [
        // Things in pictures, said loosely
        Case("there's a photo of a tiger I downloaded a few days ago", all(looks("tiger"), date("Past week"), downloaded)),
        Case("that picture of my dog at the beach", all(looks("dog"), looks("beach"), noDate)),
        Case("the restaurant bill from dinner last week", all(looks("receipt", "bill"), date("Last week"))),
        Case("a screenshot of a bar chart I took the other day", all(screenshots, looks("chart", "bar chart"), date("Past week"))),
        Case("photo of the sunset I took on my iPhone", all(looks("sunset", "sunset_sunrise"), device("iphone"))),
        Case("the handwritten notes I scanned a while back", all(looks("handwriting", "handwritten"))),
        Case("a picture of a big striped cat sleeping on the sofa", all(looks("cat"), noSize, noLook("sleeping"))),
        Case("that image of snowy mountains I saved in my downloads", all(looks("mountain", "snow"), place("Downloads"))),
        Case("photos of people around a whiteboard from last week", all(looks("whiteboard"), date("Last week"))),
        Case("a selfie with my friends at a wedding", all(kind(.images), looks("wedding"))),
        Case("pictures of food from my trip to Japan", all(looks("food"), noLook("japan"))),
        Case("a photo where my kid is holding a balloon", all(looks("balloon"))),
        Case("the scanned receipt from the hardware store", all(looks("receipt"))),
        Case("that meme with the cat wearing sunglasses", all(looks("cat"), looks("sunglasses"))),
        Case("a diagram of the database schema I drew", all(looks("diagram", "chart"))),
        Case("photos of my car taken with my Canon", all(looks("car"), device("canon"), noLook("canon"))),
        Case("I'm looking for the picture of a waterfall we saw on holiday", all(looks("waterfall"))),
        Case("where is that pic of the birthday cake from last month", all(looks("cake", "birthday cake"), date("Last month"))),
        Case("some pdf with a picture of a lighthouse on the front page", all(ext("pdf"), looks("lighthouse"))),
        Case("the gif of a dancing baby", all(ext("gif"), looks("baby"))),
        Case("an old photo of my grandparents' house in the village", all(looks("house"))),
        Case("a photo of a cozy coffee shop interior", all(looks("coffee shop", "cafe", "coffee"))),
        Case("the photo I took at the concert a couple of weeks ago", all(looks("concert"), date("Past month"))),

        // Colours: only when the whole thing is mostly that colour
        Case("the menu from the cafe with a green background", all(colour("green"))),
        Case("find me the photo of a red car parked on the street", all(looks("car"), noColour, noLook("parked"))),
        Case("the pdf where the cover page is blue", all(ext("pdf"), colour("blue"))),

        // Not about how something looks
        Case("screenshots of a dark mode app", all(screenshots, notKind(.apps), colour("black"), noLook("dark mode"))),
        Case("slides about our quarterly revenue", all(ext("pptx"), word("revenue"), noLook("revenue"))),
        Case("the document about my car insurance renewal", all(kind(.documents), word("insurance"), noLook("car"))),
        Case("that clip of fireworks from new year's eve", all(kind(.videos), noDate)),
        Case("the presentation I was working on the other day", all(ext("key"), date("Past week"))),
        Case("huge video files I haven't opened in a year", all(kind(.videos), { q in q.before == nil ? ["not 'untouched for a year'"] : [] })),
    ]

    @Test(arguments: cases)
    func sentence(_ c: Case) async throws {
        var q = QueryParser.parse(c.text)
        let t0 = Date()
        let r = await SentenceUnderstanding.refine(c.text)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if let r { q = QueryParser.merge(q, r, dismissed: []) }
        let problems = (r == nil ? ["Apple Intelligence gave no usable answer"] : []) + (ms > 10_000 ? ["took \(ms / 1000) s"] : []) + Self.tidyChips(q) + c.check(q)
        let chips = q.chips.map { "[\($0.kind.rawValue)\($0.isGuess ? "✦" : ""): \($0.label)]" }.joined(separator: " ")
        print("\(problems.isEmpty ? "PASS" : "FAIL") \(ms)ms “\(c.text)” → \(chips)\(problems.isEmpty ? "" : "  ✗ " + problems.joined(separator: "; "))")
        #expect(problems.isEmpty, "\(problems.joined(separator: "; ")) — got \(chips)")
    }
}
