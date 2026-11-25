import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads a finished voice note once, the way a person would: "Tag it under clawed… not cloth" was "Claude";
/// "tag it design, scratch that, make it animation" is #animation; "put it in SigmaFlow, actually no, Personal
/// branding" goes to Personal branding. Uses Apple Intelligence where the Mac has it, else the downloaded
/// on-device model, else only the rules in `CaptureTags` / `SpokenIntent`.
///
/// The model is only ever asked small questions: code finds the places a name may have been misheard and asks
/// "which did they say?"; it's asked what was requested only when the note mentions a tag or a collection; and
/// every answer is checked against the words before it's used. Small models stay right that way.
enum NoteUnderstanding {

    struct Result: Equatable {
        var note: String
        /// (heard, meant), in the order they were applied.
        var fixes: [Fix] = []
        /// Tags the model says were asked for (already checked against the words).
        var tags: [String] = []
        /// Tags or collections the person took back.
        var tookBack: [String] = []
        /// An existing collection they finally asked for.
        var collection: String?
        /// Names the person corrected out loud, worth listening for next time.
        var learned: [String] = []
    }

    struct Fix: Equatable { var heard: String; var meant: String }

    /// What the model says was asked for, before checking.
    struct Asks: Equatable, Sendable {
        var asksForTags = false
        var tookBack: [String] = []
        var tags: [String] = []
        var asksForCollection = false
        var collection = ""
    }

    // MARK: Engines

    protocol Reader: Sendable {
        /// true when `meant` was said and `heard` is a mishearing.
        func isName(note: String, heard: String, meant: String) async -> Bool?
        func asks(note: String, collections: [String]) async -> Asks?
    }

