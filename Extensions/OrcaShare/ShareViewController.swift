import Cocoa
import UniformTypeIdentifiers

/// "Orca" in every Share menu. It shows nothing itself: it reads what was shared, hands it to Orca with an
/// orcafind://share link, and closes. Orca then opens its usual capture strip, already listening.
///
/// Built by build.sh (not SwiftPM) into Orca Find.app/Contents/PlugIns/OrcaShare.appex.
/// It runs sandboxed, so pictures travel on a private pasteboard: Orca never has to read this extension's
/// own folder (which would make macOS ask "Orca would like to access data from other apps").
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    static let pasteboard = NSPasteboard.Name("app.orcafind.share")

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let link = await self.read()
            let done: () -> Void = { self.extensionContext?.completeRequest(returningItems: nil) }
            guard let link else { done(); return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false   // stay in the app you shared from; Orca's strip floats over it
            NSWorkspace.shared.open(link, configuration: config) { _, _ in DispatchQueue.main.async(execute: done) }
        }
    }

    /// One thing per share, in this order: a web page, a file, a picture, some text.
    @MainActor private func read() async -> URL? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let title = items.first?.attributedContentText?.string ?? items.first?.attributedTitle?.string
        var q: [String: String] = [:]
        if let title, !title.isEmpty { q["title"] = String(title.prefix(300)) }

        var web: URL?, file: URL?, imageData: Data?, text: String?
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), file == nil,
               let u = Self.url(await Self.load(p, UTType.fileURL.identifier)), u.isFileURL {
                file = u
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), web == nil,
                      let u = Self.url(await Self.load(p, UTType.url.identifier)) {
                if u.isFileURL { file = file ?? u } else if u.scheme?.hasPrefix("http") == true { web = u }
            }
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier), imageData == nil {
                imageData = Self.data(await Self.load(p, UTType.image.identifier))
            }
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), text == nil {
                let obj = await Self.load(p, UTType.plainText.identifier)
                text = (obj as? String) ?? (obj as? NSAttributedString)?.string ?? (obj as? Data).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        // Photos and other apps hand over pictures as temporary files; only files the person keeps count as files.
        if let f = file, Self.isTemporary(f) {
            if imageData == nil, UTType(filenameExtension: f.pathExtension)?.conforms(to: .image) == true { imageData = try? Data(contentsOf: f) }
            file = nil
        }

        if let web {
            q["kind"] = "page"; q["url"] = web.absoluteString
        } else if let file {
            q["kind"] = "file"; q["path"] = file.path
        } else if let imageData {
            let pb = NSPasteboard(name: Self.pasteboard)
            pb.clearContents()
            pb.setData(imageData, forType: NSPasteboard.PasteboardType(UTType.image.identifier))
            q["kind"] = "photo"
        } else if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let u = URL(string: text), u.scheme?.hasPrefix("http") == true, !text.contains(" ") {
                q["kind"] = "page"; q["url"] = text
            } else {
                q["kind"] = "text"; q["text"] = String(text.prefix(6000))
            }
        } else {
            return nil
        }
        var c = URLComponents(); c.scheme = "orcafind"; c.host = "share"
        c.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }

    private static func load(_ p: NSItemProvider, _ type: String) async -> NSSecureCoding? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: type, options: nil) { obj, _ in cont.resume(returning: obj) }
        }
    }

    private static func url(_ obj: NSSecureCoding?) -> URL? {
        if let u = obj as? URL { return u }
        if let d = obj as? Data { return URL(dataRepresentation: d, relativeTo: nil) }
        if let s = obj as? String { return URL(string: s) }
        return nil
    }

    private static func data(_ obj: NSSecureCoding?) -> Data? {
        if let d = obj as? Data { return d }
        if let u = obj as? URL, u.isFileURL { return try? Data(contentsOf: u) }
        if let img = obj as? NSImage { return img.tiffRepresentation }
        return nil
    }

    /// Inside someone's sandbox, a temp folder or the Photos library: gone soon, so not worth remembering.
    private static func isTemporary(_ u: URL) -> Bool {
        let p = u.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // This extension's own home is its sandbox container, so compare against the real user folder.
        let realHome = home.components(separatedBy: "/Library/Containers/").first ?? home
        if p.contains("/Library/Containers/") || p.contains("/Library/Group Containers/") || p.contains(".photoslibrary/") { return true }
        if p.hasPrefix("/private/var/folders/") || p.hasPrefix("/var/folders/") || p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") { return true }
        return !(p.hasPrefix(realHome + "/") || p.hasPrefix("/Volumes/"))
    }
}
