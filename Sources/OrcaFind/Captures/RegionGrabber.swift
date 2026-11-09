import AppKit
import ScreenCaptureKit

/// Panel that takes keys without making Orca the active app — the app you were in stays in front.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// "Drag over anything": dims every screen, draws the box as you drag, Esc gives up.
@MainActor
final class RegionGrabber {
    static let shared = RegionGrabber()
    private var windows: [CapturePanel] = []
    private var completion: ((NSRect?, NSScreen?) -> Void)?
    private var keyMonitor: Any?

    var isActive: Bool { !windows.isEmpty }

    func begin(_ done: @escaping (NSRect?, NSScreen?) -> Void) {
        guard !isActive else { return }
        completion = done
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
            view.showHint = NSMouseInRect(mouse, screen.frame, false)
            view.onFinish = { [weak self] rect in self?.finish(rect.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }, screen) }
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
        }
        // The panel under the mouse takes keys (Esc) without activating Orca.
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.push()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.finish(nil, nil) }; return nil }
            return e
        }
    }

    private func finish(_ rect: NSRect?, _ screen: NSScreen?) {
        guard isActive else { return }
        NSCursor.pop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let done = completion
        completion = nil
        done?(rect, screen)
    }
}

private final class GrabView: NSView {
    var screen0: NSScreen?
    var showHint = true
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private var mouse: NSPoint?

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
    }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let r = selection, r.width >= 8, r.height >= 8 {
            onFinish?(r.integral)
        } else {
            start = nil; current = nil; needsDisplay = true
        }
    }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let r = selection {
            NSGraphicsContext.current?.compositingOperation = .clear
            r.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let border = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            NSColor(hex: 0x8B5CF6).setStroke()
            border.stroke()
            drawLabel("\(Int(r.width)) × \(Int(r.height))", at: NSPoint(x: r.minX, y: r.minY - 30), small: true)
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
        let t1 = "Drag over anything", t2 = "you’ll talk right after · esc to cancel"
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
