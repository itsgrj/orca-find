import AppKit

/// Where a capture came from, taken automatically the moment the shortcut is pressed.
struct CaptureContext {
    var appName: String?
    var bundleID: String?
    var pid: pid_t = 0
    var windowTitle: String?
    var pageURL: String?
    var pageTitle: String?

    static let browsers: [String: Browser] = [
        "com.apple.Safari": .safari, "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium, "com.google.Chrome.beta": .chromium, "com.google.Chrome.canary": .chromium,
        "company.thebrowser.Browser": .chromium, "com.brave.Browser": .chromium, "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium, "com.operasoftware.Opera": .chromium, "org.chromium.Chromium": .chromium
    ]
    enum Browser { case safari, chromium }
    /// Browsers AppleScript can't ask for the page; Orca reads their address through Accessibility instead.
    static let otherBrowsers: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "io.gitlab.librewolf-community", "net.waterfox.waterfox", "com.kagi.kagimacOS", "company.thebrowser.dia",
        "ai.perplexity.comet", "com.openai.atlas"
    ]

    var isBrowser: Bool { bundleID.map { CaptureContext.browsers[$0] != nil || CaptureContext.otherBrowsers.contains($0) } ?? false }

    /// App + window title right now (cheap; the page link is fetched separately).
    @MainActor static func snapshot() -> CaptureContext {
        var c = CaptureContext()
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return c }
        c.appName = app.localizedName
        c.bundleID = app.bundleIdentifier
        c.pid = app.processIdentifier
        c.windowTitle = frontWindowTitle(pid: app.processIdentifier)
        return c
    }

    /// Title of the app's frontmost normal window (needs Screen Recording permission, which capturing has).
    static func frontWindowTitle(pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// Asks the browser for its current tab (URL + title). Runs osascript so it never blocks the UI;
    /// the first time, macOS asks once whether Orca may talk to that browser.
    static func fetchPage(bundleID: String) async -> (url: String, title: String?)? {
        guard let kind = browsers[bundleID] else { return nil }
        let script: String
        switch kind {
        case .safari:
            script = "tell application id \"\(bundleID)\" to return (URL of front document) & linefeed & (name of front document)"
        case .chromium:
            script = "tell application id \"\(bundleID)\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
        }
        return await Task.detached(priority: .userInitiated) { () -> (String, String?)? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            // Give up after 4 s (e.g. the permission prompt is ignored).
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate(); return nil }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard let url = parts.first, url.hasPrefix("http") else { return nil }
            return (url, parts.count > 1 ? parts[1...].joined(separator: " ") : nil)
        }.value
    }

    /// A readable title from a page/window title: "Priya Shah on X: “We raised…” / X" → "Priya Shah on X".
    static func cleanTitle(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression) // "(3) Home / X"
        for suffix in [" / X", " / Twitter", " - YouTube", " • Instagram photos and videos", " | LinkedIn", " - Google Docs",
                       " - Google Chrome", " — Mozilla Firefox", " - Reddit", " | Substack"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        if let r = t.range(of: #":\s*[“"]"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }
        t = t.trimmingCharacters(in: .whitespaces)
        if ["home", "new tab", "untitled", "x", "instagram"].contains(t.lowercased()) { return nil }
        return t.count > 90 ? String(t.prefix(88)) + "…" : t
    }

    /// Title for a capture: the page title, else the first words of the note, else the first line Orca read.
    static func title(page: String?, window: String?, note: String, ocr: String, app: String?) -> String {
        if let t = cleanTitle(page) ?? cleanTitle(window) { return t }
        let firstClause = note.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !firstClause.isEmpty {
            let words = firstClause.split(separator: " ")
            return words.prefix(7).joined(separator: " ") + (words.count > 7 ? "…" : "")
        }
        if let line = ocr.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.count > 3 }) {
            return line.count > 60 ? String(line.prefix(58)) + "…" : line
        }
        return "Capture from \(app ?? "screen")"
    }
}
