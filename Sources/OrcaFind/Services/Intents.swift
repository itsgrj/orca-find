import AppIntents
import AppKit

// Shortcuts & Siri actions. They register with the system through the App Intents metadata that
// build.sh generates (appintentsmetadataprocessor). The orcafind:// URL scheme below works
// everywhere too, including from Shortcuts' "Open URL" action.

@MainActor
private func waitForIndex() async {
    var tries = 0
    while !FileIndex.shared.isReady && tries < 300 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        tries += 1
    }
}

struct FindFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Files"
    static var description = IntentDescription("Find files on your Mac using plain English, like “pdfs from last week over 5 MB”.")

    @Parameter(title: "Search", requestValueDialog: "What are you looking for?")
    var query: String

    @Parameter(title: "Limit", default: 20)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        await waitForIndex()
        let parsed = QueryParser.parse(query)
        let results = SearchEngine.run(parsed, in: FileIndex.shared.items, limit: max(1, limit))
        return .result(value: results.map { IntentFile(fileURL: $0.url, filename: $0.name) })
    }
}

struct GetLatestDownloadIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Download"
    static var description = IntentDescription("Returns the newest file in your Downloads folder.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        await waitForIndex()
        guard let item = FileIndex.shared.latestDownload else { return .result(value: nil) }
        return .result(value: IntentFile(fileURL: item.url, filename: item.name))
    }
}

struct SearchInOrcaFindIntent: AppIntent {
    static var title: LocalizedStringResource = "Search in OrcaFind"
    static var description = IntentDescription("Opens OrcaFind with your search filled in.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Search")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.openMainWindow()
        AppState.shared.searchText = query
        return .result()
    }
}

struct StartCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a Capture"
    static var description = IntentDescription("Drag over part of the screen, say why you’re keeping it, and find it later in OrcaFind.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // Let Shortcuts' own window get out of the way first.
        try? await Task.sleep(nanoseconds: 300_000_000)
        CaptureController.shared.start()
        return .result()
    }
}

struct SaveToCapturesIntent: AppIntent {
    static var title: LocalizedStringResource = "Save to Captures"
    static var description = IntentDescription("Saves a file, a link or some text to your Captures. OrcaFind listens for a note, as with any capture.")

    @Parameter(title: "File")
    var file: IntentFile?

    @Parameter(title: "Link")
    var link: URL?

    @Parameter(title: "Text")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let item: SharedItem
        if let url = file?.fileURL {
            item = SharedItem(kind: .file, title: url.lastPathComponent, path: url.path)
        } else if let link {
            item = link.isFileURL ? SharedItem(kind: .file, title: link.lastPathComponent, path: link.path) : SharedItem(kind: .page, url: link.absoluteString)
        } else if let text, !text.isEmpty {
            item = SharedItem(kind: .text, text: text)
        } else {
            throw $text.needsValueError("What should OrcaFind save?")
        }
        CaptureController.shared.startShared(item)
        return .result()
    }
}

struct OrcaFindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchInOrcaFindIntent(), phrases: ["Search in \(.applicationName)", "Find files with \(.applicationName)"],
                    shortTitle: "Search Files", systemImageName: "magnifyingglass")
        AppShortcut(intent: GetLatestDownloadIntent(), phrases: ["Get my latest download from \(.applicationName)"],
                    shortTitle: "Latest Download", systemImageName: "arrow.down.circle")
        AppShortcut(intent: StartCaptureIntent(), phrases: ["Start a capture with \(.applicationName)", "Capture with \(.applicationName)"],
                    shortTitle: "Start a Capture", systemImageName: "camera.viewfinder")
        AppShortcut(intent: SaveToCapturesIntent(), phrases: ["Save to \(.applicationName) Captures"],
                    shortTitle: "Save to Captures", systemImageName: "tray.and.arrow.down")
    }
}

/// orcafind://search?q=…, orcafind://quick-search, orcafind://voice, orcafind://duplicates,
/// orcafind://clean-up, orcafind://downloaded-from, orcafind://latest-download
@MainActor
enum URLRouter {
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "orcafind" else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        let state = AppState.shared
        switch (url.host ?? "").lowercased() {
        case "search", "find":
            state.openMainWindow()
            state.searchText = q
        case "quick-search", "quicksearch":
            QuickSearchController.shared.show(query: q)
        case "voice":
            state.openMainWindow()
            state.startVoiceSearch()
        case "duplicates":
            state.openMainWindow(); state.navigate(.duplicates)
        case "clean-up", "cleanup":
            state.openMainWindow(); state.navigate(.cleanUp)
        case "downloaded-from", "downloads":
            state.openMainWindow(); state.navigate(.downloadedFrom(nil))
        case "capture":
            // orcafind://capture/<id> opens it (links from Apple Reminders); orcafind://capture alone starts one.
            let id = url.pathComponents.dropFirst().first ?? ""
            if id.isEmpty { CaptureController.shared.start() }
            else { state.openMainWindow(); state.navigate(.capture(id)) }
        case "share":
            // From Share › Orca in another app (Extensions/OrcaShare).
            if let item = SharedItem(link: url) { CaptureController.shared.startShared(item) }
        case "captures":
            state.openMainWindow(); state.navigate(.captures)
        case "latest-download":
            if let item = FileIndex.shared.latestDownload { FileActions.revealInFinder([item]) }
        default:
            state.openMainWindow()
        }
    }
}
