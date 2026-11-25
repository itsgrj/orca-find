import AppKit
import ScreenCaptureKit

/// Panel that takes keys without making Orca the active app — the app you were in stays in front.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// What was grabbed, handed to the capture.
struct Grabbed {
    /// Global AppKit coordinates, on `screen`.
    var rect: NSRect
    var screen: NSScreen
    /// A clicked picture on a web page (nil for a dragged box).
    var picture: PageInspector.Picture?
    /// The clicked picture cut from the still taken as the shortcut came up, so there's no grab to wait for.
    var image: CGImage?
    /// The dimmed screen, kept up: it becomes the dim around the grab while you talk, so the screen never
    /// flashes back to normal in between. It already lets clicks through; whoever takes it closes it.
    var cover: CapturePanel?
}

/// "Drag over anything": dims every screen, draws the box as you drag, Esc gives up.
/// Over a browser page it also lights up the picture under the mouse; a click takes just that picture.
@MainActor
final class RegionGrabber {
    static let shared = RegionGrabber()
    private var windows: [CapturePanel] = []
    private var completion: ((Grabbed?) -> Void)?
    private var keyMonitor: Any?
    /// A still of each screen from when the shortcut came up (pictures are measured and cut from it).
    private var stillsTask: Task<[ScreenStill], Never>?
    private var stills: [ScreenStill] = []

    // The picture under the mouse, on a web page in whichever app's window is under it.
    private var findsPicturesOn = false
    /// Apps already asked to build their page tree (Chromium browsers only do once asked).
    private var woken: Set<pid_t> = []
    fileprivate private(set) var lit: (rect: NSRect, picture: PageInspector.Picture)?
    private var looking = false
    private var nextLook: NSPoint?
    private var lookToken = 0
    fileprivate var findsPictures: Bool { findsPicturesOn }

    var isActive: Bool { !windows.isEmpty }

    /// `pictures`: light up pictures on web pages as the mouse passes over them (needs Accessibility).
    func begin(pictures: Bool = true, _ done: @escaping (Grabbed?) -> Void) {
        guard !isActive else { return }
        completion = done
        findsPicturesOn = pictures && PageInspector.isAllowed
        stills = []
        stillsTask = findsPicturesOn ? Task { @MainActor [weak self] in
            var out: [ScreenStill] = []
            for screen in NSScreen.screens { if let s = await ScreenStill.take(screen) { out.append(s) } }
            if let self, self.isActive { self.stills = out }
            return out
        } : nil
        CaptureLog.log("overlay opened · pictures \(findsPicturesOn ? "on" : "off") · Accessibility \(PageInspector.isAllowed ? "allowed" : "NOT allowed")")
        lit = nil
        lookToken += 1
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let w = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.setFrame(screen.frame, display: false)
            let view = GrabView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screen0 = screen
            view.grabber = self
            view.showHint = NSMouseInRect(mouse, screen.frame, false)
            view.onFinish = { [weak self] rect in self?.finish(rect.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }, screen, nil) }
            view.onPicture = { [weak self] in
                guard let self, let lit = self.lit else { return }
                let s = NSScreen.screens.first { $0.frame.intersects(lit.rect) } ?? screen
                self.finish(lit.rect.intersection(s.frame).integral, s, lit.picture)
            }
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
        }
        // The panel under the mouse takes keys (Esc) without activating Orca.
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.push()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.finish(nil, nil, nil) }; return nil }
            return e
        }
        // Already pointing at a picture when the shortcut was pressed: light it up straight away.
        look(at: mouse)
    }

    /// Finds the picture under `point` (global AppKit coordinates). One lookup at a time; while one runs,
    /// only the newest mouse position is kept, so fast moves never queue up stale lookups.
    fileprivate func look(at point: NSPoint) {
        guard findsPictures, isActive else { return }
        if looking { nextLook = point; return }
        looking = true
        let token = lookToken
        let ax = PageInspector.axRect(NSRect(origin: point, size: .zero)).origin
        let pid = CaptureContext.windowOwner(at: ax) ?? 0
        let wake = pid > 0 && woken.insert(pid).inserted
        let stillsTask = stillsTask
        Task.detached(priority: .userInitiated) {
            if wake { PageInspector.wake(pid: pid) }
            let picked = pid > 0 ? PageInspector.picture(pid: pid, at: ax) : nil
            // The corners are measured on the still, so wait for it (it's quicker than the lookup).
            let stills = picked == nil ? [] : await stillsTask?.value ?? []
            await MainActor.run { [weak self] in
                guard let self, token == self.lookToken else { return }
                var found = picked
                self.looking = false
                let rect = found.map { PageInspector.appKitRect($0.frame) }
                if let rect, let still = stills.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) {
                    found?.cornerRadius = PictureCorners.radius(of: rect, in: still) ?? 0
                }
                // The mouse may have moved off it while we looked.
                let mouse = NSEvent.mouseLocation
                let stillOver = rect.map { NSMouseInRect(mouse, $0.insetBy(dx: -2, dy: -2), false) } ?? false
                let new = (stillOver ? zip2(rect, found) : nil)
                if new?.picture != self.lit?.picture {
                    let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "no window"
                    CaptureLog.log(found.map { "picture in \(app): \(Int($0.frame.width))×\(Int($0.frame.height)) \($0.url.map { String($0.prefix(90)) } ?? "no file")\(stillOver ? "" : " (mouse moved off)")" }
                                   ?? "no picture under mouse in \(app)")
                }
                if new?.rect != self.lit?.rect || new?.picture != self.lit?.picture {
                    self.lit = new
                    self.windows.forEach { $0.contentView?.needsDisplay = true }
                }
                if let next = self.nextLook { self.nextLook = nil; self.look(at: next) }
                // A browser that just got asked for its page may need a moment to build it; look once more.
                else if wake, found == nil {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard let self, token == self.lookToken, self.lit == nil else { return }
                        self.look(at: NSEvent.mouseLocation)
                    }
                }
            }
        }
    }

    /// Dragging hides the picture outline; a drag means "this exact box".
    fileprivate func dropLit() {
        guard lit != nil else { return }
        lit = nil
        windows.forEach { $0.contentView?.needsDisplay = true }
    }

    private func finish(_ rect: NSRect?, _ screen: NSScreen?, _ picture: PageInspector.Picture?) {
        guard isActive else { return }
        NSCursor.pop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        var grabbed: Grabbed?
        if let rect, let screen {
            // The grab's screen keeps its dim (now letting clicks through) for the capture to take over.
            let cover = windows.firstIndex { $0.frame == screen.frame }.map { windows.remove(at: $0) }
            if let cover, let view = cover.contentView as? GrabView {
                cover.ignoresMouseEvents = true
                view.hold(rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                          radius: picture?.cornerRadius ?? 0, glow: picture != nil)
            }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let image = picture == nil ? nil : stills.first { $0.frame.contains(center) }?.crop(rect)
            grabbed = Grabbed(rect: rect, screen: screen, picture: picture, image: image, cover: cover)
        }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        lookToken += 1
        looking = false
        nextLook = nil
        lit = nil
        findsPicturesOn = false
        stillsTask?.cancel()
        stillsTask = nil
        stills = []
        let done = completion
        completion = nil
        done?(grabbed)
    }
}

