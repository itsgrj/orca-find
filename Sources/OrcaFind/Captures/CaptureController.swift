import AppKit
import SwiftUI

/// Everything the UI shows about saved captures.
@MainActor
@Observable
final class CaptureLibrary {
    static let shared = CaptureLibrary()
    private(set) var items: [Capture] = []
    private(set) var collections: [(name: String, count: Int)] = []
    /// Every tag in use, most used first.
    private(set) var tags: [(name: String, count: Int)] = []
    /// Bumped on every change so views can refresh thumbnails etc.
    private(set) var version = 0

    init() { reload() }

    func reload() {
        items = CaptureStore.shared.all()
        collections = CaptureStore.shared.collections()
        tags = CaptureLibrary.countTags(items)
        version += 1
    }

    func capture(_ id: String) -> Capture? { items.first { $0.id == id } ?? CaptureStore.shared.get(id) }

    func update(_ c: Capture) {
        CaptureStore.shared.save(c)
        reload()
    }

    func delete(_ c: Capture) {
        if let r = c.reminderID { RemindersBridge.remove(r) }
        CaptureStore.shared.delete(id: c.id)
        CaptureThumbs.cache.removeAllObjects()
        reload()
    }

    var tagNames: [String] { tags.map(\.name) }

    nonisolated static func countTags(_ list: [Capture]) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for c in list {
            for t in c.tagList {
                let key = order.first { CaptureTags.same($0, t) } ?? { order.append(t); return t }()
                counts[key, default: 0] += 1
            }
        }
        return order.map { ($0, counts[$0] ?? 0) }.sorted { $0.1 > $1.1 }
    }

    var upcomingReminders: Int { items.filter { ($0.reminderDate ?? .distantPast) > Date() }.count }
    var thisWeek: Int {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        return items.filter { $0.created > start }.count
    }
}

/// Live state of one capture in progress (drives the recording strip).
@MainActor
@Observable
final class CaptureSession {
    enum Mode { case recording, typing, saving }
    let id = UUID().uuidString
    var mode: Mode = .recording
    var typed = ""
    var message: String?
    var pageURL: String?
    var pageTitle: String?
    /// The pin / post / video under the box, when the page itself is a feed (or the box wraps a link elsewhere).
    var itemURL: String?
    /// Where the YouTube video was when the box was drawn.
    var videoSeconds: Double?
    /// The page details have arrived (or there are none to wait for).
    var pageDone = false
    var pastedLinks: [String] = []
    var image: CGImage
    var pointSize: CGSize
    let context: CaptureContext
    let recorder = CaptureRecorder()
    var focusToken = 0
    /// Records the box as video alongside the voice (nil when clips are off in Settings).
    var clip: ClipRecorder?
    /// Orca saw movement in the box.
    var clipMoving = false
    /// V while talking: true = keep the clip, false = picture only, nil = let Orca decide.
    var clipChoice: Bool?
    var keepsClip: Bool { clip != nil && (clipChoice ?? clipMoving) }
    /// How tall the words may get before the strip scrolls (set from the space left on screen).
    var stripMaxText: CGFloat = 360

    init(image: CGImage, pointSize: CGSize, context: CaptureContext) {
        self.image = image
        self.pointSize = pointSize
        self.context = context
    }

    var linkLabel: String? {
        guard let first = pastedLinks.last ?? itemURL ?? pageURL, let u = URL(string: first) else { return nil }
        var short = (u.host ?? "").replacingOccurrences(of: "www.", with: "") + u.path
        if short.count > 28 { short = String(short.prefix(26)) + "…" }
        if pastedLinks.isEmpty, itemURL == nil, let t = videoSeconds { short += " · \(SourceLinks.clock(t))" }
        return short
    }

    /// Links attached so far (for the "+2" next to the strip's link).
    var linkCount: Int { pastedLinks.count + (itemURL == nil ? 0 : 1) + (pageURL == nil ? 0 : 1) }
}

