import SwiftUI
import AppKit

/// Developer hooks for the editor, no UI needed:
///   OrcaFind --edit-snapshot <file> <out.png> [toolID] [dark]   renders the preview with a tool picked
///   OrcaFind --edit-selftest <file> <outdir>                    runs the kind's edits end to end and saves copies into <outdir>
@MainActor
enum EditDebug {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--edit-snapshot"), i + 2 < args.count {
            let url = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            let tool = i + 3 < args.count ? ToolID(rawValue: args[i + 3]) : nil
            let dark = args.contains("dark")
            DispatchQueue.main.async { Task { @MainActor in await snapshot(url, out: out, tool: tool, dark: dark); exit(0) } }
        }
        if let i = args.firstIndex(of: "--edit-selftest"), i + 2 < args.count {
            let url = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            DispatchQueue.main.async {
                Task { @MainActor in
                    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    guard let item = FileScanner.makeItem(url: url, rootName: "Test") else { print("FAIL can’t read \(url.path)"); exit(1) }
                    let ok: Bool
                    switch EditKind.of(item) {
                    case .photo, .screenshot: ok = await PictureWorkspace.selfTest(item, out: out)
                    case .pdf: ok = await PDFWorkspaceFactory.selfTest(item, out: out)
                    case .video, .audio: ok = await MediaWorkspaceFactory.selfTest(item, out: out)
                    case .other: print("kind: other (bar only)"); ok = true
                    }
                    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
                    exit(ok ? 0 : 1)
                }
            }
        }
    }

    static func snapshot(_ url: URL, out: URL, tool: ToolID?, dark: Bool) async {
        FontLoader.register()
        guard let item = FileScanner.makeItem(url: url, rootName: "Test") else { print("can’t read \(url.path)"); return }
        let ws = EditWorkspaces.make(for: item)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        let size = NSSize(width: 1180, height: 800)
        let host = NSHostingView(rootView: SnapshotPreview(item: item, ws: ws).environment(AppState.shared).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if let tool { ws.select(tool) }
        // Long steps (Vision, thumbnails, exports) finish before the picture is taken.
        var waited = 0
        repeat { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 } while ws.busy != nil && waited < 40
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("wrote \(out.path)")
        }
    }
}

/// The real preview, but with a workspace we can drive from the snapshot hook.
private struct SnapshotPreview: View {
    let item: FileItem
    let ws: EditWorkspace
    var body: some View {
        LargePreview(item: item, preset: ws)
    }
}

