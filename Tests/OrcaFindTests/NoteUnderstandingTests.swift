import Foundation
import Testing
@testable import OrcaFind
import FluidAudio

/// Misheard names and spoken corrections, without any model.
@Suite("Notes: sounding alike")
struct SoundAlikeTests {
    let words = ["Claude", "OrcaFind", "SigmaFlow", "SigmaTimer", "Figma", "Paper", "Obsidian", "Wispr", "Dia",
                 "design", "animation", "hero section", "background", "pricing", "Personal branding", "Newsletter"]

    @Test func soundKeys() {
        #expect(PersonalWords.sound("clawed") == PersonalWords.sound("Claude"))
        #expect(PersonalWords.sound("clod") == PersonalWords.sound("Claude"))
        #expect(PersonalWords.sound("change") != PersonalWords.sound("Claude"))
    }

    @Test func findsTheMisheardName() {
        let c = PersonalWords.candidates(in: "Tag it under clawed, not target claw.", words: words)
        #expect(c.first == .init(heard: "clawed", meant: "Claude", spellingOnly: false))
        let p = PersonalWords.candidates(in: "Figure it out if this feature in Parker find is working.", words: words)
        #expect(p.contains(.init(heard: "Parker find", meant: "OrcaFind", spellingOnly: false)))
        #expect(!p.contains { $0.meant == "background" })
    }

    @Test func spacingIsFixedWithoutAsking() {
        let c = PersonalWords.candidates(in: "In the Sigma flow website as well", words: words)
        #expect(c == [.init(heard: "Sigma flow", meant: "SigmaFlow", spellingOnly: true)])
    }

    @Test func leavesOrdinaryWordsAlone() {
        #expect(PersonalWords.candidates(in: "I like the sidebar design and the hero section.", words: words).isEmpty)
        #expect(PersonalWords.candidates(in: "add this to the personal branding collection", words: words).isEmpty)
        #expect(PersonalWords.candidates(in: "Save it for the newsletter.", words: words).isEmpty)
        #expect(PersonalWords.candidates(in: "We need to change the plan.", words: words).isEmpty)
    }

    @Test func replacesWholeWordsOnly() {
        #expect(PersonalWords.replace("clawed", with: "Claude", in: "Tag it clawed. Clawed!") == "Tag it Claude. Claude!")
        #expect(PersonalWords.replace("claw", with: "Claude", in: "clawed claw") == "clawed Claude")
    }

    @Test func modelTagsMustBeInTheWords() {
        #expect(NoteUnderstanding.grounded("hero-section", in: "tag it under hero section"))
        #expect(!NoteUnderstanding.grounded("design", in: "tag it pricing"))
        #expect(NoteUnderstanding.cleanTag("tag it marketing") == "marketing")
        #expect(NoteUnderstanding.cleanTag("not") == nil)
    }

    @Test func learnsNamesCorrectedOutLoud() async {
        let r = await NoteUnderstanding.understand(note: "Tag it cloth. Hey, it's not cloth, it's Claude.", typed: false,
                                                   words: [], collections: [], reader: nil)
        #expect(r.learned == ["Claude"])
    }

    @Test func aTagThatSaysIsNotATag() {
        #expect(CaptureTags.spoken(in: "there is a tag that says whether his app has been sold").isEmpty)
    }

    @Test func pluralsAreTheSameTag() {
        #expect(CaptureTags.same("recipes", "recipe"))
        #expect(CaptureTags.same("boxes", "box"))
        #expect(CaptureTags.same("Designs", "design"))
        #expect(!CaptureTags.same("design", "designer"))
    }

    @Test func takenBackCollectionsDontCount() {
        let t = "Add it to the wedding. Hmm, no, add it to the newsletter instead."
        #expect(NoteUnderstanding.correctionFollows("Wedding", in: t))
        #expect(!NoteUnderstanding.inLastRequest("Wedding", in: t))
    }

    @Test func lastCollectionWins() {
        let i = SpokenIntent.parse("Put it in SigmaFlow. Actually no, put it in Personal branding.", existing: ["SigmaFlow", "Personal branding"])
        #expect(i.collection == "Personal branding")
    }
}

