import AppKit

@MainActor
enum FileActions {
    static func open(_ items: [FileItem]) {
        for item in items { NSWorkspace.shared.open(item.url) }
    }

    static func revealInFinder(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    /// Puts the files themselves on the clipboard (paste into Finder, Mail, Slack…).
    static func copy(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
    }

    static func copyPath(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
