import Foundation
import Testing
@testable import OrcaFind

/// What arrives from Share › Orca in another app (orcafind://share?…), and what the strip says about it.
@Suite("Share menu: reading what was shared")
struct SharedItemTests {
    func link(_ q: [String: String]) -> URL {
        var c = URLComponents(); c.scheme = "orcafind"; c.host = "share"
        c.queryItems = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    @Test func webPage() throws {
        let item = try #require(SharedItem(link: link(["kind": "page", "url": "https://www.x.com/priyabuilds/status/1", "title": "Priya Shah on X"])))
        #expect(item.kind == .page)
        #expect(item.host == "x.com")
        #expect(item.headline == "Priya Shah on X")
        #expect(item.detail(from: "Safari") == "x.com · picture of the page and the link")
    }

    @Test func pageWithoutTitleUsesTheSite() throws {
        let item = try #require(SharedItem(link: link(["kind": "page", "url": "https://dribbble.com/shots/1"])))
        #expect(item.headline == "dribbble.com")
    }

    @Test func fileIsRememberedByWhereItIs() throws {
        let item = try #require(SharedItem(link: link(["kind": "file", "path": "/Users/me/Documents/Q3 pricing deck.pdf"])))
        #expect(item.headline == "Q3 pricing deck.pdf")
        #expect(item.detail(from: "Finder") == "From Finder · Orca remembers where it is")
    }

    @Test func selectedText() throws {
        let long = String(repeating: "pricing pages answer one question ", count: 10)
        let item = try #require(SharedItem(link: link(["kind": "text", "text": long])))
        #expect(item.headline.hasPrefix("“pricing pages"))
        #expect(item.headline.hasSuffix("…”"))
        #expect(item.headline.count <= 72)
    }

    @Test func photoNeedsNothingInTheLink() {
        #expect(SharedItem(link: link(["kind": "photo"]))?.kind == .photo)
    }

    @Test func incompleteLinksAreIgnored() {
        #expect(SharedItem(link: link(["kind": "page"])) == nil)
        #expect(SharedItem(link: link(["kind": "file"])) == nil)
        #expect(SharedItem(link: link(["kind": "text", "text": ""])) == nil)
        #expect(SharedItem(link: link(["kind": "video"])) == nil)
        #expect(SharedItem(link: URL(string: "orcafind://share")!) == nil)
    }

    @Test func oldCapturesStillLoad() throws {
        // Captures saved before files could be shared have no filePath; they must still decode.
        let json = #"{"id":"a","created":0,"note":"","noteTyped":false,"title":"t","pastedLinks":[],"ocr":"","width":1,"height":1,"audioSeconds":0}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let c = try d.decode(Capture.self, from: Data(json.utf8))
        #expect(c.filePath == nil)
    }
}