extension PictureWorkspace {
    /// Runs every picture tool's engine on a real file and saves the results.
    static func selfTest(_ item: FileItem, out: URL) async -> Bool {
        guard var img = ImageEngine.load(item.url).map(ImageEngine.normalize) else { print("FAIL load"); return false }
        var ok = true
        func save(_ i: CIImage, _ name: String, _ fmt: ImageEngine.Format = .png) {
            do {
                let d = try ImageEngine.encode(i, format: fmt, settings: .init(), source: ImageEngine.properties(item.url))
                try d.write(to: out.appendingPathComponent(name + "." + fmt.ext))
                print("ok   \(name).\(fmt.ext)  \(Fmt.size(Int64(d.count)))  \(Int(i.extent.width))×\(Int(i.extent.height))")
            } catch { print("FAIL \(name): \(error.localizedDescription)"); ok = false }
        }
        do {
            let s = try await ImageEngine.findSubjects(img)
            print("subjects: \(s.all.count)")
            if let m = s.mask(s.all) {
                save(ImageEngine.cutOut(img, mask: m, behind: .clear), "cutout")
                save(ImageEngine.cutOut(img, mask: m, behind: .blurred), "cutout-blurred", .jpeg)
                save(ImageEngine.sticker(ImageEngine.cutOut(img, mask: m, behind: .clear)), "sticker")
            } else { print("FAIL mask"); ok = false }
        } catch { print("note: no subject (\(error.localizedDescription))") }
        save(ImageEngine.autoEnhance(img), "enhanced", .jpeg)
        save(ImageEngine.adjust(img, .init(light: 20, colour: 30, warmth: 20, sharpness: 40, look: nil)), "adjusted", .jpeg)
        save(ImageEngine.adjust(img, .init(look: "CIPhotoEffectNoir")), "noir", .jpeg)
        save(ImageEngine.crop(ImageEngine.straighten(img, degrees: 5), to: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.6)), "cropped", .jpeg)
        save(ImageEngine.rotateLeft(img), "rotated", .jpeg)
        save(ImageEngine.flip(img), "flipped", .jpeg)
        img = ImageEngine.redact(img, CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.15), style: .pixelate, block: 12)
        img = ImageEngine.draw([
            .init(kind: .arrow, points: [CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.55, y: 0.45)], color: .systemRed, width: 0.006),
            .init(kind: .box, points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.8)], color: .systemBlue, width: 0.004),
            .init(kind: .text, points: [CGPoint(x: 0.05, y: 0.85)], color: .systemRed, width: 0.004, text: "Orca was here", fontSize: 0.05),
            .init(kind: .highlighter, points: [CGPoint(x: 0.1, y: 0.6), CGPoint(x: 0.4, y: 0.6)], color: .systemYellow, width: 0.006),
        ], onto: img)
        save(img, "marked-up", .jpeg)
        for f in [ImageEngine.Format.heic, .tiff, .pdf] { save(img, "format", f) }
        var small = ImageEngine.ExportSettings(); small.maxSide = 1024; small.quality = 0.6
        if let d = try? ImageEngine.encode(img, format: .jpeg, settings: small, source: ImageEngine.properties(item.url)) {
            print("ok   1024px q60 jpeg: \(Fmt.size(Int64(d.count)))")
        }
        let text = await ImageEngine.recognizeText(img)
        print("text lines: \(text.split(separator: "\n").count)")
        // The workspace itself, the way the preview drives it.
        let kind = EditKind.of(item)
        func check(_ label: String, _ run: (PictureWorkspace) async throws -> Void) async {
            let ws = PictureWorkspace(item: item, kind: kind)
            do {
                try await run(ws)
                guard ws.hasEdits else { print("FAIL \(label): no edits"); ok = false; return }
                let status = ws.status ?? ""
                let url = try await ws.save()
                let moved = out.appendingPathComponent("ws-" + url.lastPathComponent)
                try? FileManager.default.removeItem(at: moved)
                try FileManager.default.moveItem(at: url, to: moved)
                FileIndex.shared.remove(paths: [url.path])
                print("ok   ws \(label): \(url.lastPathComponent)  [\(status)]")
            } catch { print("FAIL ws \(label): \(error.localizedDescription)"); ok = false }
        }
        func waitIdle(_ ws: PictureWorkspace) async { var n = 0; while ws.busy != nil && n < 60 { try? await Task.sleep(nanoseconds: 200_000_000); n += 1 } }
        await check("remove background") { ws in ws.select(.removeBackground); await waitIdle(ws) }
        await check("redact + draw + text") { ws in
            ws.select(.redact); ws.beginDrag(at: CGPoint(x: 0.1, y: 0.1)); ws.moveDrag(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.4, y: 0.3)); ws.endDrag(at: CGPoint(x: 0.4, y: 0.3))
            ws.select(.arrow); ws.beginDrag(at: CGPoint(x: 0.9, y: 0.1)); ws.moveDrag(from: CGPoint(x: 0.9, y: 0.1), to: CGPoint(x: 0.6, y: 0.4)); ws.endDrag(at: CGPoint(x: 0.6, y: 0.4))
            ws.select(.text); ws.endDrag(at: CGPoint(x: 0.05, y: 0.8)); ws.textDraft?.text = "Orca"; ws.commitText()
        }
        await check("crop + convert") { ws in
            ws.select(.crop); ws.aspect = .square; ws.select(.convert); ws.export.format = .jpeg; ws.export.maxSide = 256
        }
        await check("enhance + rotate + undo") { ws in ws.select(.enhance); ws.select(.rotate); ws.select(.flip); ws.undo() }
        return ok
    }
}
