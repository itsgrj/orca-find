import Foundation

/// Where a downloaded file came from, derived from macOS's kMDItemWhereFroms attribute.
struct DownloadSource: Hashable {
    let key: String
    let name: String
    let symbol: String
    let host: String?
    let isWebsite: Bool
    let color: UInt32

    struct Known {
        let key: String
        let name: String
        let symbol: String
        let color: UInt32
        /// Host patterns. "foo.com" matches foo.com and *.foo.com; "~bar.com" matches any host ending in bar.com.
        let hosts: [String]
        /// Words people say when they mean this source. `needsPreposition` words only count after "from/via/on".
        let aliases: [String]
        let weakAliases: [String]
    }

    static let catalog: [Known] = [
        Known(key: "gmail", name: "Gmail", symbol: "envelope.fill", color: 0xEA4335,
              hosts: ["mail.google.com", "mail-attachment.googleusercontent.com", "inbox.google.com"],
              aliases: ["gmail", "google mail"], weakAliases: []),
        Known(key: "google-drive", name: "Google Drive", symbol: "externaldrive.fill.badge.icloud", color: 0x1FA463,
              hosts: ["drive.google.com", "drive.usercontent.google.com", "docs.google.com", "~docs.googleusercontent.com", "sheets.google.com", "slides.google.com"],
              aliases: ["google drive", "gdrive", "g drive", "google docs"], weakAliases: ["drive"]),
        Known(key: "chatgpt", name: "ChatGPT", symbol: "bubble.left.and.text.bubble.right.fill", color: 0x10A37F,
              hosts: ["chatgpt.com", "chat.openai.com", "openai.com", "oaiusercontent.com", "oaidalleapiprodscus.blob.core.windows.net", "sdmntpr.oaiusercontent.com"],
              aliases: ["chatgpt", "chat gpt", "openai", "dall-e", "dalle"], weakAliases: ["gpt"]),
        Known(key: "claude", name: "Claude", symbol: "sparkles", color: 0xD97757,
              hosts: ["claude.ai", "anthropic.com", "claudeusercontent.com"],
              aliases: [], weakAliases: ["claude"]),
        Known(key: "canva", name: "Canva", symbol: "paintbrush.pointed.fill", color: 0x00C4CC,
              hosts: ["canva.com", "canva-user-content.com", "canva.cn"],
              aliases: ["canva"], weakAliases: []),
        Known(key: "x", name: "X", symbol: "xmark", color: 0x111111,
              hosts: ["x.com", "twitter.com", "twimg.com", "t.co"],
              aliases: ["twitter", "x.com"], weakAliases: ["x"]),
        Known(key: "slack", name: "Slack", symbol: "number", color: 0x611F69,
              hosts: ["slack.com", "slack-edge.com", "slack-files.com", "slack-imgs.com"],
              aliases: ["slack"], weakAliases: []),
        Known(key: "whatsapp", name: "WhatsApp", symbol: "phone.bubble.fill", color: 0x25D366,
              hosts: ["whatsapp.com", "whatsapp.net"],
              aliases: ["whatsapp", "whats app"], weakAliases: []),
        Known(key: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", color: 0x24292F,
              hosts: ["github.com", "githubusercontent.com", "github.io", "githubassets.com", "ghcr.io"],
              aliases: ["github", "git hub"], weakAliases: []),
        Known(key: "extensions", name: "Extensions", symbol: "puzzlepiece.extension.fill", color: 0x7C5CFF,
              hosts: ["chromewebstore.google.com", "addons.mozilla.org", "clients2.googleusercontent.com", "microsoftedge.microsoft.com"],
              aliases: ["chrome extensions", "chrome extension", "browser extensions", "browser extension", "chrome web store"],
              weakAliases: ["extensions", "extension"]),
        Known(key: "dropbox", name: "Dropbox", symbol: "shippingbox.fill", color: 0x0061FF,
              hosts: ["dropbox.com", "dropboxusercontent.com", "db.tt"], aliases: ["dropbox"], weakAliases: []),
        Known(key: "notion", name: "Notion", symbol: "doc.text.fill", color: 0x2F2F2F,
              hosts: ["notion.so", "notion.site", "notion-static.com", "notionusercontent.com"], aliases: ["notion"], weakAliases: []),
        Known(key: "figma", name: "Figma", symbol: "pencil.and.outline", color: 0xA259FF,
              hosts: ["figma.com", "figmausercontent.com"], aliases: ["figma"], weakAliases: []),
        Known(key: "discord", name: "Discord", symbol: "gamecontroller.fill", color: 0x5865F2,
              hosts: ["discord.com", "discordapp.com", "discordapp.net", "discord.gg"], aliases: ["discord"], weakAliases: []),
        Known(key: "telegram", name: "Telegram", symbol: "paperplane.fill", color: 0x229ED9,
              hosts: ["telegram.org", "t.me", "telesco.pe"], aliases: ["telegram"], weakAliases: []),
        Known(key: "outlook", name: "Outlook", symbol: "envelope.badge.fill", color: 0x0A64AD,
              hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com", "attachments.office.net", "live.com"],
              aliases: ["outlook", "hotmail"], weakAliases: []),
        Known(key: "icloud", name: "iCloud", symbol: "icloud.fill", color: 0x3693F3,
              hosts: ["icloud.com", "icloud-content.com"], aliases: ["icloud"], weakAliases: []),
        Known(key: "wetransfer", name: "WeTransfer", symbol: "arrow.up.arrow.down.circle.fill", color: 0x409FFF,
              hosts: ["wetransfer.com", "we.tl"], aliases: ["wetransfer", "we transfer"], weakAliases: []),
        Known(key: "youtube", name: "YouTube", symbol: "play.rectangle.fill", color: 0xFF0000,
              hosts: ["youtube.com", "youtu.be", "googlevideo.com"], aliases: ["youtube"], weakAliases: []),
        Known(key: "linkedin", name: "LinkedIn", symbol: "person.2.fill", color: 0x0A66C2,
              hosts: ["linkedin.com", "licdn.com"], aliases: ["linkedin"], weakAliases: []),
        Known(key: "reddit", name: "Reddit", symbol: "bubble.left.fill", color: 0xFF4500,
              hosts: ["reddit.com", "redd.it", "redditmedia.com"], aliases: ["reddit"], weakAliases: []),
    ]

