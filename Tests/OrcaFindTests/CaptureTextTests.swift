import Foundation
import Testing
@testable import OrcaFind

/// Clean-up rules for the text Orca reads in a capture's picture, plus the "Remove “…”" wording.
/// Lines are from a real web-page screenshot that the first pass misread.
@Suite("Captures: text read from the picture")
struct CaptureTextTests {
    @Test func keepsTheRealWordFromEitherReading() {
        #expect(TextExtractor.bestOfBoth(first: "Onen an affected run to see the request tool activity.",
                                         closeUp: "Open an affected run to see the reauest. tool activitv.")
                == "Open an affected run to see the request tool activity.")
    }

    @Test func trustsTheCloseUpOtherwise() {
        // Both are real words: the close-up wins.
        #expect(TextExtractor.bestOfBoth(first: "Repeated wet searches", closeUp: "Repeated web searches") == "Repeated web searches")
        // Different word counts: can't line them up, so the close-up wins.
        #expect(TextExtractor.bestOfBoth(first: "8003180S・4000UrunS・24N・stradve",
                                         closeUp: "8,063 flags • 40,000 runs • 24h • Illustrative")
                == "8,063 flags • 40,000 runs • 24h • Illustrative")
        // Numbers aren't words: the close-up's punctuation wins.
        #expect(TextExtractor.bestOfBoth(first: "1,648. 4.1%", closeUp: "1,648 • 4.1%") == "1,648 • 4.1%")
    }

    @Test func dropsCheckmarksReadAsLetters() {
        #expect(TextExtractor.withoutIconGlyph("V Track failure trends over time") == "Track failure trends over time")
        #expect(TextExtractor.withoutIconGlyph("~ Define your own failures") == "Define your own failures")
        // Real text stays: one word after the letter, or a lowercase word.
        #expect(TextExtractor.withoutIconGlyph("V Neck") == "V Neck")
        #expect(TextExtractor.withoutIconGlyph("v two words") == "v two words")
        #expect(TextExtractor.withoutIconGlyph("Vitamin D levels") == "Vitamin D levels")
    }

    @Test func removeButtonQuotesOnce() {
        #expect(QueryChip(kind: .text, label: "“grs”", symbol: "", ranges: []).quoted == "“grs”")
        #expect(QueryChip(kind: .type, label: "PDFs", symbol: "", ranges: []).quoted == "“PDFs”")
    }
}
