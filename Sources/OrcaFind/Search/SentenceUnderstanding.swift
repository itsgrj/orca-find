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
    You turn a person's request to find a file on their Mac into search filters. Reply with JSON only, no prose, with keys:
    looksLike (array of short phrases for what the file visually shows: objects, animals, scenes, documents like receipts; keep colour words in the phrase, e.g. "blue cover"; empty if nothing visual),
    visualWords (object: for each looksLike phrase, 4-6 simple single-word nouns a photo classifier would use for it, most likely specific thing first, e.g. "seaside": ["beach","ocean","sea","shore","water","sand"], "bill": ["receipt","document"]; when a description names an animal or object only indirectly, put its most likely name first),
    withinDays (integer days back the file is from; "a few days ago" = 7, "the other day" = 7, "last month" = 31, "recently" = 14; 0 if no time is mentioned).
    Only use what the person said. Ignore the person themselves ("me", "I") and file kinds like photo, image, pdf, video.
    """

    static func refine(_ text: String) async -> SentenceRefinement? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard status == .available else { return nil }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: text, options: GenerationOptions(sampling: .greedy))
                return parse(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    static func parse(_ raw: String) -> SentenceRefinement? {
        var s = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") { s = String(s[a...b]) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return nil }
        var out = SentenceRefinement()
        let phrases = (obj["looksLike"] as? [String]) ?? []
        let words = (obj["visualWords"] as? [String: [String]]) ?? [:]
        out.looks = phrases.map { p in SentenceRefinement.Look(phrase: p, words: (words[p] ?? []) + p.split(separator: " ").map(String.init)) }
        out.withinDays = (obj["withinDays"] as? Int) ?? Int((obj["withinDays"] as? Double) ?? 0)
        return out
    }
}