@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private(set) var session: CaptureSession?
    private var strip: CapturePanel?
    private var outline: NSPanel?
    private var keyMonitor: Any?
    private var pageTask: Task<Void, Never>?
    private var savedPanel: CapturePanel?
    private var savedTask: Task<Void, Never>?
    /// The strip hangs below the grab and grows downward; above or over the grab it grows upward.
    private var stripGrowsDown = true

    var isBusy: Bool { session != nil || RegionGrabber.shared.isActive }

    // MARK: 1 · Grab

    func start() {
        guard !isBusy else { return }
        guard ScreenGrab.hasPermission else {
            ScreenGrab.requestPermission()
            AppState.shared.openMainWindow()
            AppState.shared.navigate(.captures)
            AppState.shared.showToast("Allow Orca under Screen & System Audio Recording, then press \(Preferences.shared.captureHotKey.display) again")
            return
        }
        hideSaved()
        let context = CaptureContext.snapshot()
        // Ask the browser for the page while the person is still dragging.
        let pageFetch: Task<(url: String, title: String?)?, Never>? = context.bundleID.flatMap { id in
            CaptureContext.browsers[id] == nil ? nil : Task { await CaptureContext.fetchPage(bundleID: id) }
        }
        let pid = context.pid
        if context.isBrowser { Task.detached(priority: .userInitiated) { PageInspector.wake(pid: pid) } }
        RegionGrabber.shared.begin { [weak self] rect, screen in
            guard let self, let rect, let screen else { return }
            // What's under the box (the pin, the post, where the video is) — read the moment the drag ends.
            let box = PageInspector.axRect(rect)
            let inspect: Task<PageInspector.Found, Never>? = context.isBrowser
                ? Task.detached(priority: .userInitiated) { PageInspector.inspect(pid: pid, box: box) } : nil
            Task { @MainActor in
                do {
                    // Let the dimming overlay leave the screen before the picture is taken.
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    let image = try await ScreenGrab.capture(rect: rect, on: screen)
                    let s = CaptureSession(image: image, pointSize: rect.size, context: context)
                    self.session = s
                    self.showStrip(for: rect, on: screen)
                    if Preferences.shared.captureClips { self.startClip(s, rect: rect, screen: screen) }
                    if pageFetch != nil || inspect != nil {
                        self.pageTask = Task { @MainActor in
                            let page = await pageFetch?.value ?? nil
                            let found = await inspect?.value
                            s.pageURL = page?.url ?? found?.pageURL
                            s.pageTitle = page?.title
                            if let item = found?.itemURL, !SourceLinks.same(item, s.pageURL) { s.itemURL = item }
                            if let t = found?.videoSeconds, SourceLinks.supportsMoment(s.pageURL) { s.videoSeconds = t }
                            s.pageDone = true
                        }
                    } else {
                        s.pageDone = true
                    }
                    await self.beginRecording(s)
                } catch {
                    NSLog("OrcaFind: capture failed: \(error)")
                    AppState.shared.showToast("Couldn’t take the picture: \(error.localizedDescription)")
                    self.teardown()
                }
            }
        }
    }

    private func startClip(_ s: CaptureSession, rect: NSRect, screen: NSScreen) {
        let clip = ClipRecorder()
        clip.onMotion = { [weak s] in s?.clipMoving = true }
        s.clip = clip
        Task {
            do { try await clip.start(rect: rect, on: screen, to: CaptureStore.folder.appendingPathComponent("\(s.id).mov")) }
            catch {
                NSLog("OrcaFind: clip recording didn't start: \(error.localizedDescription)")
                await MainActor.run { if s.clip === clip { s.clip = nil } }
                clip.discard()
            }
        }
    }

    /// V while talking: keep the clip / picture only.
    func toggleClip() {
        guard let s = session, s.clip != nil, s.mode == .recording else { return }
        s.clipChoice = !s.keepsClip
    }

    // MARK: 2 · Talk (or type)

    private func beginRecording(_ s: CaptureSession) async {
        do {
            try await s.recorder.start(audioURL: CaptureStore.folder.appendingPathComponent("\(s.id).m4a")) { [weak self] in
                self?.finish()
            }
        } catch {
            guard session === s else { return }
            s.message = error.localizedDescription
            switchToTyping()
        }
    }

    func switchToTyping() {
        guard let s = session, s.mode == .recording else { return }
        s.recorder.stop()
        // What was already said stays; keep typing after it.
        let said = s.recorder.transcript
        s.typed = said.isEmpty ? "" : said + " "
        s.mode = .typing
        s.focusToken += 1
    }

    private func pasteLink() -> Bool {
        guard let s = session else { return false }
        let pb = NSPasteboard.general
        var link: String?
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme?.hasPrefix("http") == true {
            link = url.absoluteString
        } else if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !str.contains(" "), let u = URL(string: str), u.scheme?.hasPrefix("http") == true {
            link = str
        }
        guard let link else { return false }
        if !s.pastedLinks.contains(link) && link != s.pageURL && link != s.itemURL { s.pastedLinks.append(link) }
        return true
    }

    func cancel() {
        guard let s = session else { return }
        s.recorder.stop()
        if let clip = s.clip { Task { _ = await clip.stop(); clip.discard() } }
        try? FileManager.default.removeItem(at: CaptureStore.folder.appendingPathComponent("\(s.id).m4a"))
        teardown()
    }

    // MARK: 3 · Save

    func finish() {
        guard let s = session, s.mode != .saving else { return }
        let duration = s.mode == .recording ? s.recorder.stop() : 0
        let typedMode = s.mode == .typing
        s.mode = .saving
        let note = (typedMode ? s.typed : s.recorder.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        let spokeSeconds = typedMode ? 0 : (s.recorder.heardSpeech ? duration : 0)
        let wasTyped = typedMode && !s.typed.isEmpty

        var c = Capture(id: s.id, created: Date())
        c.note = note
        c.noteTyped = wasTyped
        c.sourceApp = s.context.appName
        c.sourceBundle = s.context.bundleID
        c.windowTitle = s.context.windowTitle
        c.pageURL = s.pageURL
        c.itemURL = s.itemURL
        c.videoSeconds = s.videoSeconds
        c.pastedLinks = s.pastedLinks
        c.width = Int(s.pointSize.width)
        c.height = Int(s.pointSize.height)
        c.audioSeconds = spokeSeconds
        if spokeSeconds == 0 { try? FileManager.default.removeItem(at: c.audioURL) }

        let intent = SpokenIntent.parse(note, existing: CaptureLibrary.shared.collections.map(\.name),
                                        existingTags: CaptureLibrary.shared.tagNames)
        c.collection = intent.collection
        c.collectionPhrase = intent.collectionPhrase
        c.reminderDate = intent.reminderDate
        c.reminderPhrase = intent.reminderPhrase
        let knownTags = CaptureLibrary.shared.tagNames
        for t in intent.tags { c.addTag(t, origin: "said") }
        for t in CaptureTags.mentioned(in: note, existing: knownTags) { c.addTag(t, origin: "orca") }
        c.title = CaptureContext.title(page: s.pageTitle, window: s.context.windowTitle, note: note, ocr: "", app: s.context.appName)
        let clip = s.clip
        let keepClip = s.keepsClip
        if keepClip { c.clipSeconds = max(0.5, min(ClipRecorder.maxSeconds, s.recorder.elapsed)) }

        let image = s.image
        let pageDone = s.pageDone
        let fromBrowser = s.context.isBrowser
        let pending = pageTask
        _ = CaptureStore.writePNG(image, to: c.imageURL)
        CaptureStore.shared.save(c)
        CaptureLibrary.shared.reload()
        showSaved(c, near: strip?.frame)
        teardown()

        // 4 · Orca does the rest, in the background: page link (if still coming), text in the picture, reminder.
        let reminderTask = intent.reminderTask
        // Listen to the whole recording again right away (well under a second), while the rest runs.
        let relisten: Task<(text: String, source: NoteTranscriber.Source)?, Never>? =
            c.audioSeconds > 0 && !c.noteTyped ? Task { @MainActor in await NoteTranscriber.listen(c.audioURL, live: note) } : nil
        Task { @MainActor in
            var c = c
            var reminderTask = reminderTask
            // Better words first, so the toast, title, tags and reminder all use what was really said.
            if let relisten, let (text, source) = await relisten.value {
                if NoteTranscriber.accept(text, over: c.note) {
                    if let task = NoteTranscriber.apply(text, source, to: &c, reminders: true) { reminderTask = task.isEmpty ? nil : task }
                    if s.pageTitle == nil && CaptureContext.cleanTitle(s.context.windowTitle) == nil {
                        c.title = CaptureContext.title(page: nil, window: nil, note: text, ocr: "", app: c.sourceApp)
                    }
                } else {
                    c.noteSource = source.rawValue
                }
                CaptureLibrary.shared.update(c)
            }
            if let clip {
                let seconds = await clip.stop()
                if keepClip && seconds > 0.3 {
                    c.clipSeconds = seconds
                } else {
                    clip.discard()
                    c.clipSeconds = nil
                }
                CaptureLibrary.shared.update(c)
            }
            if !pageDone, let pending {
                await pending.value
                if let url = s.pageURL { c.pageURL = url }
                c.itemURL = s.itemURL
                c.videoSeconds = s.videoSeconds
                c.pastedLinks.removeAll { $0 == s.itemURL }
                if let t = s.pageTitle, let clean = CaptureContext.cleanTitle(t) { c.title = clean }
            }
            if fromBrowser { CaptureController.offerPageAccess() }
            let text = await Task.detached(priority: .utility) { TextExtractor.recognize(image) }.value
            c.ocr = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.pageTitle == nil && CaptureContext.cleanTitle(s.context.windowTitle) == nil && c.note.isEmpty {
                c.title = CaptureContext.title(page: nil, window: nil, note: "", ocr: c.ocr, app: c.sourceApp)
            }
            // One or two tags from the words and the picture, when Apple Intelligence is on this Mac.
            if Preferences.shared.captureAutoTags, c.tagList.count < 3 {
                for t in await CaptureTags.suggest(note: c.note, title: c.title, ocr: c.ocr, collection: c.collection,
                                                   existing: CaptureLibrary.shared.tagNames) {
                    c.addTag(t, origin: "orca")
                }
            }
            CaptureLibrary.shared.update(c)
            if let due = c.reminderDate {
                let title = reminderTask ?? (c.title.isEmpty ? "Look at your capture" : c.title)
                var notes = c.note
                if let link = c.links.first { notes += "\n\n" + link }
                if let id = await RemindersBridge.add(title: title, notes: notes, due: due, link: c.deepLink) {
                    c.reminderID = id
                    CaptureLibrary.shared.update(c)
                } else {
                    AppState.shared.showToast("Saved, but Reminders access is off — turn it on in System Settings › Privacy & Security › Reminders")
                }
            }
        }
    }

    /// The first time something is grabbed from a browser without Accessibility allowed, say once what it adds
    /// and show macOS's prompt. Never again after that; Settings › Captures has the switch.
    static func offerPageAccess() {
        let key = "askedPageAccess"
        guard !PageInspector.isAllowed, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            AppState.shared.showToast("Saved with its page link. Allow Orca under Accessibility to also keep the exact pin, post or video moment")
            PageInspector.askForAccess()
        }
    }

    static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    /// Re-reads a capture's recording (Settings-free fix for notes that lost words).
    static func transcribeAgain(_ id: String) {
        guard var c = CaptureLibrary.shared.capture(id), c.hasAudio else { return }
        AppState.shared.showToast("Listening to the recording again…")
        Task { @MainActor in
            guard let (full, source) = await NoteTranscriber.listen(c.audioURL, live: c.note) else {
                AppState.shared.showToast("Couldn’t transcribe the recording"); return
            }
            c.noteTyped = false
            NoteTranscriber.apply(full, source, to: &c, reminders: false)
            CaptureLibrary.shared.update(c)
            AppState.shared.showToast("Updated what you said · \(wordCount(full)) words")
        }
    }

    private func teardown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        strip?.orderOut(nil); strip = nil
        outline?.orderOut(nil); outline = nil
        session = nil
        pageTask = nil
    }

    // MARK: Strip window (V2 A — under the grab)

    private func showStrip(for rect: NSRect, on screen: NSScreen) {
        guard let s = session else { return }
        let vis = screen.visibleFrame
        let width = min(max(rect.width, 460), 640)
        let height: CGFloat = 138
        var x = rect.minX
        x = min(max(x, vis.minX + 8), vis.maxX - width - 8)
        var y = rect.minY - 10 - height
        stripGrowsDown = true
        if y < vis.minY + 8 { y = rect.maxY + 10; stripGrowsDown = false }
        if y + height > vis.maxY - 8 { y = max(vis.minY + 8, rect.minY + 12); stripGrowsDown = false }
        // Room for the words: everything between the strip's fixed edge and the screen edge, less the header and hints.
        let room = stripGrowsDown ? (y + height) - vis.minY - 8 : vis.maxY - y - 8
        s.stripMaxText = max(60, room - 96)

        let p = CapturePanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: CaptureStripView(session: s) { [weak self] h in self?.resizeStrip(h) })
        // We size the strip ourselves (resizeStrip). Left on, NSHostingView pins the panel's minimum
        // height to the text laid out at zero width (one letter per line, ~650pt), so the strip
        // balloons upward and covers the very thing being grabbed.
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.orderFrontRegardless()
        p.makeKey()
        strip = p

        // Everything but the grab goes dark, with a purple edge around it, so it's clear what's being talked about.
        // It sits just under the strip and lets clicks through; the picture was already taken, so it isn't in it.
        let o = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        o.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        o.isOpaque = false
        o.backgroundColor = .clear
        o.ignoresMouseEvents = true
        o.hasShadow = false
        o.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let hole = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        o.contentView = GrabSpotlightView(frame: NSRect(origin: .zero, size: screen.frame.size), hole: hole)
        o.alphaValue = 0
        o.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            o.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        outline = o

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let s = self.session, e.window === self.strip else { return false }
                switch (Int(code), mods) {
                case (53, _): self.cancel(); return true                                   // esc
                case (36, []), (76, []): self.finish(); return true                       // return
                case (48, []): if s.mode == .recording { self.switchToTyping() }; return true // tab
                case (9, []) where s.mode == .recording:                                    // v
                    self.toggleClip(); return true
                case (9, [.command]):                                                      // ⌘V
                    if self.pasteLink() { return true }
                    return s.mode == .recording
                default: return s.mode == .recording
                }
            }
            return handled ? nil : e
        }
    }

    /// Grows (or shrinks) the strip to fit what's been said, keeping the edge next to the grab still.
    private func resizeStrip(_ h: CGFloat) {
        guard let p = strip else { return }
        let h = ceil(max(110, h))
        guard abs(p.frame.height - h) > 0.5 else { return }
        var f = p.frame
        if stripGrowsDown { f.origin.y = f.maxY - h }
        f.size.height = h
        p.setFrame(f, display: true)
    }

    // MARK: Saved card (V4)

    private func showSaved(_ c: Capture, near frame: NSRect?) {
        hideSaved()
        let size = NSSize(width: 380, height: 112)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: vis.maxX - size.width - 16, y: vis.minY + 16)
        if let f = frame { origin = NSPoint(x: f.minX, y: f.maxY - size.height) }
        let p = CapturePanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = SavedCardView(captureID: c.id, undo: { [weak self] in
            if let c = CaptureLibrary.shared.capture(c.id) { CaptureLibrary.shared.delete(c) }
            self?.hideSaved()
        }, open: { [weak self] in
            self?.hideSaved()
            AppState.shared.openMainWindow()
            AppState.shared.navigate(.capture(c.id))
        }, hover: { [weak self] inside in
            if inside { self?.savedTask?.cancel() } else { self?.scheduleSavedHide(after: 1.5) }
        })
        .environment(CaptureLibrary.shared)
        p.contentView = NSHostingView(rootView: view)
        p.orderFrontRegardless()
        savedPanel = p
        scheduleSavedHide(after: 3)
    }

    private func scheduleSavedHide(after seconds: Double) {
        savedTask?.cancel()
        savedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.hideSaved() }
        }
    }

    private func hideSaved() {
        savedTask?.cancel()
        savedPanel?.orderOut(nil)
        savedPanel = nil
    }
}