    static let airdrop = DownloadSource(key: "airdrop", name: "AirDrop & Messages", symbol: "dot.radiowaves.left.and.right",
                                        host: nil, isWebsite: false, color: 0x0A84FF)

    static func known(_ key: String) -> Known? { catalog.first { $0.key == key } }

    private static func make(_ k: Known, host: String?) -> DownloadSource {
        DownloadSource(key: k.key, name: k.name, symbol: k.symbol, host: host, isWebsite: false, color: k.color)
    }

    private static func hostMatches(_ host: String, _ pattern: String) -> Bool {
        if pattern.hasPrefix("~") { return host.hasSuffix(String(pattern.dropFirst())) }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    static func detect(_ froms: [String]) -> DownloadSource? {
        guard !froms.isEmpty else { return nil }
        // The second entry is usually the page you were on (referrer); it's the more meaningful "source".
        var ordered = froms
        if froms.count > 1 { ordered = [froms[1], froms[0]] + froms.dropFirst(2) }

        var fallbackHost: String?
        for raw in ordered {
            let lower = raw.lowercased()
            if lower.hasPrefix("chrome-extension:") || lower.hasPrefix("moz-extension:")
                || lower.hasPrefix("safari-web-extension:") || lower.hasPrefix("extension:") {
                return make(known("extensions")!, host: nil)
            }
            guard let comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(),
                  ["http", "https", "ftp", "blob"].contains(scheme),
                  let host = comps.host?.lowercased(), !host.isEmpty else { continue }
            if lower.contains("chrome.google.com/webstore") || (host.hasSuffix("googleusercontent.com") && lower.contains("/crx/")) {
                return make(known("extensions")!, host: host)
            }
            if let k = catalog.first(where: { k in k.hosts.contains { hostMatches(host, $0) } }) {
                return make(k, host: host)
            }
            if fallbackHost == nil { fallbackHost = host }
        }
        if let h = fallbackHost {
            let domain = registrableDomain(h)
            return DownloadSource(key: "web:" + domain, name: domain, symbol: "globe", host: h, isWebsite: true, color: 0x6B7C8F)
        }
        // whereFroms without URLs come from AirDrop or Messages (they hold a name or handle instead).
        return airdrop
    }

    static func registrableDomain(_ host: String) -> String {
        var h = host
        for p in ["www.", "m.", "www2.", "dl.", "download.", "downloads.", "cdn."] where h.hasPrefix(p) {
            h = String(h.dropFirst(p.count))
        }
        let parts = h.split(separator: ".")
        guard parts.count > 2 else { return h }
        let twoLevel: Set<String> = ["co.uk", "com.au", "co.in", "co.jp", "com.br", "co.nz", "com.mx", "co.za", "com.sg", "org.uk", "ac.uk", "gov.uk", "com.cn", "net.au"]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoLevel.contains(lastTwo) { return parts.suffix(3).joined(separator: ".") }
        return lastTwo
    }
}
