import AppKit
import QuickLookThumbnailing
import ScreenCaptureKit

/// Something handed to Orca from another app's Share menu (Extensions/OrcaShare), via orcafind://share?…
struct SharedItem: Sendable, Equatable {
    enum Kind: String, Sendable { case page, photo, file, text }
    var kind: Kind
    var url: String?
    var title: String?
    var path: String?
    var text: String?

    init(kind: Kind, url: String? = nil, title: String? = nil, path: String? = nil, text: String? = nil) {
        self.kind = kind; self.url = url; self.title = title; self.path = path; self.text = text
    }

    init?(link: URL) {
        guard let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let kind = q["kind"].flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(kind: kind, url: q["url"], title: q["title"].flatMap { $0.isEmpty ? nil : $0 }, path: q["path"], text: q["text"])
        switch kind {
        case .page: guard url != nil else { return nil }
        case .file: guard path != nil else { return nil }
        case .text: guard !(text ?? "").isEmpty else { return nil }
        case .photo: break
        }
    }

    var host: String? { url.flatMap { URL(string: $0)?.host }.map { $0.replacingOccurrences(of: "www.", with: "") } }
    var fileName: String? { path.map { ($0 as NSString).lastPathComponent } }

    /// "Priya Shah on X: …", "Q3 pricing deck.pdf", "“The best pricing pages…”"
    var headline: String {
        switch kind {
        case .page: return title ?? host ?? "Web page"
        case .photo: return title ?? "Photo"
        case .file: return fileName ?? "File"
        case .text: return "“" + Self.excerpt(text ?? "", 70) + "”"
        }
    }

    /// What Orca keeps, in everyday words.
    func detail(from app: String?) -> String {
        switch kind {
        case .page: return "\(host ?? "Web page") · picture of the page and the link"
        case .photo: return "From \(app ?? "Photos") · the photo itself"
        case .file: return "From \(app ?? "Finder") · Orca remembers where it is"
        case .text: return "From \(app ?? "another app") · the words you selected"
        }
    }

    static func excerpt(_ s: String, _ n: Int) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? String(one.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…" : one
    }
}

/// The picture each kind of shared thing gets, so it sits in Captures like any other capture.
enum ShareImages {
    /// The main window of the app that shared, as global AppKit coordinates plus its window number.
    /// The largest one on screen: right after Share › Orca the menu itself can still be a window of that app.
    static func frontWindow(pid: pid_t) -> (id: CGWindowID, frame: NSRect)? {
        guard pid > 0, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame else { return nil }
        var best: (id: CGWindowID, frame: NSRect)?
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width > 200, r.height > 150, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            if best.map({ $0.frame.width * $0.frame.height < r.width * r.height }) ?? true {
                best = (id, NSRect(x: r.minX, y: primary.maxY - r.maxY, width: r.width, height: r.height))
            }
        }
        return best
    }

    /// Just that window, even if something overlaps it. Needs the screen permission captures already use.
    static func window(_ id: CGWindowID, frame: NSRect) async -> CGImage? {
        guard ScreenGrab.hasPermission else { log("page picture: no screen permission"); return nil }
        do {
            var content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            if !content.windows.contains(where: { $0.windowID == id }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            }
            guard let w = content.windows.first(where: { $0.windowID == id }) else { log("page picture: window \(id) not found"); return nil }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
            config.width = Int(w.frame.width * scale)
            config.height = Int(w.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log("page picture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// One line per share in ~/Library/Logs/Orca Find/share.log, so a fallback picture can be explained.
    static func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orca Find")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("share.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: file) }
    }

    /// The picture the Share extension left on Orca's private pasteboard.
    static func sharedPicture() -> CGImage? {
        let pb = NSPasteboard(name: NSPasteboard.Name("app.orcafind.share"))
        defer { pb.clearContents() }
        guard let type = pb.types?.first, let data = pb.data(forType: type),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// The file's own preview (first page of a PDF, a frame of a video), else its icon.
    static func thumbnail(path: String) async -> CGImage? {
        let url = URL(fileURLWithPath: path)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1200, height: 1200), scale: 1, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { return rep.cgImage }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 512, height: 512)
        return icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Words (selected text, or a page Orca couldn't take a picture of) drawn as a card.
    static func card(_ words: String, footer: String?, paper: NSColor = NSColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1)) -> CGImage? {
        let size = NSSize(width: 900, height: 600)
        let img = NSImage(size: size, flipped: true) { rect in
            paper.setFill(); rect.fill()
            let para = NSMutableParagraphStyle(); para.lineSpacing = 6; para.lineBreakMode = .byTruncatingTail
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .medium),
                                                       .foregroundColor: NSColor(white: 0.16, alpha: 1), .paragraphStyle: para]
            (words as NSString).draw(with: NSRect(x: 64, y: 64, width: size.width - 128, height: size.height - 170),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: body)
            if let footer {
                let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor(white: 0.4, alpha: 1)]
                (footer as NSString).draw(at: NSPoint(x: 64, y: size.height - 80), withAttributes: small)
            }
            return true
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// Puts "Orca" in Share menus the first time Orca runs with the extension inside it.
/// macOS adds new Share extensions switched off; without this, people would have to find it in System Settings.
enum ShareMenu {
    static let extensionID = "app.orcafind.mac.share"

    static func enableOnce() {
        let key = "shareMenuEnabledOnce"
        guard !UserDefaults.standard.bool(forKey: key),
              let ext = Bundle.main.builtInPlugInsURL?.appendingPathComponent("OrcaShare.appex"),
              FileManager.default.fileExists(atPath: ext.path) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.global(qos: .utility).async {
            run(["-a", ext.path])
            run(["-e", "use", "-i", extensionID])
        }
    }

    private static func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