    /// Apple Intelligence when it's on, else the downloaded model, else nothing.
    @MainActor
    static func reader() -> Reader? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SentenceUnderstanding.status == .available { return AppleReader() }
        #endif
        if LocalModel.shared.isReady { return LocalReader() }
        return nil
    }

    // MARK: Prompts (shared by both engines)

    static let nameInstructions = "Speech recognition sometimes writes a name as a similar-sounding word. You decide whether that happened."

    static func namePrompt(note: String, heard: String, meant: String) -> String {
        """
        Note: "\(note)"

        Speech recognition wrote "\(heard)". This person often says "\(meant)" (an app, tag or collection they use), \
        and the two sound alike.
        Which did they most likely say here? "as written" if "\(heard)" is an ordinary word that fits the sentence; \
        "the name" if "\(meant)" fits better, for example right after "tag it", or as something they use or talk about.
        """
    }

    static let asksInstructions = """
    You read a voice note a person said while saving something from their screen. People correct themselves out loud \
    the way they would with a friend ("not cloth, Claude", "scratch that, make it…", "I mean…", "no wait…", "never mind"). \
    Say what they finally asked for.
    """

    static func asksPrompt(note: String, collections: [String]) -> String {
        """
        Their collections: \(collections.isEmpty ? "(none yet)" : collections.joined(separator: ", "))
        Voice note: "\(note)"

        asksForTags: do they ask to tag it ("tag it …", "tag it under …", "hashtag …", "label this as …")? Talking about "a tag" is not asking.
        tookBack: tags or collections they said and then took back or said were wrong.
        tags: the tags they finally want, lowercase, one or two words each. Empty if asksForTags is false.
        asksForCollection: do they ask to save, put or add it in one of their collections?
        collection: that collection, spelled as in their collections. "" if asksForCollection is false.
        """
    }

    // MARK: Reading a note

    /// "tag it", "#design", "label this", "hashtag".
    static func asksForTag(_ text: String) -> Bool {
        text.range(of: requestPattern, options: .regularExpression) != nil || text.range(of: #"(^|\s)#[\p{L}\d]"#, options: .regularExpression) != nil
    }

    /// Asking for a tag, not talking about one ("a tag that says…" isn't asking).
    static let requestPattern = #"(?i)(?<!\ba\s)(?<!\bthe\s)(?<!\bone\s)\b(?:tag(?:ged)?|label(?:led)?)\s+(?:it|this|that|them|under|as)\b|\bhashtag\b"#

    /// Worth asking about: it mentions tags, a collection, or one of the person's collections by name.
    static func mentionsFiling(_ text: String, collections: [String]) -> Bool {
        if asksForTag(text) { return true }
        if text.range(of: #"(?i)\bcollections?\b"#, options: .regularExpression) != nil { return true }
        let t = PersonalWords.squash(text)
        return collections.contains { let c = PersonalWords.squash($0); return c.count >= 3 && t.contains(c) }
    }

    /// The whole reading. `typed` notes weren't heard by speech recognition, so no names are "fixed" in them.
    static func understand(note: String, typed: Bool, words: [String], collections: [String], reader: Reader?) async -> Result {
        var r = Result(note: note)
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return r }

        // 1. Misheard names: spacing-only ones are certain; sound-alikes are asked about. An ordinary word
        //    ("clawed", "cloth") only becomes a name where a name goes: "tag it under clawed", "put it in…".
        if !typed {
            for c in PersonalWords.candidates(in: note, words: words) {
                if c.spellingOnly {
                    r.fixes.append(Fix(heard: c.heard, meant: c.meant))
                    continue
                }
                let ordinary = await isOrdinary(c.heard)
                // An ordinary word only becomes a name where a name goes ("tag it under clawed"); never
                // "when it was priced low" → an app called Wispr Flow. Two ordinary words never swap
                // ("do designs" isn't a mishearing of the tag "design").
                if ordinary, !inNamingSpot(c.heard, in: note) { continue }
                if ordinary, await isOrdinary(c.meant) { continue }
                guard let reader else {
                    // No model on this Mac: only the certain ones. A non-word, where a name goes, that sounds and
                    // is spelled almost the same ("tag it under obsidion", "tag it Claud").
                    if !ordinary, inNamingSpot(c.heard, in: note),
                       PersonalWords.similarity(PersonalWords.sound(c.heard), PersonalWords.sound(c.meant)) >= 0.8,
                       PersonalWords.similarity(PersonalWords.squash(c.heard), PersonalWords.squash(c.meant)) >= 0.75 {
                        r.fixes.append(Fix(heard: c.heard, meant: c.meant))
                    }
                    continue
                }
                if await reader.isName(note: note, heard: c.heard, meant: c.meant) == true {
                    r.fixes.append(Fix(heard: c.heard, meant: c.meant))
                }
            }
            for f in r.fixes { r.note = PersonalWords.replace(f.heard, with: f.meant, in: r.note) }
        }

        // 2. Names corrected out loud ("it's not cloth, it's Claude") are worth listening for next time.
        for (wrong, right) in CaptureTags.corrections(in: r.note)
        where PersonalWords.similarity(PersonalWords.sound(wrong), PersonalWords.sound(right)) >= 0.6 {
            r.learned.append(spelling(of: right, in: r.note))
        }

        // 3. What was asked for. The rules read plain requests ("tag it design") right on their own; the model
        //    only gets a say when the person corrected themselves, which is where rules can't keep up.
        //    Even then a model tag must sit right after "tag it" or the correction, and be in the words.
        guard let reader, hasCorrection(r.note), mentionsFiling(r.note, collections: collections),
              let a = await reader.asks(note: r.note, collections: collections) else { return r }
        let pairs = CaptureTags.corrections(in: r.note)
        let rightOnes = pairs.map(\.right), wrongOnes = pairs.map(\.wrong) + CaptureTags.rejected(in: r.note)
        var tags: [String] = []
        if a.asksForTags, asksForTag(r.note) {
            tags = a.tags.compactMap { cleanTag($0) }.filter { t in
                grounded(t, in: r.note) && afterCue(t, in: r.note) && !wrongOnes.contains { CaptureTags.same($0, t) }
                    && !collections.contains { CaptureTags.same($0, t) }   // "put it in Personal branding" is a place, not a tag
            }
        }
        r.tags = tags
        // Taken back only if a correction really comes after it, and it isn't what they corrected *to*.
        r.tookBack = a.tookBack.compactMap { cleanTag($0) }.filter { t in
            grounded(t, in: r.note) && correctionFollows(t, in: r.note)
                && !tags.contains { CaptureTags.same($0, t) } && !rightOnes.contains { CaptureTags.same($0, t) }
        }
        if a.asksForCollection {
            let named = PersonalWords.squash(a.collection)
            let text = PersonalWords.squash(r.note)
            r.collection = collections.first { PersonalWords.squash($0) == named && !named.isEmpty && text.contains(named) }
            // Not one they then took back ("add it to the wedding. Hmm, no, … the newsletter").
            if let c = r.collection, correctionFollows(c, in: r.note), !inLastRequest(c, in: r.note) { r.collection = nil }
        }
        return r
    }

    /// "not", "scratch that", "I mean", "wait", "never mind"…: the person changed their mind somewhere.
    static func hasCorrection(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(not|no|don['’]?t|scratch\s+that|actually|instead|i\s+mean|i\s+meant|wait|never\s?mind|sorry|rather|make\s+(?:it|that)|change\s+(?:it|that))\b"#,
                   options: .regularExpression) != nil
    }

    /// The tag comes within a few words after "tag it", "hashtag", or a correction ("no wait, Paper", "it's Claude").
    static func afterCue(_ tag: String, in text: String) -> Bool {
        let words = tag.split(separator: "-").map { NSRegularExpression.escapedPattern(for: String($0)) }
        let tagPattern = words.joined(separator: #"[\s-]*"#) + #"(?:e?s)?(?![\p{L}\d])"#
        let cue = #"(?:\b(?:tag(?:ged)?|label(?:led)?)\s+(?:it|this|them)|\bhashtag|\bnot|\bno|\bwait|\bmean|\bmeant|\binstead|\bactually|\bsorry|\brather|\bmake\s+(?:it|that)|\bit['’]?s)"#
        let p = "(?i)" + cue + #"[^\p{L}\d]+(?:[\p{L}\d'’]+[^\p{L}\d]+){0,3}"# + tagPattern
        return text.range(of: p, options: .regularExpression) != nil
    }

    /// The name is in the last "put/save/add it in …" request of the note.
    static func inLastRequest(_ name: String, in text: String) -> Bool {
        let p = #"(?i)\b(?:add|save|put|file|keep|move)\s+(?:it|this|that)\s+(?:to|in|into|under|with)\b"#
        guard let re = try? NSRegularExpression(pattern: p),
              let last = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let r = Range(last.range, in: text) else { return false }
        return text[r.upperBound...].range(of: name, options: .caseInsensitive) != nil
    }

    /// "design" in "tag it design. Scratch that, …": a correction comes after the word's last mention.
    static func correctionFollows(_ tag: String, in text: String) -> Bool {
        let key = tag.replacingOccurrences(of: "-", with: " ")
        guard let last = text.range(of: key, options: [.caseInsensitive, .backwards]) else { return false }
        return hasCorrection(String(text[last.upperBound...]))
    }

    /// Right after "tag it (under/as)", "hashtag", or "put/save/add it in/to (the)": where people say names.
    static func inNamingSpot(_ heard: String, in text: String) -> Bool {
        let p = #"(?i)(?:\b(?:tag(?:ged)?|label(?:led)?)\s+(?:it|this|that)?\s*(?:as|under|with)?|\bhashtag|\b(?:put|save|add|file|move|keep)\s+(?:it|this|that)\s+(?:in|into|to|under|with)(?:\s+(?:the|my|our))?|\bnot|\bit['’]?s|\bi\s+mean)\s+"#
            + NSRegularExpression.escapedPattern(for: heard) + #"(?![\p{L}\d])"#
        return text.range(of: p, options: .regularExpression) != nil
    }

    /// Spelled right in the dictionary ("clawed", "cloth"), as opposed to "Parker find".
    @MainActor
    static func isOrdinary(_ words: String) -> Bool {
        let checker = NSSpellChecker.shared
        return words.split(separator: " ").allSatisfy { w in
            let s = String(w).lowercased()
            return checker.checkSpelling(of: s, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }

    /// "Tag it under hero section" → "hero-section"; nil for "it", "not", "tag".
    static func cleanTag(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"(?i)^(?:#|(?:tag|label|hashtag)\s+(?:it|this|that)?\s*(?:as|under|with)?\s*)"#,
                                   with: "", options: .regularExpression)
        guard let t = CaptureTags.normalize(s), !["tag", "tags", "hashtag", "label", "not", "no", "none", "nothing"].contains(t) else { return nil }
        return t
    }

    /// Every word of the tag is in the note (plurals and spacing aside): the model can't invent tags.
    static func grounded(_ tag: String, in text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let squashed = PersonalWords.squash(text)
        return tag.split(separator: "-").allSatisfy { p in
            words.contains { CaptureTags.same($0, String(p)) }
        } || (tag.count >= 4 && squashed.contains(tag.replacingOccurrences(of: "-", with: "")))
    }

    /// The word as it's written in the note ("Claude", not "claude").
    private static func spelling(of word: String, in text: String) -> String {
        guard let r = text.range(of: word, options: .caseInsensitive) else { return word }
        return String(text[r])
    }

    // MARK: Putting it on a capture

    /// Reads the capture's note and files it by what it really says. Never touches tags added by hand.
    @MainActor
    static func refine(_ c0: Capture) async -> Capture {
        var c = c0
        guard !c.note.isEmpty else { return c }
        let lib = CaptureLibrary.shared
        let collections = lib.collections.map(\.name)
        let r = await understand(note: c.note, typed: c.noteTyped, words: PersonalWords.all(), collections: collections, reader: reader())
        if r.note != c.note {
            if c.noteHeard == nil { c.noteHeard = c.note }
            c.note = r.note
        }
        c.refileTags(text: c.note, existing: lib.tagNames, mentionable: lib.establishedTagNames, asked: r.tags, takenBack: r.tookBack)
        // Only a collection that came from the words can be changed by the words.
        let fromWords = c.collection == nil || c.collectionPhrase != nil
        if fromWords {
            if let col = r.collection {
                if c.collection != col { c.collection = col; c.collectionPhrase = col }
            } else if let current = c.collection, r.tookBack.contains(where: { CaptureTags.same($0, current) }) {
                c.collection = nil; c.collectionPhrase = nil
            }
        }
        for w in r.learned { PersonalWords.learn(w) }
        return c
    }
}

// MARK: - Apple Intelligence

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable(description: "Which word the person said")
struct NameCheck {
    @Guide(description: "\"as written\" or \"the name\"", .anyOf(["as written", "the name"]))
    var said: String
}

@available(macOS 26.0, *)
@Generable(description: "What the person finally asked for in a voice note")
struct NoteAsks {
    var asksForTags: Bool
    @Guide(description: "Tags or collections they took back", .maximumCount(4))
    var tookBack: [String]
    @Guide(description: "The tags they finally want, lowercase, one or two words each", .maximumCount(4))
    var tags: [String]
    var asksForCollection: Bool
    @Guide(description: "The collection, spelled as in their collections, or empty")
    var collection: String
}

@available(macOS 26.0, *)
struct AppleReader: NoteUnderstanding.Reader {
    func isName(note: String, heard: String, meant: String) async -> Bool? {
        do {
            let s = LanguageModelSession(instructions: NoteUnderstanding.nameInstructions)
            let r = try await s.respond(to: NoteUnderstanding.namePrompt(note: note, heard: heard, meant: meant),
                                        generating: NameCheck.self, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 30))
            return r.content.said == "the name"
        } catch { return nil }
    }

    func asks(note: String, collections: [String]) async -> NoteUnderstanding.Asks? {
        do {
            let s = LanguageModelSession(instructions: NoteUnderstanding.asksInstructions)
            let r = try await s.respond(to: NoteUnderstanding.asksPrompt(note: note, collections: collections),
                                        generating: NoteAsks.self, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 160))
            let a = r.content
            return .init(asksForTags: a.asksForTags, tookBack: a.tookBack, tags: a.tags,
                         asksForCollection: a.asksForCollection, collection: a.collection)
        } catch { return nil }
    }
}
#endif

// MARK: - The downloaded model

struct LocalReader: NoteUnderstanding.Reader {
    /// A model file other than the downloaded one (tests).
    var file: URL? = nil
    /// Answers can only take these shapes (llama.cpp grammar), so they always parse.
    static let nameGrammar = #"""
    root ::= "{" ws "\"said\"" ws ":" ws ( "\"as written\"" | "\"the name\"" ) ws "}"
    ws ::= [ \n]{0,3}
    """#

    static let asksGrammar = #"""
    root ::= "{" ws "\"asksForTags\"" ws ":" ws bool ws "," ws "\"tookBack\"" ws ":" ws list ws "," ws "\"tags\"" ws ":" ws list ws "," ws "\"asksForCollection\"" ws ":" ws bool ws "," ws "\"collection\"" ws ":" ws str ws "}"
    bool ::= "true" | "false"
    list ::= "[" ws ( str ( ws "," ws str ){0,3} )? ws "]"
    str ::= "\"" [^"\\\n]{0,40} "\""
    ws ::= [ \n]{0,3}
    """#

    func isName(note: String, heard: String, meant: String) async -> Bool? {
        let user = NoteUnderstanding.namePrompt(note: note, heard: heard, meant: meant) + "\nAnswer as JSON: {\"said\": …}"
        guard let s = await LocalModel.shared.respond(system: NoteUnderstanding.nameInstructions, user: user, grammar: Self.nameGrammar, maxTokens: 24, file: file),
              let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return nil }
        return (obj["said"] as? String) == "the name"
    }

    func asks(note: String, collections: [String]) async -> NoteUnderstanding.Asks? {
        let user = NoteUnderstanding.asksPrompt(note: note, collections: collections)
            + "\nAnswer as JSON with asksForTags, tookBack, tags, asksForCollection, collection."
        guard let s = await LocalModel.shared.respond(system: NoteUnderstanding.asksInstructions, user: user, grammar: Self.asksGrammar, maxTokens: 160, file: file),
              let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return nil }
        return .init(asksForTags: obj["asksForTags"] as? Bool ?? false,
                     tookBack: obj["tookBack"] as? [String] ?? [],
                     tags: obj["tags"] as? [String] ?? [],
                     asksForCollection: obj["asksForCollection"] as? Bool ?? false,
                     collection: obj["collection"] as? String ?? "")
    }
}