private func zip2(_ r: NSRect?, _ p: PageInspector.Picture?) -> (rect: NSRect, picture: PageInspector.Picture)? {
    guard let r, let p else { return nil }
    return (r, p)
}

private final class GrabView: NSView {
    /// How dark the screen gets: lighter while choosing, so the page stays easy to read;
    /// darker once something is in focus (a lit picture, a box, the grab while you talk).
    static let restingDim: CGFloat = 0.3
    static let focusDim: CGFloat = 0.6

    var screen0: NSScreen?
    var showHint = true
    var onFinish: ((NSRect?) -> Void)?
    /// A click on the lit picture.
    var onPicture: (() -> Void)?
    weak var grabber: RegionGrabber?
    private var start: NSPoint?
    private var current: NSPoint?
    private var mouse: NSPoint?
    private let glow = PictureGlow()
    /// After the click: the grab stays clear while the rest stays dim (labels gone, clicks pass through).
    private var held: (rect: NSRect, radius: CGFloat, glow: Bool)?

    @objc dynamic var dimLevel: CGFloat = GrabView.restingDim { didSet { needsDisplay = true } }
    private var dimTarget = GrabView.restingDim
    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "dimLevel" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    func hold(_ rect: NSRect, radius: CGFloat, glow: Bool) {
        held = (rect, radius, glow)
        start = nil; current = nil
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true // the glow's halo is blurred
        layer?.addSublayer(glow.root)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glow.root.frame = bounds
    }

    /// The glow follows the lit picture; a drag (a box of its own) hides it.
    override func viewWillDraw() {
        super.viewWillDraw()
        glow.root.frame = bounds
        if let held {
            glow.show(held.glow ? held.rect : nil, radius: held.radius)
        } else {
            glow.show(selection == nil ? litRect : nil, radius: grabber?.lit?.picture.cornerRadius ?? 0)
        }
        let target = held != nil || selection != nil || litRect != nil ? Self.focusDim : Self.restingDim
        if target != dimTarget {
            dimTarget = target
            // Not from inside drawing: ease to the new darkness on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.dimTarget == target else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self.dimLevel = target; return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().dimLevel = target
                }
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouse = convert(event.locationInWindow, from: nil)
        showHint = true
        needsDisplay = true
        if let w = window { grabber?.look(at: w.convertPoint(toScreen: event.locationInWindow)) }
    }