// MARK: - Views

/// V2 A: the dark strip under the grab. Recording starts on its own; no buttons.
struct CaptureStripView: View {
    @Bindable var session: CaptureSession
    /// Reports the strip's natural height so its window can grow with the words.
    var onHeight: (CGFloat) -> Void = { _ in }
    @FocusState private var typingFocused: Bool
    @State private var textHeight: CGFloat = 20

    var body: some View {
        let r = session.recorder
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                switch session.mode {
                case .recording:
                    Circle().fill(Color(hex: 0xFF453A)).frame(width: 7, height: 7)
                    Text(session.keepsClip ? "Recording clip" : "Recording").font(DS.caption).foregroundStyle(DS.onDark)
                    Text(Self.clock(r.elapsed)).font(DS.caption).foregroundStyle(DS.onDark2).monospacedDigit()
                    Waveform(levels: session.keepsClip ? Array(r.levels.suffix(16)) : r.levels)
                        .frame(width: session.keepsClip ? 76 : 130, height: 16)
                case .typing:
                    Image(systemName: "mic.slash").font(.system(size: 10)).foregroundStyle(DS.onDark2)
                    Text(session.message ?? "Mic off · typing").font(DS.caption).foregroundStyle(DS.onDark).lineLimit(1)
                case .saving:
                    ProgressView().controlSize(.mini)
                    Text("Saving…").font(DS.caption).foregroundStyle(DS.onDark)
                }
                Spacer(minLength: 6)
                if session.keepsClip && session.mode != .typing {
                    HStack(spacing: 5) {
                        Image(systemName: "film").font(.system(size: 9))
                        Text(session.clipChoice == true ? "Keeping video" : "Moving · keeping video").font(DS.caption).lineLimit(1)
                    }
                    .foregroundStyle(DS.onDark)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: 0xFF453A).opacity(0.22)))
                    .transition(.opacity)
                }
                if session.keepsClip && session.mode != .typing, session.linkLabel != nil {
                    Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(DS.onDark2)
                        .help(session.itemURL ?? session.pageURL ?? "")
                } else if let link = session.linkLabel {
                    HStack(spacing: 5) {
                        Image(systemName: "globe").font(.system(size: 9))
                        Text("\(link) attached").font(DS.caption).lineLimit(1)
                        if session.linkCount > 1 {
                            Text("+\(session.linkCount - 1)").font(DS.caption).foregroundStyle(DS.onDark2)
                        }
                    }
                    .foregroundStyle(DS.onDark)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
            }
            Group {
                if session.mode == .typing {
                    TextField("", text: $session.typed, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DS.px(15)).foregroundStyle(.white)
                        .lineLimit(1...12)
                        .focused($typingFocused)
                        .background(alignment: .topLeading) {
                            if session.typed.isEmpty {
                                Text("Why are you saving this?").font(DS.px(15)).foregroundStyle(DS.onDark2).allowsHitTesting(false)
                            }
                        }
                } else if r.transcript.isEmpty {
                    Text("Say why you’re saving this…").font(DS.px(15)).foregroundStyle(DS.onDark2)
                } else {
                    // Every word stays visible: the strip grows, and scrolls (pinned to the newest words)
                    // only once it reaches the edge of the screen.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            Text(r.transcript).font(DS.px(15)).foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(GeometryReader { g in Color.clear.preference(key: StripTextHeight.self, value: g.size.height) })
                                .id("words")
                        }
                        .scrollIndicators(.never)
                        .frame(height: min(max(textHeight, 20), session.stripMaxText))
                        .onChange(of: r.transcript) { _, _ in proxy.scrollTo("words", anchor: .bottom) }
                        .onChange(of: textHeight) { _, _ in proxy.scrollTo("words", anchor: .bottom) }
                    }
                    .onPreferenceChange(StripTextHeight.self) { textHeight = $0 }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            ViewThatFits(in: .horizontal) {
                hints(compact: false)
                hints(compact: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: StripHeight.self, value: g.size.height) })
        .onPreferenceChange(StripHeight.self) { onHeight($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1A1A1A).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .animation(.easeOut(duration: 0.2), value: session.keepsClip)
        .onChange(of: session.focusToken) { _, _ in
            DispatchQueue.main.async { typingFocused = true }
        }
    }

    private func hints(compact: Bool) -> some View {
        HStack(spacing: 14) {
            if session.mode == .typing {
                hint("return", "save"); hint("⌘V", "attach link"); hint("esc", "cancel")
            } else {
                if !compact { hint(nil, "stop talking to save") }
                if session.clip != nil { hint("v", session.keepsClip ? "picture only" : "keep clip") } else { hint("return", "done") }
                hint("tab", compact ? "type" : "type instead"); hint("esc", "cancel")
            }
            Spacer(minLength: 0)
        }
    }

    private func hint(_ key: String?, _ text: String) -> some View {
        HStack(spacing: 5) {
            if let key { Text(key.uppercased()).font(DS.label).foregroundStyle(DS.onDark) }
            Text(text.uppercased()).font(DS.label).foregroundStyle(DS.onDark2)
        }
        .tracking(0.5)
        .lineLimit(1)
        .fixedSize()
    }

    static func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

