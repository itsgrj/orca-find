import SwiftUI
import Quartz

@main
struct OrcaFindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    init() {
        DebugCLI.runIfRequested()
    }

    var body: some Scene {
        Window("Orca Find", id: "main") {
            MainView()
                .environment(state)
                .frame(minWidth: 1080, minHeight: 720)
                .onOpenURL { URLRouter.handle($0) }
        }
        .defaultSize(width: 1340, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(state: state) }

        Settings {
            SettingsView()
                .environment(state)
        }

        MenuBarExtra("Orca Find", systemImage: "magnifyingglass.circle", isInserted: Binding(
            get: { state.prefs.showMenuBar }, set: { state.prefs.showMenuBar = $0 })) {
            MenuBarView()
                .environment(state)
        }
        .menuBarExtraStyle(.window)
    }
}

struct AppCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open") { state.openSelection() }
                .keyboardShortcut("o")
            Button("Show in Finder") { FileActions.revealInFinder(state.selectedItems) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Pin Folder to Sidebar") { if let i = state.selectedItems.first { state.pin(i) } }
                .keyboardShortcut("p", modifiers: [.command, .control])
            Divider()
            Button("Copy Path") { FileActions.copyPath(state.selectedItems) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Move to Trash") { state.trashSelection() }
        }

        CommandMenu("Find") {
            Button("Quick Search (\(state.prefs.quickSearchHotKey.display))") { QuickSearchController.shared.toggle() }
            Button("Search") { state.focusSearch() }
                .keyboardShortcut("f")
            Button("Search by Voice") { state.focusSearch(); state.startVoiceSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Save as Smart Folder…") { state.showSaveFolder = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(state.searchText.isEmpty || state.section != .search)
            Button("New Smart Folder…") { state.openMainWindow(); state.newFolderSheet() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Downloaded From") { state.navigate(.downloadedFrom(nil)) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button("Copy Text from Images") { state.copyTextFromSelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Inspector") { state.showInspector.toggle() }
                .keyboardShortcut("i")
            Button("Search (⌘K)") { state.focusSearch() }
                .keyboardShortcut("k")
        }

        CommandGroup(before: .toolbar) {
            Button("as Grid") { state.prefs.viewMode = .grid }
                .keyboardShortcut("1")
            Button("as List") { state.prefs.viewMode = .list }
                .keyboardShortcut("2")
            Divider()
            Button("Bigger Cards") { state.biggerCards() }
                .keyboardShortcut("+")
            Button("Bigger Cards") { state.biggerCards() }
                .keyboardShortcut("=")
            Button("Smaller Cards") { state.smallerCards() }
                .keyboardShortcut("-")
            Divider()
            Button("Quick Look (Space)") { state.toggleQuickLook() }
            Button("Light / Dark") { state.prefs.toggleDark() }
                .keyboardShortcut("t", modifiers: [.command, .control])
            Divider()
        }

        CommandMenu("Go") {
            Button("Home") { state.navigate(.home) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Library") { state.navigate(.library) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Recents") { state.navigate(.recents) }
            ForEach(FileCategory.library) { c in
                Button(c.title) { state.navigate(.category(c)) }
            }
            Divider()
            Button("Screenshots") { state.navigate(.screenshots) }
            Button("Large Files") { state.navigate(.largeFiles) }
            Divider()
            Button("Duplicates") { state.navigate(.duplicates) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Clean Up") { state.navigate(.cleanUp) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }

        CommandMenu("Music") {
            Button(state.player.isPlaying ? "Pause" : "Play") { state.player.toggle() }
                .keyboardShortcut(.space, modifiers: .command)
                .disabled(state.player.current == nil)
            Button("Next Song (⌘→)") { state.player.next() }
                .disabled(state.player.current == nil)
            Button("Previous Song (⌘←)") { state.player.previous() }
                .disabled(state.player.current == nil)
            Divider()
            Button("Stop") { state.player.stop() }
                .disabled(state.player.current == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            FontLoader.register()
            if Snapshot.requested {
                NSApp.windows.forEach { $0.orderOut(nil) }
                Snapshot.run()
                return
            }
            let prefs = Preferences.shared
            NSApp.appearance = prefs.appearance.nsAppearance
            HotKeyCenter.shared.handler = { QuickSearchController.shared.toggle() }
            HotKeyCenter.shared.register(prefs.quickSearchHotKey)
            _ = AppState.shared
            FileIndex.shared.onReady.append {
                TidyModel.shared.scan()
            }
            FileIndex.shared.start()
            // Load MobileCLIP in the background so the first description search is instant.
            if prefs.smartPictures { MobileCLIP.warmUp() }
            AutoCleanup.shared.start()
            installKeyMonitor()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppState.shared.openMainWindow() } }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(URLRouter.handle) }
    }

    // Quick Look panel control lives at the end of the responder chain.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookCoordinator.shared
            panel.delegate = QuickLookCoordinator.shared
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { KeyRouter.handle(event) } ? nil : event
        }
    }
}

/// Finder-style keys for the main window: Space = Quick Look, arrows move the selection,
/// Return opens, ⌘⌫ trashes, ⌘C copies files, ⌘←/⌘→ skip songs. Text fields keep their keys.
@MainActor
enum KeyRouter {
    static func handle(_ e: NSEvent) -> Bool {
        let state = AppState.shared
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(e.keyCode)
        let arrow: MoveDirection? = [123: .left, 124: .right, 125: .down, 126: .up][code]

        // Keys while the Quick Look panel is in front.
        if let w = e.window, w is QLPreviewPanel {
            if code == 49 && mods.isEmpty { QuickLookCoordinator.shared.close(); return true }
            if let arrow, mods.isEmpty { state.quickLookMove(arrow); return true }
            return false
        }

        guard let window = e.window, window === state.mainWindow, window.attachedSheet == nil else { return false }
        let typing = window.firstResponder is NSTextView

        if typing {
            // ↓ from the search field jumps into the results.
            if code == 125 && mods.isEmpty && state.section.isBrowser && !state.visibleItems.isEmpty
                && state.prefs.viewMode == .grid && state.section == .search {
                window.makeFirstResponder(nil)
                state.moveSelection(.right)
                return true
            }
            return false
        }

        let inTable = window.firstResponder is NSTableView

        switch (code, mods) {
        case (49, []):
            state.toggleQuickLook(); return true
        case (_, []) where arrow != nil:
            guard state.section.isBrowser || isReview(state.section) else { return false }
            if inTable || state.prefs.viewMode == .list { return false }
            state.moveSelection(arrow!); return true
        case (36, []), (76, []):
            guard !state.selection.isEmpty else { return false }
            state.openSelection(); return true
        case (51, [.command]):
            guard !state.selection.isEmpty else { return false }
            state.trashSelection(); return true
        case (8, [.command]):
            guard !state.selection.isEmpty else { return false }
            FileActions.copy(state.selectedItems)
            state.showToast("Copied \(Fmt.plural(state.selection.count, "file"))")
            return true
        case (0, [.command]):
            guard state.section.isBrowser else { return false }
            state.selectAll(); return true
        case (123, [.command]):
            guard state.player.current != nil else { return false }
            state.player.previous(); return true
        case (124, [.command]):
            guard state.player.current != nil else { return false }
            state.player.next(); return true
        case (53, []):
            if !state.selection.isEmpty { state.selection = []; return true }
            return false
        default:
            return false
        }
    }

    private static func isReview(_ s: AppSection) -> Bool {
        if case .cleanUpReview = s { return true }
        return false
    }
}