    /// The lit picture in this view's coordinates.
    private var litRect: NSRect? {
        guard let r = grabber?.lit?.rect, let screen = screen0 else { return nil }
        let local = r.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        return local.intersects(bounds) ? local : nil
    }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let r = selection, r.width >= 8 || r.height >= 8 { grabber?.dropLit() }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let r = selection, r.width >= 8, r.height >= 8 {
            onFinish?(r.integral)
        } else if let lit = litRect, let c = current, lit.insetBy(dx: -2, dy: -2).contains(c) {
            onPicture?()
        } else {
            start = nil; current = nil; needsDisplay = true
        }
    }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(dimLevel).setFill()
        bounds.fill()
        if let held {
            // Talking about it now: the grab stays clear (a dragged box keeps its purple edge; a picture its glow).
            NSGraphicsContext.current?.compositingOperation = .clear
            if held.glow {
                NSBezierPath(roundedRect: held.rect, xRadius: held.radius, yRadius: held.radius).fill()
            } else {
                held.rect.fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            if !held.glow {
                let border = NSBezierPath(rect: held.rect.insetBy(dx: -1, dy: -1))
                border.lineWidth = 2
                NSColor(hex: 0x8B5CF6).setStroke()
                border.stroke()
            }
        } else if let r = selection {
            NSGraphicsContext.current?.compositingOperation = .clear
            r.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let border = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            NSColor(hex: 0x8B5CF6).setStroke()
            border.stroke()
            drawLabel("\(Int(r.width)) × \(Int(r.height))", at: NSPoint(x: r.minX, y: r.minY - 30), small: true)
        } else if let r = litRect {
            // The picture under the mouse: lifted out of the dimming, at its own corners; the glow layer draws its edge.
            let radius = grabber?.lit?.picture.cornerRadius ?? 0
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let below = r.minY - 44 >= 8
            drawLabel("Click to save this picture", at: NSPoint(x: r.minX, y: below ? r.minY - 44 : r.maxY + 18), small: true)
        } else if showHint, let m = mouse ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) }) {
            drawHint(at: NSPoint(x: m.x + 18, y: m.y - 58))
        }
    }

    private func drawLabel(_ text: String, at p: NSPoint, small: Bool) {
        let font = NSFont(name: DS.pixelName, size: 12) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attr)
        let box = NSRect(x: p.x, y: max(4, p.y), width: size.width + 16, height: size.height + 8)
        NSColor(hex: 0x1A1A1A).withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attr)
    }

    private func drawHint(at p: NSPoint) {
        let f1 = NSFont(name: DS.pixelName, size: 14) ?? .systemFont(ofSize: 13, weight: .semibold)
        let f2 = NSFont(name: DS.pixelName, size: 11) ?? .systemFont(ofSize: 11)
        let a1: [NSAttributedString.Key: Any] = [.font: f1, .foregroundColor: NSColor.white]
        let a2: [NSAttributedString.Key: Any] = [.font: f2, .foregroundColor: NSColor(hex: 0x9A9A9A)]
        let t1 = grabber?.findsPictures == true ? "Click a picture, or drag over anything" : "Drag over anything"
        // Without Accessibility Orca can't see pictures on pages; say so instead of silently not lighting up.
        let t2 = PageInspector.isAllowed ? "you’ll talk right after · esc to cancel"
                                         : "to click pictures, allow OrcaFind in Settings › Accessibility · esc to cancel"
        let w = max((t1 as NSString).size(withAttributes: a1).width, (t2 as NSString).size(withAttributes: a2).width) + 24
        let box = NSRect(x: min(p.x, bounds.maxX - w - 8), y: max(8, p.y), width: w, height: 48)
        NSColor(hex: 0x1A1A1A).withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        (t1 as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 24), withAttributes: a1)
        (t2 as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 8), withAttributes: a2)
    }
}

/// Takes the picture with ScreenCaptureKit, leaving Orca's own windows out.
enum ScreenGrab {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// `rect` is in global AppKit coordinates (bottom-left origin) and lies on `screen`.
    static func capture(rect: NSRect, on screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw NSError(domain: "OrcaFind", code: 10, userInfo: [NSLocalizedDescriptionKey: "Couldn’t find that screen."])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "OrcaFind", code: 11, userInfo: [NSLocalizedDescriptionKey: "Couldn’t find that screen."])
        }
        let me = getpid()
        let ours = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let local = NSRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        config.sourceRect = local
        let scale = screen.backingScaleFactor
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