private struct StripHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct StripTextHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Waveform: View {
    let levels: [Float]
    var color = Color(hex: 0xA78BFA)
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                let v = CGFloat(min(1, max(0, levels[i])))
                Capsule().fill(v < 0.04 ? Color.white.opacity(0.25) : color)
                    .frame(width: 2.5, height: max(2.5, v * 16))
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}

/// V4: "Saved to Newsletter" — gone after 3 seconds, Undo, click to open.
struct SavedCardView: View {
    @Environment(CaptureLibrary.self) private var library
    let captureID: String
    let undo: () -> Void
    let open: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        let c = library.capture(captureID)
        HStack(alignment: .top, spacing: 12) {
            CaptureThumb(id: captureID, maxPixel: 200)
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x34C759)).font(.system(size: 12))
                    Text(savedTitle(c)).font(DS.body).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Button("Undo", action: undo).buttonStyle(.plain).font(DS.bodySM).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15)))
                }
                Text(c.map { $0.note.isEmpty ? "No note — Orca kept the link and the text it read" : "“\($0.note)”" } ?? "")
                    .font(DS.bodySM).foregroundStyle(DS.onDark).lineLimit(2)
                HStack(spacing: 6) {
                    if let s = c?.clipSeconds, s > 0 { tag("play.fill", CaptureStripView.clock(s)) }
                    if let c, !c.links.isEmpty { tag("globe", "link") }
                    if let d = c?.reminderDate { tag("bell", Capture.reminderShort(d)) }
                    if let c, !c.tagList.isEmpty { tag("number", c.tagList.prefix(2).joined(separator: " #")) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1A1A1A).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover(perform: hover)
    }

    private func savedTitle(_ c: Capture?) -> String {
        let what = (c?.clipSeconds ?? 0) > 0 ? "Clip saved" : "Saved"
        return c?.collection.map { "\(what) to \($0)" } ?? what
    }

    private func tag(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(DS.caption).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(DS.onDark)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

/// Downscaled capture images, cached.
enum CaptureThumbs {
    static let cache = NSCache<NSString, NSImage>()

    static func image(_ id: String, maxPixel: Int) -> NSImage? {
        let key = "\(id)@\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = CaptureStore.folder.appendingPathComponent("\(id).png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}

struct CaptureThumb: View {
    let id: String
    var maxPixel = 600
    var fit = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            DS.surface2
            if let image {
                if fit { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
                else { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
            }
        }
        .task(id: id) {
            let id = id, px = maxPixel
            image = await Task.detached(priority: .userInitiated) { CaptureThumbs.image(id, maxPixel: px) }.value
        }
    }
}

/// The dim around a grab while you talk: the screen darkens, the grabbed box stays clear with a purple edge.
final class GrabSpotlightView: NSView {
    let hole: NSRect
    init(frame: NSRect, hole: NSRect) { self.hole = hole; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let edge = hole.insetBy(dx: -2, dy: -2)
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(roundedRect: edge, xRadius: 3, yRadius: 3))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        let border = NSBezierPath(roundedRect: edge.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        border.lineWidth = 2
        NSColor(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255, alpha: 1).setStroke()
        border.stroke()
    }
}
