import SwiftUI

/// Developer hook that renders screens to PNG without needing screen-recording permission:
/// OrcaFind --snapshot <outdir> [--root <folder with Desktop/Documents/Downloads/…>]
@MainActor
enum Snapshot {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    /// Sample smart folders for the snapshot run (its defaults are separate from the real app's).
    static func seedFolders() {
        let state = AppState.shared
        guard state.smartFolders.isEmpty else { return }
        state.smartFolders = [
            SmartFolder(name: "Acme invoices", rules: [SmartRule(field: .kind, value: "pdfs"), SmartRule(field: .text, value: "acme")],
                        lastSeen: Date().addingTimeInterval(-3 * 86_400)),
            SmartFolder(name: "Recent screenshots", rules: [SmartRule(field: .kind, value: "screenshots"), SmartRule(field: .date, value: "past month")], showOnHome: true),
            SmartFolder(name: "Tax 2026", rules: [SmartRule(field: .text, value: "tax return"), SmartRule(field: .date, value: "this year")]),
        ]
        state.refreshStats()
    }

    static func render<V: View>(_ view: V, size: NSSize, name: String, window: NSWindow) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot") else { return }
        let host = NSHostingView(rootView: view.environment(AppState.shared).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        window.setContentSize(size)
        window.contentView = host
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]).appendingPathComponent(name + ".png"))
        }
    }

    static func run() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let outDir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if let r = args.firstIndex(of: "--root"), r + 1 < args.count {
            let base = URL(fileURLWithPath: args[r + 1])
            FileIndex.overrideRoots = ["Downloads", "Desktop", "Documents", "Pictures", "Music", "Movies"].compactMap { name in
                let u = base.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: u.path) ? FileScanner.Root(url: u, name: name, maxDepth: 6) : nil
            }
        }
        let state = AppState.shared
        let prefs = Preferences.shared
        let wasOnboarded = prefs.onboarded
        prefs.onboarded = true
        state.inlineChrome = true
        FileIndex.shared.onReady.append { TidyModel.shared.scan(); DuplicatesModel.shared.scan() }
        FileIndex.shared.start()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        let size = NSSize(width: 1340, height: 900)

        struct Shot { let name: String; let dark: Bool; let setup: @MainActor () -> Void }
        let shots: [Shot] = [
            Shot(name: "01-home", dark: false) { state.navigate(.home) },
            Shot(name: "02-search", dark: false) { state.navigate(.home); state.searchText = args.firstIndex(of: "--query").map { args[$0 + 1] } ?? "screenshots with wifi password" },
            Shot(name: "03-library", dark: false) { state.navigate(.library) },
            Shot(name: "04-images", dark: false) { state.navigate(.category(.images)) },
            Shot(name: "05-downloads", dark: false) { state.navigate(.downloadedFrom(nil)) },
            Shot(name: "06-tidy", dark: false) { state.navigate(.cleanUp) },
            Shot(name: "07-duplicates", dark: false) { state.navigate(.duplicates) },
            Shot(name: "08-home-dark", dark: true) { state.navigate(.home) },
            Shot(name: "09-library-smart", dark: false) { seedFolders(); state.navigate(.library) },
            Shot(name: "10-smart-folder", dark: false) { if let f = state.smartFolders.first { state.navigate(.smartFolder(f.id)) } },
            Shot(name: "11-smart-empty", dark: false) { if let f = state.smartFolders.last { state.navigate(.smartFolder(f.id)) } },
        ]

        Task { @MainActor in
            var waited = 0
            while !FileIndex.shared.isReady && waited < 150 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            state.refreshStats()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for shot in shots {
                shot.setup()
                let host = NSHostingView(rootView: MainView().environment(state).frame(width: size.width, height: size.height))
                host.frame = NSRect(origin: .zero, size: size)
                host.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
                window.setContentSize(size)
                window.contentView = host
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(shot.name + ".png"))
                }
                state.searchText = ""
            }
            // Sheets and popovers open in their own windows, so render them on their own.
            state.navigate(.home); state.searchText = "invoices from gmail"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await render(SaveFolderPopover {}.background(DS.surface), size: NSSize(width: 380, height: 330), name: "12-save-popover", window: window)
            state.searchText = ""
            let draft = FolderDraft(folder: SmartFolder(name: "Acme invoices", rules: [SmartRule(field: .kind, value: "pdfs"), SmartRule(field: .text, value: "acme"), SmartRule(field: .date, value: "this year")]), isNew: true)
            await render(SmartFolderSheet(draft: draft), size: NSSize(width: 840, height: 590), name: "13-rules-sheet", window: window)
            prefs.onboarded = wasOnboarded
            print("snapshots written to \(outDir.path)")
            exit(0)
        }
    }
}
