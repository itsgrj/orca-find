import AppKit
import ApplicationServices

/// Reads the browser page the way a screen reader does (macOS Accessibility), right when the drag ends:
/// - the link under the box you dragged, so a grab from a feed keeps the pin / post / video itself, not the feed;
/// - where a YouTube video was, so its link reopens at that moment;
/// - the page address in browsers AppleScript can't ask (Firefox, Zen…).
/// Needs no browser settings, only Orca being allowed under Privacy & Security › Accessibility.
/// Everything here is blocking IPC, so call `inspect` off the main thread.
enum PageInspector {
    struct Found: Sendable {
        var pageURL: String?
        var itemURL: String?
        var videoSeconds: Double?
    }

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// macOS's own "allow Accessibility" alert, with a button to System Settings.
    static func askForAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Chromium browsers only build their page tree for assistive apps once asked; ask when the shortcut is
    /// pressed so the tree is ready by the time the drag ends.
    static func wake(pid: pid_t) {
        guard pid > 0, isAllowed else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// AppKit global rect (bottom-left origin) → Accessibility coordinates (top-left of the main screen).
    @MainActor static func axRect(_ r: NSRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func inspect(pid: pid_t, box: CGRect) -> Found {
        var found = Found()
        guard pid > 0, isAllowed, box.width > 2, box.height > 2 else { return found }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let web = webArea(in: app, box: box) else { return found }
        found.pageURL = urlString(web, kAXURLAttribute)

        let links = linksUnder(box, in: web)
        found.itemURL = pickItem(links, box: box, page: found.pageURL)
        if SourceLinks.supportsMoment(found.pageURL) { found.videoSeconds = videoPosition(in: web) }
        return found
    }

    /// Where the page sits on screen (Accessibility coordinates); for `--page-probe`.
    static func pageFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return webArea(in: app, box: CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5)).flatMap(frame)
    }

    // MARK: Finding the page

    /// The page (AXWebArea) in the front window that overlaps the box most — not DevTools or a side panel.
    private static func webArea(in app: AXUIElement, box: CGRect) -> AXUIElement? {
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return nil }
        var queue = [window], seen = 0
        var best: (AXUIElement, CGFloat)?
        while !queue.isEmpty, seen < 800 {
            let e = queue.removeFirst(); seen += 1
            if string(e, kAXRoleAttribute) == "AXWebArea" {
                let overlap = frame(e).map { $0.intersection(box).area } ?? 0
                if best == nil || overlap > best!.1 { best = (e, overlap) }
                continue // the page's own content can be huge; the walk below handles it
            }
            queue += children(e)
        }
        return best?.0
    }

    // MARK: Links under the box

    private struct Link { let url: String; let frame: CGRect }

    /// Every link that overlaps the box. Skips parts of the page that don't touch it.
    private static func linksUnder(_ box: CGRect, in web: AXUIElement) -> [Link] {
        let reach = box.insetBy(dx: -4, dy: -4)
        let deadline = Date().addingTimeInterval(0.8)
        var stack = [web], seen = 0, out: [Link] = []
        while let e = stack.popLast(), seen < 6000, Date() < deadline {
            seen += 1
            let f = frame(e)
            if let f, f.width > 0, f.height > 0, !f.intersects(reach) { continue }
            if string(e, kAXRoleAttribute) == "AXLink", let f, let u = urlString(e, kAXURLAttribute), u.hasPrefix("http") {
                out.append(Link(url: u, frame: f))
            }
            stack += children(e).reversed()
        }
        return out
    }

    /// The one thing the box was drawn around.
    /// 1. A link to a single item (pin, post, video, product…) inside the box; if there are several, the one
    ///    covering most of the box (a feed card links the same pin from its image and its title).
    /// 2. Otherwise a big link that wraps most of the box, like a card whose image links elsewhere.
    /// A small link inside a grabbed paragraph is neither, so it's ignored.
    private static func pickItem(_ links: [Link], box: CGRect, page: String?) -> String? {
        let boxArea = max(box.area, 1)
        var items: [String: (url: String, score: CGFloat)] = [:]
        var wrapper: (url: String, cover: CGFloat)?
        for l in links where !SourceLinks.same(l.url, page) {
            let overlap = l.frame.intersection(box).area
            let inside = overlap / max(l.frame.area, 1)
            let cover = overlap / boxArea
            guard inside >= 0.5 || cover >= 0.3 else { continue }
            if let item = SourceLinks.item(l.url) {
                let prev = items[item.key]
                items[item.key] = (prev?.url ?? l.url, (prev?.score ?? 0) + max(overlap, 1))
            } else if cover >= 0.4, cover > (wrapper?.cover ?? 0) {
                wrapper = (l.url, cover)
            }
        }
        if let best = items.values.max(by: { $0.score < $1.score }) { return clean(best.url) }
        return wrapper.map { clean($0.url) }
    }

    /// Drops tracking bits Pinterest/YouTube add to feed links.
    private static func clean(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return raw }
        let junk: Set<String> = ["pp", "si", "feature", "ref_src", "ref", "utm_source", "utm_medium", "utm_campaign"]
        let q = (c.queryItems ?? []).filter { !junk.contains($0.name) }
        c.queryItems = q.isEmpty ? nil : q
        c.fragment = nil
        return c.string ?? raw
    }

    // MARK: Video position

    /// Reads YouTube's seek bar ("2:14 of 10:31"). It's near the top of the page, so walk in page order and stop there.
    private static func videoPosition(in web: AXUIElement) -> Double? {
        let deadline = Date().addingTimeInterval(0.6)
        var stack = [web], seen = 0
        while let e = stack.popLast(), seen < 4000, Date() < deadline {
            seen += 1
            if string(e, kAXRoleAttribute) == "AXSlider" {
                let text = string(e, "AXValueDescription") ?? ""
                let label = (string(e, kAXDescriptionAttribute) ?? "") + " " + (string(e, kAXTitleAttribute) ?? "")
                if text.contains(" of "), let s = SourceLinks.parseClock(text) { return s }
                if label.localizedCaseInsensitiveContains("seek") {
                    if let s = SourceLinks.parseClock(text) { return s }
                    if let v = number(e, kAXValueAttribute), let m = number(e, kAXMaxValueAttribute), m > 0, v >= 0, v <= m { return v }
                }
                continue
            }
            stack += children(e).reversed()
        }
        return nil
    }

    // MARK: AX helpers

    private static func value(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? { value(e, attr) as? String }

    private static func number(_ e: AXUIElement, _ attr: String) -> Double? { (value(e, attr) as? NSNumber)?.doubleValue }

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] { (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    private static func urlString(_ e: AXUIElement, _ attr: String) -> String? {
        guard let v = value(e, attr) else { return nil }
        if let u = v as? URL { return u.absoluteString }
        return v as? String
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
