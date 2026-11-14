import Foundation
import Testing
@testable import OrcaFind

/// How typed searches turn into chips, using only the built-in rules (no Apple Intelligence).
/// Every case runs against a fixed "now" so dates don't drift: Monday 9 November 2026, 15:00.
@Suite("Search: built-in rules")
struct QueryParserTests {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()
    static let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 15))!

    func parse(_ text: String) -> ParsedQuery { QueryParser.parse(text, now: Self.now, calendar: Self.cal) }
    func label(_ q: ParsedQuery, _ kind: QueryChip.Kind) -> String? { q.chips.first { $0.kind == kind }?.label }
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date { Self.cal.date(from: DateComponents(year: y, month: m, day: d))! }

    // MARK: Kinds of file

    @Test func pdfsFromLastWeek() {
        let q = parse("pdfs from last week")
        #expect(q.extensions == ["pdf"])
        #expect(label(q, .date) == "Last week")
        #expect(q.after == day(2026, 11, 1))   // weeks start on Sunday in en_US
        #expect(q.terms.isEmpty)
    }

    @Test func screenshotsYesterday() {
        let q = parse("screenshots from yesterday")
        #expect(q.screenshots)
        #expect(label(q, .type) == "Screenshots")   // no separate "Images" chip
        #expect(label(q, .date) == "Yesterday")
        #expect(q.after == day(2026, 11, 8) && q.before == day(2026, 11, 9))
    }

    @Test func spreadsheetsOlderThanSixMonths() {
        let q = parse("spreadsheets older than 6 months")
        #expect(q.extensions.contains("xlsx"))
        #expect(label(q, .date) == "Older than 6 months")
        #expect(q.before == Self.cal.date(byAdding: .month, value: -6, to: Self.now))
    }

    @Test func zipFromWhatsAppYesterday() {
        let q = parse("that zip file someone sent me on whatsapp yesterday")
        #expect(q.extensions == ["zip"])
        #expect(q.sourceKeys == ["whatsapp"])
        #expect(label(q, .date) == "Yesterday")
        #expect(q.terms == ["someone"])
    }

    @Test func slidesAboutRevenue() {
        let q = parse("slides about our quarterly revenue")
        #expect(q.extensions.contains("key") && q.extensions.contains("pptx"))
        #expect(q.terms.contains("quarterly") && q.terms.contains("revenue"))
        #expect(q.looks.isEmpty)
    }

    // MARK: Sizes

    @Test func videosOverOneGB() {
        let q = parse("videos larger than 1 gb")
        #expect(q.categories == [.videos])
        #expect(q.minSize == 1_000_000_000)
    }

    @Test func bigVideosMeansFileSize() {
        #expect(parse("big videos").minSize == 100_000_000)
        #expect(parse("huge files").minSize == 1_000_000_000)
    }

    @Test func bigCatIsNotAFileSize() {
        let q = parse("a picture of a big striped cat")
        #expect(q.minSize == nil)
        #expect(q.looks.contains { $0.labels.contains("cat") })
    }

    // MARK: Dates

    @Test func aFewDaysAgoMeansPastWeek() {
        let q = parse("photo of a tiger from a few days ago")
        #expect(label(q, .date) == "Past week")
        #expect(q.after == Self.cal.date(byAdding: .day, value: -7, to: Self.now))
    }

    @Test func monthWithYear() {
        let q = parse("invoices from march 2025")
        #expect(q.after == day(2025, 3, 1) && q.before == day(2025, 4, 1))
        #expect(q.terms == ["invoices"])
    }

    @Test func ambiguousMonthWordsNeedContext() {
        // "may" and "march" are ordinary words unless something says they're dates.
        #expect(parse("may notes").after == nil)
        #expect(parse("march plans").after == nil)
        #expect(parse("photos from may").after == day(2026, 5, 1))
    }

    @Test func monthLaterThisYearMeansLastYear() {
        // It's November, so "December" means December 2025.
        #expect(parse("photos from december").after == day(2025, 12, 1))
    }

    @Test func notOpenedInAYear() {
        let q = parse("videos not opened in 1 year")
        #expect(q.before == Self.cal.date(byAdding: .year, value: -1, to: Self.now))
        #expect(label(q, .date) == "Untouched for 1 year")
    }

    @Test func haventOpenedInAYear() {
        // Said the way people actually say it.
        let q = parse("huge video files I haven't opened in a year")
        #expect(q.categories == [.videos])
        #expect(q.minSize == 1_000_000_000)
        #expect(q.before == Self.cal.date(byAdding: .year, value: -1, to: Self.now))
        #expect(q.terms.isEmpty)
    }

    // MARK: Devices, places, sources

    @Test func photosFromIPhone() {
        let q = parse("photos from my iphone")
        #expect(q.categories == [.images])
        #expect(q.devices == ["iphone"])
        #expect(label(q, .device) == "iPhone")
    }

    @Test func carPhotosFromCanon() {
        let q = parse("photos of my car taken with my Canon")
        #expect(q.devices == ["canon"])
        #expect(q.looks.contains { $0.labels.contains("car") })
    }

    @Test func inDownloads() {
        let q = parse("an image with mountains and snow somewhere in my downloads")
        #expect(q.locations == ["Downloads"])
        #expect(q.categories == [.images])
        #expect(q.looks.contains { $0.word == "mountain" })
        #expect(q.looks.contains { $0.word == "snow" })
    }

    @Test func downloadedMeansFromTheWeb() {
        let q = parse("music I downloaded last month")
        #expect(q.categories == [.music])
        #expect(q.anySource)
        #expect(q.after == day(2026, 10, 1) && q.before == day(2026, 11, 1))
    }

    // MARK: Looks and colours

    @Test func blueCoverPDF() {
        let q = parse("the pdf where the cover page is blue")
        #expect(q.extensions == ["pdf"])
        #expect(q.coverColours == ["blue"])
        #expect(label(q, .colour) == "Cover: mostly blue")
        #expect(q.terms.isEmpty)
    }

    @Test func seasideExpandsToBeachLabels() {
        let q = parse("photos by the seaside")
        #expect(q.looks.first?.labels.contains("beach") == true)
    }

    @Test func darkModeAppScreenshotsAreNotApps() {
        // "app" here is what the screenshot shows, not a request for applications.
        let q = parse("screenshots of a dark mode app")
        #expect(q.screenshots)
        #expect(!q.categories.contains(.apps))
        #expect(label(q, .type) == "Screenshots")
        // and "dark mode" means the screen is mostly black
        #expect(q.coverColours == ["black"])
        #expect(q.terms == ["app"])
        #expect(parse("light theme screenshots").coverColours == ["white"])
    }

    @Test func appsStillWorkOnTheirOwn() {
        #expect(parse("apps").categories == [.apps])
        #expect(parse("apps I downloaded this week").categories == [.apps])
        #expect(parse("large apps").categories == [.apps])
    }

    @Test func topicAfterAboutIsWordsNotLooks() {
        let q = parse("the document about my car insurance renewal")
        #expect(q.looks.isEmpty)
        #expect(q.terms.contains("car") && q.terms.contains("insurance"))
    }

    @Test func aboutAnAmountIsNotATopic() {
        #expect(QueryParser.topicClause("photos from about 3 days ago of a tiger") == nil)
        #expect(QueryParser.topicClause("videos about 5 mb") == nil)
        #expect(parse("photos from about 3 days ago of a tiger").looks.contains { $0.labels.contains("tiger") })
    }

    @Test func storyWordsAreNotRequired() {
        // In a search that isn't about pictures every leftover word must be in the file, so filler matters.
        let deck = parse("the presentation I was working on the other day")
        #expect(deck.terms.isEmpty)
        #expect(deck.chips.first { $0.kind == .date }?.label == "Past week")
        #expect(parse("slides about our quarterly revenue").terms == ["quarterly", "revenue"])
        #expect(parse("working draft pdf").terms == ["working", "draft"])
    }

    @Test func singularSelfieAndMeme() {
        #expect(parse("selfie at the beach").categories == [.images])
        #expect(parse("that cat meme").categories == [.images])
    }

    // MARK: Names, quotes, sorting

    @Test func namedFile() {
        let q = parse("pdf named report")
        #expect(q.nameTerms == ["report"])
        #expect(label(q, .name) == "Name: report")
    }

    @Test func quotedPhraseIsExact() {
        let q = parse("\"quarterly plan\" docs")
        #expect(q.terms == ["quarterly plan"])
        #expect(q.categories == [.documents])
    }

    @Test func largestFirst() {
        let q = parse("largest videos first")
        #expect(q.sort == SortSpec(field: .size, ascending: false))
        #expect(q.categories == [.videos])
    }

    @Test func plainWordsFallBackToNameSearch() {
        let q = parse("the")
        #expect(q.terms == ["the"])
    }

    // MARK: Removing a chip edits the text

    @Test func removingAChipRemovesItsWords() {
        let text = "pdfs from last week"
        let q = parse(text)
        let date = q.chips.first { $0.kind == .date }!
        #expect(QueryParser.removing(date, from: text) == "pdfs")
    }

    @Test func removingTheLastThingTidiesLittleWords() {
        let text = "photos of a tiger"
        let look = parse(text).chips.first { $0.kind == .looks }!
        #expect(QueryParser.removing(look, from: text) == "photos")
    }

    @Test func removingFromTheMiddleKeepsTheRest() {
        // Words after the removed part still need their little words.
        let text = "pdfs from last week about taxes"
        let date = parse(text).chips.first { $0.kind == .date }!
        #expect(QueryParser.removing(date, from: text) == "pdfs from about taxes")
    }

    @Test func otherWaysOfSayingUntouched() {
        let yearAgo = Self.cal.date(byAdding: .year, value: -1, to: Self.now)
        #expect(parse("files I have not opened in a year").before == yearAgo)
        // Not "Past year": that would show exactly the files that WERE touched.
        let never = parse("photos never touched in the past year")
        #expect(never.before == yearAgo && never.after == nil)
        #expect(never.terms.isEmpty)
        #expect(parse("files I haven't opened in months").before == Self.cal.date(byAdding: .month, value: -3, to: Self.now))
        let watched = parse("videos I haven't watched in a year")
        #expect(watched.before == yearAgo && watched.terms.isEmpty)
        #expect(parse("docs I haven’t used for 2 years").before == Self.cal.date(byAdding: .year, value: -2, to: Self.now))
    }

    @Test func appWordsInsideOtherKinds() {
        #expect(!parse("screen recordings of the app").categories.contains(.apps))
        #expect(parse("pdf about the app launch").extensions == ["pdf"])
        #expect(parse("pdf about the app launch").terms.contains("app"))
    }
}