/// The 30 notes, through the whole reading: rules + model + checks. Run with
/// `ORCA_EVAL=apple swift test --filter NoteReadingEval` or `ORCA_EVAL=local ORCA_EVAL_MODEL=/path/model.gguf …`.
@Suite("Notes: reading eval", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORCA_EVAL"] != nil))
struct NoteReadingEval {
    struct Case: CustomTestStringConvertible, Sendable {
        let name, note: String
        let fixes: [[String]]
        let tags: [String]
        let collection: String
        var testDescription: String { name }
    }

    static let words = ["Claude", "OrcaFind", "SigmaFlow", "SigmaTimer", "Figma", "Paper", "Obsidian", "Wispr", "Dia",
                        "design", "animation", "hero section", "background", "pricing"]
    static let collections = ["SigmaFlow", "Personal branding", "Newsletter", "Wedding"]

    static let cases: [Case] = [
        .init(name: "real: clawed", note: "Remember this prompt for any time that I am creating any AI app and I want the Figma file to accurately reflect each and every change that I do to the app. Tag it under clawed. Tag it under clawed, not target claw, not cloth.", fixes: [["clawed", "Claude"]], tags: ["claude"], collection: ""),
        .init(name: "its not X its Y", note: "Tag it cloth. Hey, it's not cloth, it's Claude.", fixes: [], tags: ["claude"], collection: ""),
        .init(name: "scratch that", note: "Tag it design. Scratch that, make it animation.", fixes: [], tags: ["animation"], collection: ""),
        .init(name: "wait no", note: "Tag it pricing. Wait, no, tag it marketing instead.", fixes: [], tags: ["marketing"], collection: ""),
        .init(name: "collection change", note: "Love this layout. Put it in SigmaFlow. Actually no, put it in Personal branding.", fixes: [], tags: [], collection: "Personal branding"),
        .init(name: "real: Parker find", note: "Figure it out if this feature in Parker find is working or not.", fixes: [["Parker find", "OrcaFind"]], tags: [], collection: ""),
        .init(name: "real: a tag that says", note: "I absolutely love how he has designed his Twitter cover image where he has the icons of all the apps that he has developed, and also there is a tag that says whether his app has been sold or not.", fixes: [], tags: [], collection: ""),
        .init(name: "real: Sigma flow", note: "I like how they have used all the company logos as keys in this keyboard. In the Sigma flow website as well I need to have a section that looks exactly like this.", fixes: [["Sigma flow", "SigmaFlow"]], tags: [], collection: "SigmaFlow"),
        .init(name: "two tags", note: "Tag it design and pricing.", fixes: [], tags: ["design", "pricing"], collection: ""),
        .init(name: "hashtag + collection", note: "Hashtag motion. Save it for the newsletter.", fixes: [], tags: ["motion"], collection: "Newsletter"),
        .init(name: "not asked, mentions not", note: "This is not really about design, it's more about how they explain pricing.", fixes: [], tags: [], collection: ""),
        .init(name: "gift idea", note: "Tag it as gift idea, this would be perfect for mom.", fixes: [], tags: ["gift-idea"], collection: ""),
        .init(name: "I mean", note: "Tag it cloth, I mean Claude.", fixes: [], tags: ["claude"], collection: ""),
        .init(name: "no wait app", note: "Tag it Figma. No wait, Paper. The app Paper.", fixes: [], tags: ["paper"], collection: ""),
        .init(name: "label not", note: "Label this as inspiration, not reference.", fixes: [], tags: ["inspiration"], collection: ""),
        .init(name: "dont tag", note: "Don't tag it design, tag it typography.", fixes: [], tags: ["typography"], collection: ""),
        .init(name: "two words", note: "Tag it under hero section.", fixes: [], tags: ["hero-section"], collection: ""),
        .init(name: "real: long no tag", note: "I really like this background. What I find very tasteful is the fact that they have managed to combine both a really good natural background and also some sort of a sci-fi techie code on top of it.", fixes: [], tags: [], collection: ""),
        .init(name: "read later + tag", note: "Read this later. Tag it AI.", fixes: [], tags: ["ai"], collection: ""),
        .init(name: "correct already", note: "I opened Claude and asked it to write the onboarding copy. Tag it copywriting.", fixes: [], tags: ["copywriting"], collection: ""),
        .init(name: "trap: real cloth", note: "The cloth on the table has a lovely texture, could work as a background.", fixes: [], tags: [], collection: ""),
        .init(name: "trap: cat clawed", note: "The cat clawed the sofa again, look at this photo.", fixes: [], tags: [], collection: ""),
        .init(name: "collection not", note: "Put it into the Wedding collection, not Newsletter.", fixes: [], tags: [], collection: "Wedding"),
        .init(name: "also tag", note: "Tag it design. Oh and also tag it motion.", fixes: [], tags: ["design", "motion"], collection: ""),
        .init(name: "app tag", note: "Tag it under Obsidian, it's for my note taking research.", fixes: [], tags: ["obsidian"], collection: ""),
        .init(name: "Sigma timer", note: "Tag it under Sigma timer.", fixes: [["Sigma timer", "SigmaTimer"]], tags: ["sigmatimer"], collection: ""),
        .init(name: "misheard collection", note: "Save this to sigma flow, the pricing section looks great.", fixes: [["sigma flow", "SigmaFlow"]], tags: [], collection: "SigmaFlow"),
        .init(name: "real: plain design", note: "I like the sidebar design. It is able to cram up a lot of things but at the same time it looks clean.", fixes: [], tags: [], collection: ""),
        .init(name: "never mind tag", note: "Tag it pricing. Actually never mind, no tag.", fixes: [], tags: [], collection: ""),
        .init(name: "real: personal branding", note: "I really like this animation on this website. Please add this to the personal branding collection.", fixes: [], tags: [], collection: "Personal branding"),
    ]


    /// Written after tuning and never tuned against: the honest score.
    static let holdout: [Case] = [
        .init(name: "h: rather", note: "Tag it travel, or rather tag it vacation.", fixes: [], tags: ["vacation"], collection: ""),
        .init(name: "h: correction mid", note: "Hashtag recipes, no, hashtag desserts.", fixes: [], tags: ["desserts"], collection: ""),
        .init(name: "h: three plain", note: "Tag it fonts, colors and layout.", fixes: [], tags: ["fonts", "colors", "layout"], collection: ""),
        .init(name: "h: misheard tag obsidian", note: "Tag it under obsidion please.", fixes: [["obsidion", "Obsidian"]], tags: ["obsidian"], collection: ""),
        .init(name: "h: figure not figma", note: "I can't figure out how they did this shadow.", fixes: [], tags: [], collection: ""),
        .init(name: "w: whisper", note: "Save this one for Wispr, tag it under whisper.", fixes: [["whisper", "Wispr"]], tags: ["wispr"], collection: ""),
        .init(name: "h: change collection", note: "Add it to the wedding. Hmm, no, add it to the newsletter instead.", fixes: [], tags: [], collection: "Newsletter"),
        .init(name: "h: not about", note: "Not a design thing really, just a funny meme.", fixes: [], tags: [], collection: ""),
        .init(name: "h: label as", note: "Label this as onboarding.", fixes: [], tags: ["onboarding"], collection: ""),
        .init(name: "h: tags word in sentence", note: "The price tags on this store page are really clear.", fixes: [], tags: [], collection: ""),
        .init(name: "h: make that", note: "Tag it blue. Make that purple.", fixes: [], tags: ["purple"], collection: ""),
        .init(name: "h: claud", note: "Tag it Claud, this is the prompt I used.", fixes: [["Claud", "Claude"]], tags: ["claude"], collection: ""),
        .init(name: "h: cloud real", note: "The cloud illustration in the hero is lovely.", fixes: [], tags: [], collection: ""),
        .init(name: "h: sigma flow tag", note: "Tag it Sigma Flow and put it in the Sigma Flow collection.", fixes: [["Sigma Flow", "SigmaFlow"]], tags: ["sigmaflow"], collection: "SigmaFlow"),
        .init(name: "h: no tag at all", note: "Just saving this for later, nothing special.", fixes: [], tags: [], collection: ""),
        .init(name: "h: sorry", note: "Tag it pricing, sorry, packaging.", fixes: [], tags: ["packaging"], collection: ""),
        .init(name: "h: tagged as", note: "This should be tagged as competitor.", fixes: [], tags: ["competitor"], collection: ""),
        .init(name: "h: dia app", note: "I saw this in Dia, tag it browser.", fixes: [], tags: ["browser"], collection: ""),
        .init(name: "h: dear trap", note: "Dear me, this layout is so clean.", fixes: [], tags: [], collection: ""),
        .init(name: "h: both changes", note: "Tag it icons and put it in Wedding. Actually, put it in Personal branding, and tag it logos not icons.", fixes: [], tags: ["logos"], collection: "Personal branding"),
    ]

    @Test(arguments: holdout)
    @MainActor func holdoutReading(_ c: Case) async { await reading(c) }

    static var reader: NoteUnderstanding.Reader? {
        let env = ProcessInfo.processInfo.environment
        switch env["ORCA_EVAL"] {
        case "apple":
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { return AppleReader() }
            #endif
            return nil
        case "local": return LocalReader(file: env["ORCA_EVAL_MODEL"].map { URL(fileURLWithPath: $0) })
        default: return nil
        }
    }

    static func squash(_ s: String) -> String { PersonalWords.squash(s) }

    @Test(arguments: cases)
    @MainActor func reading(_ c: Case) async {
        let start = Date()
        let r = await NoteUnderstanding.understand(note: c.note, typed: false, words: Self.words, collections: Self.collections, reader: Self.reader)
        var cap = Capture(id: "eval", created: Date())
        cap.note = r.note
        cap.refileTags(text: r.note, existing: [], asked: r.tags, takenBack: r.tookBack)
        var col = SpokenIntent.parse(r.note, existing: Self.collections).collection
        if let ac = r.collection { col = ac }
        else if let cc = col, r.tookBack.contains(where: { CaptureTags.same($0, cc) }) { col = nil }
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        var problems: [String] = []
        let gotFixes = Set(r.fixes.map { Self.squash($0.heard) + "→" + Self.squash($0.meant) })
        let wantFixes = Set(c.fixes.map { Self.squash($0[0]) + "→" + Self.squash($0[1]) })
        if gotFixes != wantFixes { problems.append("fixes \(r.fixes.map { "\($0.heard)→\($0.meant)" }) want \(c.fixes)") }
        if cap.tagList.sorted() != c.tags.sorted() { problems.append("tags \(cap.tagList) want \(c.tags)") }
        if Self.squash(col ?? "") != Self.squash(c.collection) { problems.append("collection '\(col ?? "")' want '\(c.collection)'") }
        print("\(problems.isEmpty ? "PASS" : "FAIL") [\(c.name)] \(ms) ms\(problems.isEmpty ? "" : "  ✗ " + problems.joined(separator: "; "))")
        #expect(problems.isEmpty, "\(c.name): \(problems)")
    }
}

/// A real recording through the speech model, with and without the person's words listened for.
/// `ORCA_AUDIO=/path/note.m4a swift test --filter SpeechWordsCheck`
@Suite("Speech: own words", .enabled(if: ProcessInfo.processInfo.environment["ORCA_AUDIO"] != nil))
struct SpeechWordsCheck {
    @Test @MainActor func listensForTheirWords() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORCA_AUDIO"]!)
        #expect(SpeechModel.shared.isReady)
        if !SpeechModel.hasListener { _ = try await CtcModels.download(to: SpeechModel.listenerDirectory) }
        let words = ProcessInfo.processInfo.environment["ORCA_WORDS"].map { $0.components(separatedBy: ",") }
            ?? PersonalWords.all().filter { !["clawed", "cloth not", "not target", "says whether"].contains($0) }
        let plain = try await SpeechModel.shared.transcribe(url)
        if ProcessInfo.processInfo.environment["ORCA_DEFAULT_THRESHOLDS"] != nil { SpeechModel.thresholds = .default }
        let start = Date()
        let boosted = try await SpeechModel.shared.transcribe(url, words: words)
        print("WORDS \(words.count): \(words.prefix(12))…")
        print("NEAR \(PersonalWords.candidates(in: plain, words: words, max: 10).map { "\($0.heard)→\($0.meant)" })")
        print("PLAIN   \(plain)")
        print("BOOSTED \(boosted)  (\(Int(Date().timeIntervalSince(start) * 1000)) ms)")
    }
}
