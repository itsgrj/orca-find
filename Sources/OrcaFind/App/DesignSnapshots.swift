import SwiftUI

/// Extra screens for keeping the Figma file in sync with the app (dev only):
/// `ORCA_CAPTURES_DIR=<scratch> OrcaFind --snapshot <outdir> --root <fakehome> --design`
/// Renders every main-window state and the separate windows/panels that `--snapshot` alone doesn't cover.
@MainActor
enum DesignSnapshots {
    static func run(_ outDir: URL) {
        let state = AppState.shared
        let prefs = Preferences.shared
        prefs.onboarded = true
        state.inlineChrome = true
        if ProcessInfo.processInfo.environment["ORCA_CAPTURES_DIR"] != nil {
            if CaptureStore.shared.all().isEmpty { Snapshot.seedCaptures() }
            CaptureLibrary.shared.reload()
        }
        FileIndex.shared.onReady.append { TidyModel.shared.scan(); DuplicatesModel.shared.scan() }
        FileIndex.shared.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        let main = NSSize(width: 1340, height: 900)

        @MainActor func shot<V: View>(_ v: V, _ name: String, _ size: NSSize = main, dark: Bool = false, wait: Double = 2.0,
                                      midway: (@MainActor () -> Void)? = nil) async {
            let host = NSHostingView(rootView: v.environment(state).environment(CaptureLibrary.shared).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(size)
            window.contentView = host
            window.orderFront(nil)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            // A change made while the view is already on screen (typing on Home), not before it first appears.
            if let midway { midway(); try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name + ".png"))
            }
        }
        func reset() { state.searchText = ""; state.selection = []; state.showInspector = false; state.toast = nil; state.filters = BrowserFilters(); prefs.viewMode = .grid; RecentlyRemovedScreen.snapshotQuery = nil }
        let only = CommandLine.arguments.firstIndex(of: "--only").map { CommandLine.arguments[$0 + 1].split(separator: ",").map(String.init) }
        func want(_ n: String) -> Bool { only.map { $0.contains { n.hasPrefix($0) } } ?? true }

