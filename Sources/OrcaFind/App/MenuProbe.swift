import SwiftUI
import ScreenCaptureKit

/// Dev only: `open -n "build/Orca Find.app" --args --menu-probe <outdir>`
/// Opens the menu bar dropdown over a dark and a bright backdrop, in light and dark appearance,
/// screenshots each (needs the app's Screen Recording permission) and writes the panel's view tree.
@MainActor
enum MenuProbe {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--menu-probe"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await run(out)
            exit(0)
        }
    }

    private static func statusButton() -> NSStatusBarButton? {
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let b = find(NSStatusBarButton.self, in: w.contentView) { return b }
        }
        return nil
    }

    private static func find<T: NSView>(_ t: T.Type, in v: NSView?) -> T? {
        guard let v else { return nil }
        if let m = v as? T { return m }
        for s in v.subviews { if let m = find(t, in: s) { return m } }
        return nil
    }

    private static func tree(_ v: NSView, _ depth: Int = 0) -> String {
        var s = String(repeating: "  ", count: depth) + "\(type(of: v)) \(Int(v.frame.width))×\(Int(v.frame.height))"
        if let e = v as? NSVisualEffectView { s += " material=\(e.material.rawValue) blending=\(e.blendingMode.rawValue) state=\(e.state.rawValue)" }
        if v.isHidden { s += " hidden" }
        s += "\n"
        for c in v.subviews { s += tree(c, depth + 1) }
        return s
    }

    private static func layers(_ l: CALayer, _ depth: Int = 0) -> String {
        guard depth < 8 else { return "" }
        var s = String(repeating: "  ", count: depth) + "\(type(of: l)) \(Int(l.bounds.width))×\(Int(l.bounds.height))"
        if let f = l.filters, !f.isEmpty { s += " filters=\(f.map { String(describing: $0) })" }
        if l.backgroundColor != nil { s += " bg" }
        if l.isHidden { s += " HIDDEN" }
        s += "\n"
        for c in l.sublayers ?? [] { s += layers(c, depth + 1) }
        return s
    }

    private static func run(_ out: URL) async {
        var waited = 0
        while !AppState.shared.index.isReady && waited < 60 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
        guard let button = statusButton(), let bwin = button.window else { print("no status item"); return }
        let anchor = bwin.frame
        let backRect = NSRect(x: anchor.minX - 60, y: anchor.minY - 620, width: 520, height: 620)
        let back = NSWindow(contentRect: backRect, styleMask: [.borderless], backing: .buffered, defer: false)
        back.level = .floating
        NSApp.activate(ignoringOtherApps: true)

        var log = ""
        let backdrops: [(String, AnyView)] = [("dark-app", AnyView(DarkAppBackdrop())), ("bright", AnyView(BrightBackdrop()))]
        for (bname, view) in backdrops {
            back.contentView = NSHostingView(rootView: view.frame(width: backRect.width, height: backRect.height))
            back.orderFrontRegardless()
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try? await Task.sleep(nanoseconds: 400_000_000)
                button.performClick(nil)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let panel = NSApp.windows.first(where: { $0.isVisible && $0 !== back && $0 !== bwin && $0.frame.width > 300 && $0.frame.width < 500 }) else {
                    print("no panel"); continue
                }
                if log.isEmpty, let frame = panel.contentView?.superview {
                    log = "panel \(type(of: panel)) level=\(panel.level.rawValue) opaque=\(panel.isOpaque) bg=\(panel.backgroundColor?.description ?? "nil") glass=\(MenuLook.glass)\n" + tree(frame)
                    if let l = frame.layer { log += "\nLAYERS\n" + layers(l) }
                }
                let name = "\(bname)-\(dark ? "dark" : "light")"
                await capture(panel.frame.insetBy(dx: -24, dy: -24), to: out.appendingPathComponent(name + ".png"))
                print("captured", name)
                button.performClick(nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        try? log.write(to: out.appendingPathComponent("panel-tree.txt"), atomically: true, encoding: .utf8)
    }

    private static func capture(_ rect: NSRect, to url: URL) async {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = NSRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            config.width = Int(rect.width * screen.backingScaleFactor)
            config.height = Int(rect.height * screen.backingScaleFactor)
            config.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: img)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch { print("capture failed:", error) }
    }
}

/// A dark code editor, like the window behind the dropdown in the bug report.
private struct DarkAppBackdrop: View {
    private let widths: [CGFloat] = [180, 240, 120, 300, 210, 90, 260, 150, 330, 200, 110, 280, 170, 230, 140, 310, 190, 100, 250, 160, 290, 130, 220, 180, 270, 95, 240, 150, 300, 200, 120, 260, 170, 90, 210, 280, 140, 230, 190, 110, 250, 160]
    private let palette: [Color] = [0x569CD6, 0xCE9178, 0x9CDCFE, 0x6A9955, 0xC586C0, 0xD4D4D4, 0x4EC9B0].map { Color(hex: $0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(widths.enumerated()), id: \.offset) { i, w in
                RoundedRectangle(cornerRadius: 2).fill(palette[(i * 3) % palette.count].opacity(0.85))
                    .frame(width: w, height: 7).padding(.leading, [0, 16, 32, 48, 32, 16][i % 6])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: 0x1E1E1E))
    }
}

private struct BrightBackdrop: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "bg-liquid@2x", withExtension: "jpg", subdirectory: "Backgrounds"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            LinearGradient(colors: [.pink, .yellow, .mint, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
