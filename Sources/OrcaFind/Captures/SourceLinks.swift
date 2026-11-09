import Foundation

/// Recognises links that point at one thing (a pin, a post, a video, a product) rather than a feed,
/// and builds YouTube links that open at a moment. Foundation only, so the MCP server can use it too.
enum SourceLinks {
    /// What a link points at, or nil for feeds, profiles and ordinary pages.
    /// `key` identifies the item across URL variants (".../status/1/analytics" and ".../status/1" are the same post).
    struct Item: Equatable { let kind: String; let key: String }

    static func item(_ raw: String?) -> Item? {
        guard let raw, let u = URL(string: raw), let rawHost = u.host?.lowercased() else { return nil }
        let host = rawHost.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "m.", with: "", options: .anchored)
        let parts = u.path.split(separator: "/").map(String.init)
        func at(_ i: Int) -> String? { i < parts.count ? parts[i] : nil }
        func query(_ name: String) -> String? { URLComponents(string: raw)?.queryItems?.first { $0.name == name }?.value }
        func digits(_ s: String?) -> Bool { s.map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } ?? false }
        func is_(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if host.contains("pinterest."), at(0) == "pin", let id = at(1) { return Item(kind: "pin", key: "pin:\(id)") }
        if is_("x.com") || is_("twitter.com"), at(1) == "status", digits(at(2)) { return Item(kind: "post", key: "x:\(at(2)!)") }
        if is_("youtube.com") {
            if parts == ["watch"], let v = query("v") { return Item(kind: "video", key: "yt:\(v)") }
            if at(0) == "shorts" || at(0) == "live", let v = at(1) { return Item(kind: "video", key: "yt:\(v)") }
        }
        if host == "youtu.be", let v = at(0) { return Item(kind: "video", key: "yt:\(v)") }
        if is_("instagram.com") {
            if at(0) == "p", let id = at(1) { return Item(kind: "post", key: "ig:\(id)") }
            if at(0) == "reel" || at(0) == "reels", let id = at(1) { return Item(kind: "reel", key: "ig:\(id)") }
        }
        if is_("tiktok.com"), at(1) == "video", let id = at(2) { return Item(kind: "video", key: "tt:\(id)") }
        if is_("reddit.com"), let i = parts.firstIndex(of: "comments"), let id = at(i + 1) { return Item(kind: "post", key: "rd:\(id)") }
        if is_("linkedin.com"), (at(0) == "feed" && at(1) == "update") || at(0) == "posts", let id = parts.last {
            return Item(kind: "post", key: "li:\(id)")
        }
        if is_("threads.net") || is_("threads.com"), at(1) == "post", let id = at(2) { return Item(kind: "post", key: "th:\(id)") }
        if host == "bsky.app", at(2) == "post", let id = at(3) { return Item(kind: "post", key: "bs:\(id)") }
        if host == "news.ycombinator.com", parts == ["item"], let id = query("id") { return Item(kind: "post", key: "hn:\(id)") }
        if is_("vimeo.com"), digits(at(0)) { return Item(kind: "video", key: "vm:\(at(0)!)") }
        if is_("dribbble.com"), at(0) == "shots", let id = at(1) { return Item(kind: "shot", key: "dr:\(id.prefix { $0.isNumber })") }
        if is_("behance.net"), at(0) == "gallery", let id = at(1) { return Item(kind: "project", key: "be:\(id)") }
        if is_("etsy.com"), at(0) == "listing", let id = at(1) { return Item(kind: "product", key: "et:\(id)") }
        if host.contains("amazon."), let i = parts.firstIndex(where: { $0 == "dp" || $0 == "product" }), let id = at(i + 1) {
            return Item(kind: "product", key: "az:\(id)")
        }
        if is_("substack.com") || is_("medium.com"), let i = parts.firstIndex(of: "p"), let id = at(i + 1) {
            return Item(kind: "article", key: "\(host):\(id)")
        }
        return nil
    }

    /// True when two links point at the same thing (same item, or the same page ignoring #fragment and trailing /).
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        if let x = item(a), let y = item(b) { return x.key == y.key }
        func plain(_ s: String) -> String {
            var t = s.components(separatedBy: "#")[0]
            while t.hasSuffix("/") { t.removeLast() }
            return t.replacingOccurrences(of: "://www.", with: "://")
        }
        return plain(a) == plain(b)
    }

    // MARK: Video moments

    /// Whether Orca can open this page at a moment (YouTube videos; not Shorts, which ignore it).
    static func supportsMoment(_ raw: String?) -> Bool {
        guard let raw, let u = URL(string: raw), let host = u.host?.lowercased() else { return false }
        if host == "youtu.be" { return u.path.count > 1 }
        return (host == "youtube.com" || host.hasSuffix(".youtube.com")) && u.path == "/watch"
    }

    /// The same link, opening `seconds` in: youtube.com/watch?v=…&t=134s.
    static func atMoment(_ raw: String, seconds: Double) -> String {
        guard supportsMoment(raw), var c = URLComponents(string: raw) else { return raw }
        var q = (c.queryItems ?? []).filter { $0.name != "t" && $0.name != "start" }
        let s = Int(seconds.rounded(.down))
        if s >= 1 { q.append(URLQueryItem(name: "t", value: "\(s)s")) }
        c.queryItems = q.isEmpty ? nil : q
        return c.string ?? raw
    }

    /// 134 → "2:14", 3723 → "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "2:14 of 10:31" (what YouTube's seek bar tells screen readers) → 134.
    static func parseClock(_ text: String) -> Double? {
        guard let first = text.split(separator: " ").first else { return nil }
        let nums = first.split(separator: ":").map { Int($0) }
        guard (2...3).contains(nums.count), nums.allSatisfy({ $0 != nil }) else { return nil }
        return Double(nums.reduce(0) { $0 * 60 + $1! })
    }
}
