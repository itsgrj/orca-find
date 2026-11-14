import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Apple Intelligence read out of a long, chatty query.
struct SentenceRefinement: Sendable, Equatable {
    struct Look: Sendable, Equatable {
        var phrase: String      // "seaside", "blue cover"
        var words: [String]     // simple nouns a photo classifier would use: ["beach", "ocean", "shore"]
    }
    var looks: [Look] = []
    var withinDays = 0
}

/// Uses the on-device Apple Intelligence model (macOS 26+) to understand sentences like
/// "there's a photo of a tiger I downloaded a few days ago". Nothing leaves the Mac.
enum SentenceUnderstanding {
    enum Status: Equatable { case available, turnedOff, notReady, unsupported }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
            case .unavailable(.modelNotReady): return .notReady
            default: return .unsupported
            }
        }
        #endif
        return .unsupported
    }

    static var statusText: String {
        switch status {
        case .available: return "Available on this Mac"
        case .turnedOff: return "Turned off in System Settings"
        case .notReady: return "Downloading — ready soon"
        case .unsupported: return "Not available on this Mac"
        }
    }

    /// Readings shared by the main window and Quick Search, keyed by the lowercased query.
    @MainActor static var cache: [String: SentenceRefinement] = [:]

    /// Worth asking only for sentence-like queries; short ones are handled instantly by the rules.
    static func worthRefining(_ text: String) -> Bool {
        let words = text.split { $0.isWhitespace || $0 == "," }.filter { !$0.isEmpty }
        return words.count >= 4
    }

    private static let instructions = """
    You help a person find a file on their Mac. Read what they typed and fill in only what they actually said; leave things empty when they didn't say them.
    """

    static func refine(_ text: String) async -> SentenceRefinement? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard status == .available else { return nil }
            do {
                let session = LanguageModelSession(instructions: instructions)
                // The answer is filled straight into `SearchReading`'s fields, so it always has the right shape,
                // and the token cap stops a runaway answer (free-text replies used to ramble for ~50 s).
                let response = try await session.respond(to: text, generating: SearchReading.self,
                                                         options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 300))
                return response.content.refinement
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// What Apple Intelligence fills in for a search sentence. Fields are generated in this order.
@available(macOS 26.0, *)
@Generable(description: "How to search for the file the person describes")
struct SearchReading {
    @Guide(description: """
    Each thing that would be visible in the picture or on the page: objects, animals, food, plants, buildings, \
    landscapes and scenes (a beach, a kitchen, a concert, a wedding), and kinds of paper such as a receipt, a menu, \
    a diagram or handwriting. One entry per thing, keeping its describing words with it ("red car", "snowy mountains", \
    "birthday cake"). Leave out actions (sleeping, holding, parked), the person and people they know, countries and \
    cities, named days and holidays, what a document is about (insurance, revenue, a project), and kinds of file \
    (photo, picture, screenshot, pdf, video, document). Empty when nothing visible is described.
    """)
    var things: [SeenThing]

    @Guide(description: """
    How many days back from today the file is from, only when the person says how long ago: \
    "a few days ago" or "the other day" = 7, "recently" = 14, "a while back" = 30, "last month" = 31. \
    0 when they don't say, and 0 for named days and holidays like "new year's eve" or "my birthday".
    """, .range(0...3650))
    var daysBack: Int

    var refinement: SentenceRefinement {
        SentenceRefinement(
            looks: things.compactMap { t in
                let phrase = Self.tidy(t.phrase)
                guard !phrase.isEmpty else { return nil }
                return SentenceRefinement.Look(phrase: phrase, words: t.labels + phrase.split(separator: " ").map(String.init))
            },
            withinDays: daysBack)
    }

    /// "photos of my car" → "car", "a photo where my kid…" → "kid…": the model sometimes copies the lead-in.
    static func tidy(_ phrase: String) -> String {
        let lead: Set<String> = ["a", "an", "the", "my", "our", "his", "her", "their", "this", "that", "some", "of", "where", "with",
                                 "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "screenshot", "screenshots",
                                 "scan", "scans", "scanned", "file", "files"]
        var words = phrase.lowercased().split(separator: " ").map(String.init)
        while let f = words.first, lead.contains(f) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}

@available(macOS 26.0, *)
@Generable
struct SeenThing {
    @Guide(description: """
    Just the thing itself: a noun with at most two describing words, in the person's own words, \
    e.g. "seaside", "red car", "bill", "balloon". Never a whole phrase like "photo of my car" or "kid holding a balloon".
    """)
    var phrase: String

    @Guide(description: """
    Simple one-word nouns a photo classifier would use for this thing, the most likely specific one first: \
    "seaside" → beach, ocean, shore; "bill" → receipt; "big striped cat" → tiger, cat.
    """, .count(1...6))
    var labels: [String]
}
#endif
