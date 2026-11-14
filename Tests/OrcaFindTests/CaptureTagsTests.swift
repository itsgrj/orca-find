import Foundation
import Testing
@testable import OrcaFind

/// Tag rules that don't need Apple Intelligence: spelling, reuse, what's never a tag.
@Suite("Captures: tag rules")
struct CaptureTagRuleTests {
    @Test func spelling() {
        #expect(CaptureTags.normalize("#Landing Page!") == "landing-page")
        #expect(CaptureTags.normalize("it") == nil)
        #expect(CaptureTags.normalize("  Gift idea ") == "gift-idea")
    }

    @Test func reusesTheLibrarySpelling() {
        #expect(CaptureTags.clean(["Designs"], collection: nil, existing: ["design"]) == ["design"])
        #expect(CaptureTags.clean(["gift idea"], collection: nil, existing: ["gift-idea"]) == ["gift-idea"])
    }

    @Test func neverTheCollectionNameOrLongPhrases() {
        #expect(CaptureTags.clean(["SigmaFlow", "design"], collection: "SigmaFlow", existing: []) == ["design"])
        #expect(CaptureTags.clean(["colour palette inspiration", "ui"], collection: nil, existing: []) == ["ui"])
    }

    @Test func kindsOfFileAreNotTopics() {
        #expect(CaptureTags.clean(["screenshot", "photo"], collection: nil, existing: []).isEmpty)
    }

    @Test func oneWordFindsTheLongerTagYouUse() {
        #expect(CaptureTags.clean(["gift"], collection: nil, existing: ["gift-idea"]) == ["gift-idea"])
        #expect(CaptureTags.clean(["read"], collection: nil, existing: ["to-read"]) == ["to-read"])
        #expect(CaptureTags.clean(["idea"], collection: nil, existing: ["gift-idea"]) == ["idea"])
        #expect(CaptureTags.clean(["design"], collection: nil, existing: ["product-design"]) == ["design"])
    }

    @Test func laterMeansAListTag() {
        #expect(CaptureTags.later(in: "read this later") == ["to-read"])
        #expect(CaptureTags.later(in: "want to try this on sunday") == ["to-try"])
        #expect(CaptureTags.later(in: "watch it tonight") == ["to-watch"])
        #expect(CaptureTags.later(in: "a pasta recipe I saw").isEmpty)
        #expect(CaptureTags.later(in: "try harder next time").isEmpty)
    }

    @Test func siteNameFromTheTitle() {
        #expect(CaptureTags.site(in: "Pricing – Linear") == "Linear")
        #expect(CaptureTags.site(in: "Senior Product Designer – Stripe Careers") == "Stripe Careers")
        #expect(CaptureTags.site(in: "10 things to do in Kyoto") == nil)
        #expect(CaptureTags.clean(["pricing", "linear"], collection: nil, existing: [], avoid: ["Linear"]) == ["pricing"])
    }

    @Test func atMostTwoAndNoRepeats() {
        #expect(CaptureTags.clean(["design", "Design", "motion", "copy"], collection: nil, existing: []) == ["design", "motion"])
    }

    @Test func spokenTags() {
        #expect(CaptureTags.spoken(in: "tag it design and pricing").map(\.tag) == ["design", "pricing"])
        #expect(CaptureTags.spoken(in: "save this #onboarding").map(\.tag) == ["onboarding"])
    }
}