        Task { @MainActor in
            var waited = 0
            while !FileIndex.shared.isReady && waited < 150 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            Snapshot.seedFolders()
            state.refreshStats()
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            // Main window states
            let mainShots: [(String, Bool, @MainActor () -> Void)] = [
                ("m01-home", false, { state.navigate(.home) }),
                ("m01-home-dark", true, { state.navigate(.home) }),
                ("m02-search-wifi", false, { state.navigate(.home); state.searchText = "screenshots with wifi password" }),
                ("m02-search-invoices", false, { state.navigate(.home); state.searchText = "invoices from gmail" }),
                ("m02-search-photos", false, { state.navigate(.home); state.searchText = "photos from last week" }),
                ("m02-search-none", false, { state.navigate(.home); state.searchText = "zebra spreadsheet from 1999" }),
                ("m02-search-wifi-dark", true, { state.navigate(.home); state.searchText = "screenshots with wifi password" }),
                ("m03-voice-listening", false, { state.navigate(.home); state.voice.owner = "main"; state.voice.isListening = true; state.voice.level = 0.6; state.voice.transcript = "" }),
                ("m03-voice-heard", false, { state.navigate(.home); state.voice.owner = "main"; state.voice.isListening = true; state.voice.level = 0.4; state.voice.transcript = "screenshots with wifi password" }),
                ("m04-library", false, { state.voice.isListening = false; state.navigate(.library) }),
                ("m04-library-dark", true, { state.navigate(.library) }),
                ("m05-images", false, { state.navigate(.category(.images)) }),
                ("m05-images-list", false, { prefs.viewMode = .list; state.navigate(.category(.images)) }),
                ("m05-images-selection", false, { state.navigate(.category(.images)); state.selection = Set(state.visibleItems.prefix(3).map(\.id)) }),
                ("m05-images-inspector", false, { state.navigate(.category(.images)); if let f = state.visibleItems.first { state.selection = [f.id] }; state.showInspector = true }),
                ("m05-images-toast", false, { state.navigate(.category(.images)); state.showToast("Moved 2 items to the Trash", undo: {}) }),
                ("m06-videos", false, { state.navigate(.category(.videos)) }),
                ("m06-music", false, { state.navigate(.category(.music)) }),
                ("m06-documents", false, { state.navigate(.category(.documents)) }),
                ("m06-archives", false, { state.navigate(.category(.archives)) }),
                ("m06-apps", false, { state.navigate(.category(.apps)) }),
                ("m06-recents", false, { state.navigate(.recents) }),
                ("m06-screenshots", false, { state.navigate(.screenshots) }),
                ("m06-large", false, { state.navigate(.largeFiles) }),
                ("m07-downloads", false, { state.navigate(.downloadedFrom(nil)) }),
                ("m07-downloads-dark", true, { state.navigate(.downloadedFrom(nil)) }),
                ("m07-downloads-source", false, { state.navigate(.downloadedFrom(state.homeStats.sources.first?.source.key)) }),
                ("m08-tidy", false, { state.navigate(.cleanUp) }),
                ("m08-tidy-dark", true, { state.navigate(.cleanUp) }),
                ("m08-review-downloads", false, { state.navigate(.cleanUpReview(.forgottenDownloads)) }),
                ("m08-review-installers", false, { state.navigate(.cleanUpReview(.oldInstallers)) }),
                ("m08-review-screenshots", false, { state.navigate(.cleanUpReview(.oldScreenshots)) }),
                ("m09-duplicates", false, { state.navigate(.duplicates) }),
                ("m10-smart-folder", false, { if let f = state.smartFolders.first { state.navigate(.smartFolder(f.id)) } }),
                ("m10-smart-empty", false, { if let f = state.smartFolders.last { state.navigate(.smartFolder(f.id)) } }),
                ("m11-captures", false, { state.navigate(.captures) }),
                ("m11-captures-dark", true, { state.navigate(.captures) }),
                // Recently removed (Figma "Proposals · Recently removed"); data comes from removed.json in ORCA_CAPTURES_DIR.
                ("r01-tidy-entry", false, { state.navigate(.cleanUp) }),
                ("r01-tidy-entry-dark", true, { state.navigate(.cleanUp) }),
                ("r02-removed-list", false, { prefs.removedTimeline = false; state.navigate(.recentlyRemoved) }),
                ("r02-removed-list-dark", true, { prefs.removedTimeline = false; state.navigate(.recentlyRemoved) }),
                ("r03-removed-timeline", false, { prefs.removedTimeline = true; state.navigate(.recentlyRemoved) }),
                ("r03-removed-timeline-dark", true, { prefs.removedTimeline = true; state.navigate(.recentlyRemoved) }),
                ("r05-toast-see-removed", false, { prefs.removedTimeline = false; state.navigate(.category(.images)); state.showToast("Moved 3 items to the Trash · 2.4 MB", undo: {}, seeRemoved: true) }),
                ("r05-toast-see-removed-dark", true, { state.navigate(.category(.images)); state.showToast("Moved 3 items to the Trash · 2.4 MB", undo: {}, seeRemoved: true) }),
                ("r08-captures-deleted", false, { state.capturesFolder = nil; state.navigate(.captures); state.showToast("Capture deleted · kept 30 days", undo: {}, seeRemoved: true) }),
                ("r08-captures-deleted-dark", true, { state.capturesFolder = nil; state.navigate(.captures); state.showToast("Capture deleted · kept 30 days", undo: {}, seeRemoved: true) }),
                ("r09-home-lookalike", false, { state.navigate(.home); state.searchText = "sigmaflow" }),
                ("r09-home-lookalike-dark", true, { state.navigate(.home); state.searchText = "sigmaflow" }),
                ("r10-removed-search-none", false, { RecentlyRemovedScreen.snapshotQuery = "sigmaflow"; state.navigate(.home); state.navigate(.recentlyRemoved) }),
                ("r10-removed-search-none-dark", true, { RecentlyRemovedScreen.snapshotQuery = "sigmaflow"; state.navigate(.home); state.navigate(.recentlyRemoved) }),
            ]
            for (name, dark, setup) in mainShots where want(name) {
                reset(); setup()
                await shot(MainView(), name, dark: dark, wait: 2.2)
            }
            // Typing on Home once it's showing: the results must fill the window under the card.
            if want("m03") {
                reset(); state.navigate(.home)
                await shot(MainView(), "m03-home-then-type", wait: 2.2, midway: { state.searchText = "s" })
            }
            state.voice.isListening = false; reset()

            // More states: list view for every kind, the Reminders folder, a capture detail — light and dark.
            let firstCapture = CaptureLibrary.shared.items.first?.id
            let extra: [(String, @MainActor () -> Void)] = [
                ("x01-documents-list", { prefs.viewMode = .list; state.navigate(.category(.documents)) }),
                ("x01-music-list", { prefs.viewMode = .list; state.navigate(.category(.music)) }),
                ("x01-archives-list", { prefs.viewMode = .list; state.navigate(.category(.archives)) }),
                ("x01-screenshots-list", { prefs.viewMode = .list; state.navigate(.screenshots) }),
                ("x01-recents-list", { prefs.viewMode = .list; state.navigate(.recents) }),
                ("x02-captures-reminders", { state.capturesFolder = .reminders; state.navigate(.captures) }),
                ("x02-captures-unsorted", { state.capturesFolder = .unsorted; state.navigate(.captures) }),
                ("x03-capture-detail", { if let id = firstCapture { state.navigate(.capture(id)) } }),
            ]
            for (name, setup) in extra where want(name) {
                for dark in [false, true] {
                    reset(); state.capturesFolder = nil; setup()
                    await shot(MainView(), dark ? name + "-dark" : name, dark: dark, wait: 2.2)
                }
            }
            reset(); state.capturesFolder = nil

            // Dark twin of every light main-window state (--dark-all).
            if CommandLine.arguments.contains("--dark-all") {
                for (name, dark, setup) in mainShots where !dark && want(name) && !mainShots.contains(where: { $0.0 == name + "-dark" }) {
                    reset(); setup()
                    await shot(MainView(), name + "-dark", dark: true, wait: 2.2)
                }
                state.voice.isListening = false; reset()
                for p in SettingsView.Pane.allCases where p != .general {
                    let slug = p.rawValue.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
                    await shot(SettingsView(pane: p), "s-\(slug)-dark", NSSize(width: 860, height: 640), dark: true)
                }
                prefs.onboarded = false
                await shot(OnboardingView(showAI: true), "o02-onboarding-ai-dark", dark: true)
                prefs.onboarded = true
                let qm = QuickSearchModel()
                await shot(QuickSearchView(model: qm), "q01-quick-empty-dark", NSSize(width: 700, height: 480), dark: true)
                await shot(MenuBarView().fixedSize(), "b01-menubar-dark", NSSize(width: 460, height: 640), dark: true)
            }

            // Onboarding (shown over the main window until onboarded)
            if want("o") {
                prefs.onboarded = false
                await shot(OnboardingView(), "o01-onboarding")
                await shot(OnboardingView(step: .look), "o03-onboarding-look")
                await shot(OnboardingView(step: .access), "o04-onboarding-access", wait: 3)
                await shot(OnboardingView(showAI: true), "o02-onboarding-ai")
                await shot(OnboardingView(), "o01-onboarding-dark", dark: true)
                prefs.onboarded = true
            }

            // Settings window, every pane
            if want("s") {
                for p in SettingsView.Pane.allCases {
                    let slug = p.rawValue.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
                    await shot(SettingsView(pane: p), "s-\(slug)", NSSize(width: 860, height: 640))
                }
                await shot(SettingsView(pane: .general), "s-general-dark", NSSize(width: 860, height: 640), dark: true)
            }

            // Quick Search panel and menu bar
            if want("q") {
                let qm = QuickSearchModel()
                await shot(QuickSearchView(model: qm), "q01-quick-empty", NSSize(width: 700, height: 480))
                qm.query = "invoices"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await shot(QuickSearchView(model: qm), "q02-quick-results", NSSize(width: 700, height: 480))
                await shot(QuickSearchView(model: qm), "q02-quick-results-dark", NSSize(width: 700, height: 480), dark: true)
            }
            if want("b") {
                let menu = NSSize(width: 460, height: 640)
                await shot(MenuBarView().fixedSize(), "b01-menubar", menu)
                await shot(MenuBarView().fixedSize(), "b01-menubar-dark", menu, dark: true)
                MenuUI.shared.tab = .images
                await shot(MenuBarView().fixedSize(), "b02-menubar-images", menu)
                MenuUI.shared.tab = .notes
                await shot(MenuBarView().fixedSize(), "b02-menubar-notes", menu)
                MenuUI.shared.tab = .all
                MenuBarController.shared.search.query = "invoice"
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await shot(MenuBarView().fixedSize(), "b03-menubar-search", menu)
                MenuBarController.shared.search.query = ""
                await shot(MenuDropPanel().fixedSize(), "b04-drop-panel", NSSize(width: 400, height: 420))
                MenuUI.shared.toast = MenuToastInfo(message: "Moved brand-board-v3.jpg to Design", undo: {})
                await shot(MenuToastView().fixedSize(), "b05-menu-toast", NSSize(width: 400, height: 80))
                MenuUI.shared.toast = nil
                await shot(DropShelfView(notch: 32).fixedSize().background(Color(white: 0.85)), "b06-shelf-notch", NSSize(width: 760, height: 240))
                await shot(DropShelfView(notch: 0).fixedSize(), "b07-shelf-no-notch", NSSize(width: 760, height: 220))
                await shot(SortPlanSheet(plan: SortDownloads.plan(FileIndex.shared.items, now: Date().addingTimeInterval(3600))) {}, "b08-sort-plan", NSSize(width: 560, height: 560))
            }
            if want("i") {
                state.navigate(.category(.images))
                if let f = state.visibleItems.first { await shot(InspectorPanel(item: f).background(DS.surface), "i01-inspector-image", NSSize(width: 300, height: 860)) }
                state.navigate(.category(.documents))
                if let f = state.visibleItems.first { await shot(InspectorPanel(item: f).background(DS.surface), "i02-inspector-doc", NSSize(width: 300, height: 860)) }
            }
            print("design snapshots written to \(outDir.path)")
            exit(0)
        }
    }
}
