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
        let host = NSHostingView(rootView: view.environment(AppState.shared).environment(CaptureLibrary.shared).frame(width: size.width, height: size.height))
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

    /// OrcaFind --snapshot <outdir> --scroll-bench: opens Tidy off-screen, scrolls it
    /// down and back in small steps, and prints how long each step took to lay out and draw.
    static func scrollBench(window: NSWindow, size: NSSize) async {
        let state = AppState.shared
        // Wait for the Tidy scans so the cards hold real numbers and thumbnails.
        var waited = 0
        while (TidyModel.shared.isScanning || DuplicatesModel.shared.isScanning) && waited < 600 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        state.navigate(.cleanUp)
        let host = NSHostingView(rootView: MainView().environment(state).environment(CaptureLibrary.shared).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        window.contentView = host
        window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        func scrollViews(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        guard let sv = scrollViews(host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else {
            print("bench: no scroll view found"); return
        }
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
        print("bench: content \(Int(sv.documentView?.frame.height ?? 0)) pt, can scroll \(Int(maxY)) pt")
        var times: [Double] = []
        for pass in 0..<3 {
            let steps = stride(from: 0.0, through: Double(maxY), by: 8).map { $0 }
            for y in (pass % 2 == 0 ? steps : steps.reversed()) {
                let t0 = CFAbsoluteTimeGetCurrent()
                sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                sv.reflectScrolledClipView(sv.contentView)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }
        let sorted = times.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        print(String(format: "bench: %d steps · median %.2f ms · p90 %.2f ms · p99 %.2f ms · max %.2f ms · over 16 ms: %d",
                     times.count, pct(0.5), pct(0.9), pct(0.99), sorted.last ?? 0, times.filter { $0 > 16 }.count))
        layerReport(host, "tidy")
        state.navigate(.home)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        layerReport(host, "home")
    }

    /// What the render server has to put together each frame: how many layers, how big their pictures are.
    static func layerReport(_ host: NSView, _ label: String) {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); CATransaction.flush()
        guard let root = host.layer else { print("bench \(label): no layer"); return }
        var count = 0, withContents = 0, pixels = 0, shadows = 0, masks = 0, filters = 0, bigImages: [String] = []
        var types: [String: Int] = [:]
        func walk(_ l: CALayer, _ depth: Int) {
            count += 1
            types[String(describing: type(of: l)), default: 0] += 1
            if l.shadowOpacity > 0 { shadows += 1 }
            if l.mask != nil || l.masksToBounds && l.cornerRadius > 0 { masks += 1 }
            if !(l.filters ?? []).isEmpty || !(l.backgroundFilters ?? []).isEmpty || l.compositingFilter != nil { filters += 1 }
            if let c = l.contents {
                withContents += 1
                let cf = c as CFTypeRef
                if CFGetTypeID(cf) == CGImage.typeID {
                    let img = c as! CGImage
                    pixels += img.width * img.height
                    let shown = l.bounds.size.width * l.contentsScale
                    if img.width > 300 || Double(img.width) > shown * 2.5 { bigImages.append("\(img.width)x\(img.height) shown at \(Int(l.bounds.width))x\(Int(l.bounds.height))") }
                } else if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                    let s = c as! IOSurfaceRef
                    pixels += IOSurfaceGetWidth(s) * IOSurfaceGetHeight(s)
                    if IOSurfaceGetWidth(s) > 300 { bigImages.append("surface \(IOSurfaceGetWidth(s))x\(IOSurfaceGetHeight(s)) shown at \(Int(l.bounds.width))x\(Int(l.bounds.height))") }
                }
            }
            l.sublayers?.forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
        print("bench \(label): \(count) layers · \(withContents) with pictures · \(pixels / 1_000_000) M pixels · shadows \(shadows) · masks \(masks) · filters \(filters)")
        print("bench \(label): types \(types.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        let grouped = Dictionary(grouping: bigImages, by: { $0 }).map { "\($0.value.count)× \($0.key)" }.sorted()
        grouped.prefix(25).forEach { print("bench \(label):   \($0)") }
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
        if args.contains("--captures-only") { runCaptures(outDir); return }
        if args.contains("--design") { DesignSnapshots.run(outDir); return }
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
            if args.contains("--scroll-bench") { await scrollBench(window: window, size: size); exit(0) }
            for shot in shots {
                shot.setup()
                let host = NSHostingView(rootView: MainView().environment(state).environment(CaptureLibrary.shared).frame(width: size.width, height: size.height))
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
            var long = FolderDraft(folder: SmartFolder(name: "", rules: []), isNew: true)
            long.description = "All pictures that have blue colored theme or design in them, especially screenshots and wallpapers I saved this year"
            await render(SmartFolderSheet(draft: long), size: NSSize(width: 840, height: 590), name: "13b-rules-sheet-long", window: window)
            prefs.onboarded = wasOnboarded
            print("snapshots written to \(outDir.path)")
            exit(0)
        }
    }
}