/// Real captures through Apple's on-device model. Each answer must be quick, short and sensible.
@Suite("Captures: AppleModel tag suggestions", .serialized, .enabled(if: SentenceUnderstanding.status == .available))
struct CaptureTagsTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var note = ""
        var title: String
        var ocr = ""
        var collection: String? = nil
        var existing: [String] = []
        var wantAny: [String] = []       // at least one of these (empty = anything sensible, or nothing)
        var never: [String] = []         // site, app, collection or brand names, and existing tags that don't fit
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "recipe", title: "Creamy garlic pasta in 20 minutes",
             ocr: "Ingredients 200g spaghetti 4 cloves garlic 1 cup cream parmesan salt pepper Method boil the pasta",
             existing: ["design", "recipe", "travel"], wantAny: ["recipe", "cooking", "food"], never: ["design", "travel"]),
        Case(name: "design shot", note: "love the colour palette here", title: "Analytics dashboard UI – Dribbble",
             collection: "SigmaFlow", existing: ["design", "pricing"], wantAny: ["design"], never: ["sigmaflow", "dribbble", "pricing"]),
        Case(name: "pricing page", note: "compare their pricing tiers", title: "Pricing – Linear",
             ocr: "Free $0 Standard $8 per user/month Plus $14 per user/month Enterprise contact sales",
             existing: ["design", "pricing"], wantAny: ["pricing"], never: ["linear", "design"]),
        Case(name: "gift", note: "gift for mom's birthday", title: "Handmade ceramic mug – Etsy",
             existing: ["gift-idea", "design"], wantAny: ["gift-idea"], never: ["etsy", "design"]),
        Case(name: "read later", note: "read this later", title: "The case for slow software — an essay",
             existing: ["to-read", "design"], wantAny: ["to-read"], never: ["design"]),
        Case(name: "job post", title: "Senior Product Designer – Stripe Careers",
             ocr: "We're hiring a senior product designer. Remote. Apply now. Requirements 5+ years",
             existing: ["job", "design"], wantAny: ["job", "jobs", "career", "hiring"], never: ["stripe"]),
        Case(name: "travel", title: "10 things to do in Kyoto",
             ocr: "Fushimi Inari shrine, Arashiyama bamboo grove, Kinkaku-ji temple, Gion at night",
             existing: ["travel", "recipe"], wantAny: ["travel"], never: ["recipe"]),
        Case(name: "workout", title: "12-minute full-body HIIT workout — YouTube",
             wantAny: ["fitness", "workout", "exercise", "hiit"], never: ["youtube"]),
        Case(name: "meme", note: "haha", title: "Screenshot", ocr: "when the code works on the first try and you don't know why",
             wantAny: ["funny", "humor", "humour", "meme", "memes", "programming", "coding"]),
        Case(name: "nothing to go on", title: "Screenshot", never: ["screenshot"]),
        Case(name: "unrelated existing tags", note: "this sofa would fit the living room", title: "Linen 3-seater sofa – IKEA",
             existing: ["design", "pricing", "motion", "copy"], wantAny: ["furniture", "home", "home-decor", "interior", "interiors", "decor", "sofa", "shopping"],
             never: ["ikea", "design", "pricing", "motion", "copy"]),
        Case(name: "privacy page", title: "Privacy Policy – Notion",
             ocr: "We collect information you provide. We use cookies. You can ask us to delete your data.",
             existing: ["design"], never: ["notion", "design", "privacy-policy", "policy"]),
        Case(name: "spoken topic", note: "use this for the onboarding redesign", title: "Welcome screens – Mobbin",
             existing: ["onboarding", "pricing"], wantAny: ["onboarding"], never: ["mobbin", "pricing"]),
        Case(name: "long page", note: "", title: "Terms of Service – Acme",
             ocr: String(repeating: "By using the service you agree to these terms. We may change them at any time. ", count: 20),
             never: ["acme", "service", "terms"]),
        Case(name: "motion reference", note: "nice easing on this menu", title: "Menu animation — Twitter",
             collection: "Newsletter", existing: ["motion", "design", "copy"], wantAny: ["motion", "animation"],
             never: ["twitter", "newsletter", "copy"]),
    ]

    @Test(arguments: cases)
    func suggestion(_ c: Case) async {
        let start = Date()
        let tags = await CaptureTags.suggest(note: c.note, title: c.title, ocr: c.ocr, collection: c.collection, existing: c.existing)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        var problems: [String] = []
        if ms > 8000 { problems.append("took \(ms) ms") }
        if tags.count > 2 { problems.append("more than two tags") }
        for t in tags {
            if t.split(separator: "-").count > 2 { problems.append("long tag \(t)") }
            if c.never.contains(where: { CaptureTags.same($0, t) }) { problems.append("used \(t)") }
        }
        if !c.wantAny.isEmpty, !tags.contains(where: { t in c.wantAny.contains { CaptureTags.same($0, t) } }) {
            problems.append("wanted one of \(c.wantAny)")
        }
        print("\(problems.isEmpty ? "PASS" : "FAIL") [\(c.name)] \(ms) ms → \(tags)\(problems.isEmpty ? "" : "  ✗ " + problems.joined(separator: "; "))")
        #expect(problems.isEmpty, "\(c.name): \(problems) → \(tags)")
    }
}
