import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Spotlight

/// Captures (with the note you said) and smart folders show up in Spotlight, even when OrcaFind isn't open.
/// Clicking one opens it in OrcaFind (AppDelegate › continue userActivity).
@MainActor
enum SpotlightIndex {
    private static var task: Task<Void, Never>?
    private static var watching = false

    /// Indexes now, then again (debounced) whenever captures or smart folders change.
    static func start() {
        guard !watching else { return }
        watching = true
        watch()
        schedule(delay: 4)
    }

    private static func watch() {
        withObservationTracking {
            _ = CaptureLibrary.shared.version
            _ = AppState.shared.smartFolders
        } onChange: {
            Task { @MainActor in
                SpotlightIndex.schedule(delay: 2)
                SpotlightIndex.watch()
            }
        }
    }

    private static func schedule(delay: Double) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            reindex()
        }
    }

    private static func reindex() {
        let captures = CaptureLibrary.shared.items
        let folders = AppState.shared.smartFolders
        Task.detached(priority: .utility) {
            var items: [CSSearchableItem] = []
            for c in captures.prefix(2000) {
                let a = CSSearchableItemAttributeSet(contentType: .image)
                a.title = c.title.isEmpty ? "Capture" : c.title
                a.contentDescription = [c.note, c.sourceApp.map { "From \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                a.textContent = [c.note, c.ocr, c.windowTitle ?? ""].joined(separator: "\n")
                a.keywords = (c.tags ?? []) + [c.collection].compactMap { $0 } + ["capture", "OrcaFind"]
                a.contentCreationDate = c.created
                if FileManager.default.fileExists(atPath: c.imageURL.path) { a.thumbnailURL = c.imageURL }
                a.contentURL = c.deepLink
                items.append(CSSearchableItem(uniqueIdentifier: "capture:\(c.id)", domainIdentifier: "captures", attributeSet: a))
            }
            for f in folders {
                let a = CSSearchableItemAttributeSet(contentType: .folder)
                a.title = f.name
                a.contentDescription = "Smart folder in OrcaFind"
                a.keywords = ["smart folder", "OrcaFind"]
                items.append(CSSearchableItem(uniqueIdentifier: "folder:\(f.id.uuidString)", domainIdentifier: "smartfolders", attributeSet: a))
            }
            let index = CSSearchableIndex.default()
            index.deleteSearchableItems(withDomainIdentifiers: ["captures", "smartfolders"]) { _ in
                index.indexSearchableItems(items) { err in
                    if let err { NSLog("OrcaFind: Spotlight indexing failed: \(err.localizedDescription)") }
                }
            }
        }
    }

    /// A Spotlight result was opened.
    static func open(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        let state = AppState.shared
        if id.hasPrefix("capture:") {
            state.openMainWindow(); state.navigate(.capture(String(id.dropFirst(8))))
            return true
        }
        if id.hasPrefix("folder:"), let uuid = UUID(uuidString: String(id.dropFirst(7))) {
            state.openMainWindow(); state.navigate(.smartFolder(uuid))
            return true
        }
        return false
    }
}

// MARK: - Services menu

/// Select text in any app, right-click › Services › Capture with Orca (Info.plist NSServices).
final class OrcaServices: NSObject {
    static let shared = OrcaServices()

    @MainActor static func register() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }

    @objc func captureText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            error.pointee = "There was no text to capture." as NSString
            return
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CaptureController.shared.startShared(SharedItem(kind: .text, text: text)) }
        }
    }
}
