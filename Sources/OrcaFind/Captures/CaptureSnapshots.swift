import SwiftUI
import AVFoundation

/// `ORCA_CAPTURES_DIR=/tmp/x OrcaFind --snapshot <out> --captures-only` renders the capture screens with sample data.
/// Refuses to seed the real library.
extension Snapshot {
    static func runCaptures(_ outDir: URL) {
        guard ProcessInfo.processInfo.environment["ORCA_CAPTURES_DIR"] != nil else {
            print("Set ORCA_CAPTURES_DIR to a scratch folder first (samples are never written to your real captures)."); exit(1)
        }
        let state = AppState.shared
        state.inlineChrome = true
        Preferences.shared.onboarded = true
        if CaptureStore.shared.all().isEmpty { seedCaptures() }
        CaptureLibrary.shared.reload()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        let size = NSSize(width: 1340, height: 900)

        Task { @MainActor in
            // Let the menu bar extra finish setting up first, or SwiftUI deadlocks on its update lock.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            @MainActor func shot<V: View>(_ v: V, _ name: String, _ sz: NSSize, dark: Bool = false) async {
                let host = NSHostingView(rootView: v.environment(state).environment(CaptureLibrary.shared).frame(width: sz.width, height: sz.height))
                host.frame = NSRect(origin: .zero, size: sz)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(sz)
                window.contentView = host
                window.orderFront(nil)
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name + ".png"))
                }
            }
            state.navigate(.captures)
            await shot(MainView(), "20-captures", size)
            if let col = CaptureLibrary.shared.collections.first?.name {
                state.capturesFolder = .collection(col)
                await shot(MainView(), "20b-folder", size)
                if let t = CaptureLibrary.countTags(CaptureLibrary.shared.items.filter { $0.collection == col }).first?.name {
                    state.capturesTag = t
                    await shot(MainView(), "20c-folder-tag", size)
                }
                state.capturesFolder = nil
            }
            if let t = CaptureLibrary.shared.tags.first?.name {
                state.capturesTag = t
                await shot(MainView(), "20d-tag-everywhere", size)
            }
            state.capturesTag = nil
            if let tagged = CaptureLibrary.shared.items.first(where: { !$0.hasClip && $0.tagList.count >= 2 }) {
                state.navigate(.capture(tagged.id))
                await shot(MainView(), "21b-detail-tags", size)
            }
            for title in ["Miso butter pasta", "Week 4 · Supply and demand"] {
                if let c = CaptureLibrary.shared.items.first(where: { $0.title == title }) {
                    state.navigate(.capture(c.id))
                    await shot(MainView(), title.hasPrefix("Miso") ? "21c-detail-feed-item" : "21d-detail-video-moment", size)
                }
            }
            state.navigate(.home)
            state.searchText = "that pricing thread I saved for the newsletter"
            await shot(MainView(), "30-search-captures", size)
            state.searchText = "#design"
            await shot(MainView(), "31-search-tag", size)
            state.searchText = ""
            state.navigate(.captures)
            await shot(AddTagPopover(existing: CaptureLibrary.shared.tagNames, have: ["pricing"]) { _ in }, "29-add-tag", NSSize(width: 300, height: 270))
            if let first = CaptureLibrary.shared.items.first {
                state.navigate(.capture(first.id))
                await shot(MainView(), "21-capture-detail", size)
                state.navigate(.captures)
                state.capturesQuery = "pricing newsletter"
                await shot(MainView(), "22-captures-search", size)
                state.capturesQuery = ""
                await shot(MainView(), "23-captures-dark", size, dark: true)

                let img = NSImage(contentsOf: first.imageURL)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                let s = CaptureSession(image: img, pointSize: CGSize(width: 599, height: 412), context: CaptureContext())
                s.pageURL = "https://x.com/priyabuilds/status/1855012"
                s.recorder.transcript = "Pricing thread for Friday’s newsletter. The forty percent bit is the hook. Remind me Thursday to write it up"
                s.recorder.elapsed = 7
                s.recorder.levels = (0..<28).map { i in i < 20 ? Float.random(in: 0.1...0.95) : 0 }
                await shot(CaptureStripView(session: s).padding(20).background(Color(hex: 0xDADDE2)), "24-strip-recording", NSSize(width: 640, height: 178))
                s.clip = ClipRecorder(); s.clipMoving = true
                s.recorder.transcript = "Watch how the bars grow one after another. Want this for the SigmaFlow dashboard, tag it motion"
                await shot(CaptureStripView(session: s).padding(20).background(Color(hex: 0xDADDE2)), "24b-strip-clip", NSSize(width: 640, height: 178))
                await shot(CaptureStripView(session: s).padding(20).background(Color(hex: 0xDADDE2)), "24c-strip-clip-narrow", NSSize(width: 500, height: 178))
                s.clip = nil
                s.recorder.transcript = String(repeating: "I like this picture a lot, the way the light falls on the subject on the edges, and I want to use it for one of the designs of the SigmaFlow site. ", count: 4)
                s.stripMaxText = 150
                await shot(CaptureStripView(session: s).padding(20).background(Color(hex: 0xDADDE2)), "24d-strip-long", NSSize(width: 640, height: 330))
                s.mode = .typing; s.typed = "pricing thread for the newsletter"
                await shot(CaptureStripView(session: s).padding(20).background(Color(hex: 0xDADDE2)), "25-strip-typing", NSSize(width: 640, height: 178))
                // Share › Orca: the same strip with "what you're saving" on top, one per kind of thing.
                let shares: [(SharedItem, String?, CGImage?)] = [
                    (SharedItem(kind: .page, url: "https://x.com/priyabuilds/status/1855012", title: "Priya Shah on X: “We raised prices 40%…”"), "Safari", img),
                    (SharedItem(kind: .photo, title: "IMG_4821"), "Photos", img),
                    (SharedItem(kind: .file, path: "/Users/someone/Documents/Q3 pricing deck.pdf"), "Finder", img),
                    (SharedItem(kind: .text, text: "The best pricing pages answer one question: what happens when I outgrow this plan?"), "Notes",
                     ShareImages.card("The best pricing pages answer one question: what happens when I outgrow this plan?", footer: "Notes")),
                ]
                for (i, (item, app, picture)) in shares.enumerated() {
                    var ctx = CaptureContext(); ctx.appName = app
                    let ss = CaptureSession(image: picture ?? img, pointSize: CGSize(width: 900, height: 600), context: ctx)
                    ss.shared = item
                    ss.pageURL = item.kind == .page ? item.url : nil
                    ss.recorder.transcript = i == 0 ? "Pricing thread for Friday’s newsletter, the forty percent bit is the hook" : ""
                    ss.recorder.elapsed = 4
                    ss.recorder.levels = (0..<28).map { j in j < 14 ? Float.random(in: 0.1...0.9) : 0 }
                    await shot(CaptureStripView(session: ss).padding(20).background(Color(hex: 0xDADDE2)), "25s\(i)-strip-shared-\(item.kind.rawValue)", NSSize(width: 600, height: 250))
                }
                await shot(SavedCardView(captureID: first.id, undo: {}, open: {}, hover: { _ in }).padding(20).background(Color(hex: 0xDADDE2)),
                           "26-saved", NSSize(width: 420, height: 152))
            }
            await shot(NewCollectionPopover(existing: ["Newsletter", "Recipes"]) { _ in }, "28-new-collection", NSSize(width: 300, height: 230))
            await shot(CapturesSettings().padding(24).background(DS.surface), "27-settings", NSSize(width: 660, height: 1040))
            await shot(VoiceNotesTip(preview: true).padding(24).background(DS.app), "32-voice-tip", NSSize(width: 1100, height: 120))
            await shot(VoiceNotesTip(preview: true).padding(24).background(DS.app), "32b-voice-tip-dark", NSSize(width: 1100, height: 120), dark: true)
            print("capture snapshots written to \(outDir.path)")
            exit(0)
        }
    }

    /// Sample captures drawn on the fly (post, product, recipe card, lecture slide, quote…).
    static func seedCaptures() {
        struct Sample { let note: String; let title: String; let url: String?; let app: String; let ocr: String; let daysAgo: Double; let draw: (CGContext, CGSize) -> Void }
        func text(_ ctx: CGContext, _ s: String, _ rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black, serif: Bool = false) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let font = serif ? (NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)) : NSFont.systemFont(ofSize: size, weight: weight)
            (s as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color])
            NSGraphicsContext.restoreGraphicsState()
        }
        func fill(_ ctx: CGContext, _ hex: UInt32, _ r: CGRect, radius: CGFloat = 0) {
            ctx.setFillColor(NSColor(hex: hex).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
        }
        let samples: [Sample] = [
            Sample(note: "Pricing thread for Friday’s newsletter. The forty percent bit is the hook. Remind me Thursday to write it up.",
                   title: "Priya Shah on X", url: "https://x.com/priyabuilds/status/1855012", app: "Google Chrome",
                   ocr: "Priya Shah @priyabuilds · We raised prices 40% last spring and lost almost no one. Here’s exactly what we changed, in order.", daysAgo: 0.1) { c, s in
                fill(c, 0xFFFFFF, CGRect(origin: .zero, size: s))
                fill(c, 0xC2410C, CGRect(x: 24, y: s.height - 70, width: 44, height: 44), radius: 22)
                text(c, "Priya Shah  @priyabuilds · 4h", CGRect(x: 80, y: s.height - 52, width: 500, height: 24), size: 16, weight: .semibold)
                text(c, "We raised prices 40% last spring and lost almost no one. Here’s exactly what we changed, in order.\n\n1/ We stopped selling seats and started selling outcomes.", CGRect(x: 80, y: s.height - 170, width: 500, height: 110), size: 15)
                fill(c, 0xF6F7F8, CGRect(x: 80, y: 30, width: 490, height: 170), radius: 12)
                for i in 0..<8 { fill(c, i < 5 ? 0xD1D5DB : 0xC2410C, CGRect(x: 100 + i * 56, y: 50, width: 36, height: 40 + (i < 5 ? i * 6 : 60 + i * 8)), radius: 3) }
            },
            Sample(note: "This jacket, but check if they have olive in M before Black Friday. Remind me on 27 November.",
                   title: "Field Jacket — Olive", url: "https://shop.example.com/field-jacket", app: "Safari", ocr: "Field Jacket — Olive $189 S M L XL Add to bag", daysAgo: 2) { c, s in
                fill(c, 0xF1F0EA, CGRect(origin: .zero, size: s))
                fill(c, 0x6B7F4A, CGRect(x: s.width/2 - 90, y: 140, width: 180, height: 200), radius: 30)
                text(c, "Field Jacket — Olive\n$189", CGRect(x: 40, y: 40, width: 300, height: 70), size: 20, weight: .medium)
            },
            Sample(note: "Miso pasta from the reel. Making this Sunday, save it to recipes.", title: "Miso butter pasta",
                   url: "https://www.instagram.com/reel/abc", app: "Arc", ocr: "Miso butter pasta 15 min · one pan", daysAgo: 4) { c, s in
                fill(c, 0x2B1D14, CGRect(origin: .zero, size: s))
                fill(c, 0xF5E6C8, CGRect(x: s.width/2 - 120, y: s.height/2 - 60, width: 240, height: 240), radius: 120)
                fill(c, 0xE7A93B, CGRect(x: s.width/2 - 90, y: s.height/2 - 30, width: 180, height: 180), radius: 90)
                text(c, "Miso butter pasta", CGRect(x: 30, y: 30, width: 400, height: 40), size: 24, weight: .bold, color: .white)
            },
            Sample(note: "Competitor moved Pro to $12. Compare with ours on Monday. Tag it pricing.", title: "Simple pricing", url: "https://competitor.io/pricing", app: "Google Chrome",
                   ocr: "Simple pricing Starter $0 Pro $12 Team $29 per month", daysAgo: 7) { c, s in
                fill(c, 0xF4F4F5, CGRect(origin: .zero, size: s))
                for (i, (p, dark)) in [("$0", false), ("$12", true), ("$29", false)].enumerated() {
                    let r = CGRect(x: 30 + CGFloat(i) * 190, y: 30, width: 170, height: s.height - 90)
                    fill(c, dark ? 0x111827 : 0xFFFFFF, r, radius: 12)
                    text(c, p, CGRect(x: r.minX + 18, y: r.maxY - 70, width: 150, height: 50), size: 34, weight: .bold, color: dark ? .white : .black)
                }
                text(c, "Simple pricing", CGRect(x: 30, y: s.height - 50, width: 300, height: 30), size: 16, weight: .semibold)
            },
            Sample(note: "This graph will be on the exam. 14:32 in the lecture. For the econ revision.", title: "Week 4 · Supply and demand",
                   url: "https://www.youtube.com/watch?v=econ101", app: "Safari", ocr: "Week 4 · Supply and demand Price Quantity S D", daysAgo: 3) { c, s in
                fill(c, 0xFFFFFF, CGRect(origin: .zero, size: s))
                fill(c, 0x1E3A8A, CGRect(x: 0, y: s.height - 50, width: s.width, height: 50))
                text(c, "Week 4 · Supply and demand", CGRect(x: 20, y: s.height - 40, width: 400, height: 30), size: 18, weight: .semibold, color: .white)
                c.setStrokeColor(NSColor.red.cgColor); c.setLineWidth(3); c.move(to: CGPoint(x: 80, y: 60)); c.addLine(to: CGPoint(x: 520, y: 300)); c.strokePath()
                c.setStrokeColor(NSColor.blue.cgColor); c.move(to: CGPoint(x: 80, y: 300)); c.addLine(to: CGPoint(x: 520, y: 60)); c.strokePath()
            },
            Sample(note: "Use this line in my talk about search. Hashtag design.", title: "People scan, they don’t read", url: "https://essays.example.com/scanning", app: "Safari",
                   ocr: "People don’t read interfaces. They scan for the one word that matches what they came for.", daysAgo: 6) { c, s in
                fill(c, 0xFFFBEB, CGRect(origin: .zero, size: s))
                fill(c, 0xD97706, CGRect(x: 40, y: 90, width: 4, height: s.height - 160))
                text(c, "“People don’t read interfaces. They scan for the one word that matches what they came for.”", CGRect(x: 60, y: 90, width: s.width - 110, height: s.height - 160), size: 26, serif: true)
            },
            Sample(note: "", title: "Lake in Norway", url: nil, app: "Photos", ocr: "", daysAgo: 1) { c, s in
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(hex: 0x0E7490).cgColor, NSColor(hex: 0xA5F3FC).cgColor] as CFArray, locations: [0, 1])!
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: s.height), options: [])
                fill(c, 0x14532D, CGRect(x: 0, y: s.height * 0.45, width: s.width, height: 60))
            },
        ]
        let sampleTags: [[String]] = [["pricing"], ["gift-idea"], ["recipe"], ["design"], ["to-read"], ["design", "copy"], []]
        var existing: [String] = []
        for (i, sm) in samples.enumerated() {
            let size = CGSize(width: 600, height: i == 2 ? 640 : 420)
            let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            sm.draw(ctx, size)
            var c = Capture(id: UUID().uuidString, created: Date().addingTimeInterval(-sm.daysAgo * 86_400))
            c.note = sm.note; c.title = sm.title; c.pageURL = sm.url; c.sourceApp = sm.app; c.ocr = sm.ocr
            c.width = Int(size.width); c.height = Int(size.height)
            let intent = SpokenIntent.parse(sm.note, existing: existing, now: c.created)
            c.collection = intent.collection; c.collectionPhrase = intent.collectionPhrase
            c.reminderDate = intent.reminderDate; c.reminderPhrase = intent.reminderPhrase
            if let col = c.collection, !existing.contains(col) { existing.append(col) }
            if i == 0 { c.pastedLinks = ["https://docs.google.com/document/d/newsletter-draft"]; c.audioSeconds = 9 }
            // Grabbed from the Instagram feed: the reel itself, plus the feed it was on.
            if sm.title == "Miso butter pasta" { c.itemURL = sm.url; c.pageURL = "https://www.instagram.com/" }
            // The lecture: the link reopens at 14:32.
            if sm.title.hasPrefix("Week 4") { c.videoSeconds = 872 }
            for t in SpokenIntent.parse(sm.note, existing: [], existingTags: []).tags { c.addTag(t, origin: "said") }
            for t in sampleTags[i] { c.addTag(t, origin: "orca") }
            if i == 0 {
                // A clip of the bars growing, so the clip screens have something to show.
                if makeSampleClip(c.clipURL, size: size, draw: sm.draw, barsChart: true) { c.clipSeconds = 3 }
            }
            _ = CaptureStore.writePNG(ctx.makeImage()!, to: c.imageURL)
            CaptureStore.shared.save(c)
        }
    }

    /// Writes a 3-second clip: the first sample with its orange bars growing one by one.
    nonisolated static func makeSampleClip(_ url: URL, size: CGSize, draw: (CGContext, CGSize) -> Void, barsChart: Bool) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let w = Int(size.width), h = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let frames = 90
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return false }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            draw(ctx, size)
            // Cover the orange bars that haven't "grown" yet.
            let shown = min(3, f / 20)
            ctx.setFillColor(NSColor(hex: 0xF6F7F8).cgColor)
            for i in (5 + shown)..<8 { ctx.fill(CGRect(x: 100 + i * 56, y: 50, width: 36, height: 140)) }
            if shown < 3 {
                let grow = CGFloat(f % 20) / 20
                let i = 5 + shown
                ctx.setFillColor(NSColor(hex: 0xC2410C).cgColor)
                ctx.fill(CGRect(x: CGFloat(100 + i * 56), y: 50, width: 36, height: CGFloat(60 + i * 8 + 40) * grow))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return writer.status == .completed
    }
}
