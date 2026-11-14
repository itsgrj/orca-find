import AppKit
import Sparkle
import UserNotifications

/// One improvement in a release, in plain words ("Photo search finds more"). Shown by the update UI.
struct UpdateNote: Codable, Hashable, Identifiable {
    var symbol: String
    var title: String
    var detail: String
    var id: String { title }
}

/// Resources/WhatsNew.json: the notes for the version this copy of the app *is*. tools/release.sh turns the
/// same file into the update feed's notes, so "what's new" is written once.
struct WhatsNew: Codable {
    var version: String
    var notes: [UpdateNote]
    static var bundled: WhatsNew? {
        // Inside the app bundle; when run from .build, the project's copy.
        let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json") ?? URL(fileURLWithPath: "Resources/WhatsNew.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WhatsNew.self, from: data)
    }
}

/// In-app updates. Sparkle does the plumbing (reads the feed on the GitHub release, downloads, checks the
/// EdDSA signature, swaps the app, relaunches); Orca draws every bit of UI itself:
/// top-bar Update button, menu bar dot + row, Mac notification, corner card, Settings › General › Updates,
/// "installs when you quit" toast and the welcome-back card. See the Figma page "Proposals · Updates".
@MainActor @Observable
final class Updater: NSObject {
    static let shared = Updater()
    static let releasesPage = URL(string: "https://github.com/itsgrj/orca-find/releases")!

    enum Phase: Equatable {
        case idle, checking, found, downloading(Double), ready, installing, upToDate, failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if case .downloading = phase, case .downloading = oldValue {} else { Self.log("phase \(phase) \(version)") }
            // Dev: ORCA_UPDATE_TEST_RESTART=1 presses "Restart now" by itself (tools: local update test).
            if phase == .ready || phase == .found, ProcessInfo.processInfo.environment["ORCA_UPDATE_TEST_RESTART"] != nil {
                Task { @MainActor in try? await Task.sleep(nanoseconds: 3_000_000_000); Updater.shared.updateNow() }
            }
        }
    }
    /// The waiting update: its version (only shown in Settings), notes and date.
    private(set) var version = ""
    private(set) var notes: [UpdateNote] = []
    private(set) var released: Date?
    private(set) var critical = false
    private(set) var lastChecked: Date?
    var popoverOpen = false
    /// "Update downloaded. It goes in the next time you quit Orca." (shown once per version).
    private(set) var readyToast = false
    /// After an update: the notes for the version now running (welcome-back card).
    private(set) var welcome: [UpdateNote]?

    @ObservationIgnored private var sparkle: SPUUpdater?
    @ObservationIgnored private let driver = UpdateDriver()
    @ObservationIgnored private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var installOnQuitNow: (() -> Void)?
    @ObservationIgnored private var installWhenReady = false
    @ObservationIgnored private var expected: UInt64 = 0
    @ObservationIgnored private var received: UInt64 = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let d = UserDefaults.standard
    /// Bumped whenever a stored dismissal changes, so views re-read the time-based rules.
    private var tick = 0

    private enum K {
        static let lastSeen = "update.lastSeenVersion"
        static let cardClosed = "update.cardClosedVersion"
        static let cardSnooze = "update.cardSnoozedUntil"
        static let toastShown = "update.toastShown"          // [version: Date]
        static let notified = "update.notifiedVersion"
        static let windowSeen = "update.windowLastSeen"
    }

    /// Dev: ORCA_UPDATE_LOG_FILE=<path> appends every step there (tools: local update test); NSLog otherwise.
    static func log(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["ORCA_UPDATE_LOG_FILE"] else { NSLog("Orca update: %@", line); return }
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") \(line)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    // MARK: - What the UI asks

    /// Something is waiting (found, downloading, downloaded) — drives the top-bar button and the menu bar dot.
    var hasUpdate: Bool {
        switch phase { case .found, .downloading, .ready, .installing: return true; default: return false }
    }
    var isReady: Bool { phase == .ready }
    var isDownloading: Bool { if case .downloading = phase { return true }; return false }

    /// "Photo search finds more, and 2 other improvements"
    var summary: String {
        guard let first = notes.first else { return "Fixes and small improvements" }
        let rest = notes.count - 1
        return rest == 0 ? first.title : "\(first.title), and \(rest == 1 ? "one other improvement" : "\(rest) other improvements")"
    }

    /// Corner card on the main window (idea 04). Waits until the "installs when you quit" toast has had its moment.
    var showsCornerCard: Bool {
        _ = tick
        guard phase == .found || phase == .ready, !version.isEmpty, welcome == nil else { return false }
        if d.string(forKey: K.cardClosed) == version { return false }
        if let until = d.object(forKey: K.cardSnooze) as? Date, until > .now { return false }
        if phase == .ready {
            guard let shown = toastShownAt else { return false }
            if readyToast || Date.now.timeIntervalSince(shown) < 4 * 3600 { return false }
        }
        return true
    }

    var automatic: Bool {
        get { _ = tick; return sparkle?.automaticallyDownloadsUpdates ?? true }
        set {
            sparkle?.automaticallyChecksForUpdates = true
            sparkle?.automaticallyDownloadsUpdates = newValue
            tick += 1
        }
    }

    // MARK: - Start

    func start() {
        guard sparkle == nil else { return }
        prepareWelcome()
        // Only a real app bundle can update itself (not `swift run`, not snapshot renders).
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        driver.owner = self
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do { try u.start() } catch { NSLog("Orca updates: \(error.localizedDescription)"); return }
        sparkle = u
        lastChecked = u.lastUpdateCheckDate
        if d.object(forKey: K.windowSeen) == nil { d.set(Date(), forKey: K.windowSeen) }
        setUpNotifications()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, w === AppState.shared.mainWindow else { return }
                Updater.shared.mainWindowSeen()
            }
        }
        // Time-based rules (3 quiet days → notification, remind-me-tomorrow) are re-checked hourly.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.tick += 1; Updater.shared.maybeNotify() }
        }
        // A fresh check shortly after launch, then Sparkle's own daily schedule.
        if u.automaticallyChecksForUpdates { u.checkForUpdatesInBackground() }
    }

    // MARK: - Actions

    /// "Update now" / "Restart" everywhere.
    func updateNow() {
        popoverOpen = false
        readyToast = false
        if let go = installOnQuitNow { phase = .installing; go(); return }
        installWhenReady = true
        if let reply = pendingChoice { pendingChoice = nil; reply(.install); return }
        checkNow()
    }

    func checkNow() {
        guard let s = sparkle else { return }
        if s.canCheckForUpdates { s.checkForUpdates() }
    }

    func later() { popoverOpen = false }
    func remindTomorrow() { d.set(Date().addingTimeInterval(24 * 3600), forKey: K.cardSnooze); tick += 1 }
    func closeCard() { d.set(version, forKey: K.cardClosed); tick += 1 }
    func closeToast() { readyToast = false; toastTask?.cancel(); tick += 1 }
    func dismissWelcome() { d.set(currentVersion, forKey: K.lastSeen); welcome = nil }

    // MARK: - Rules

    private var toastShownAt: Date? { (d.dictionary(forKey: K.toastShown) as? [String: Date])?[version] }

    private func mainWindowSeen() {
        d.set(Date(), forKey: K.windowSeen)
        tick += 1
        maybeShowToast()
    }

    /// Once per version, while the main window is on screen.
    private func maybeShowToast() {
        guard phase == .ready, !version.isEmpty, toastShownAt == nil, welcome == nil else { return }
        guard let w = AppState.shared.mainWindow, w.isVisible else {
            Self.log("toast waits for the window (window \(AppState.shared.mainWindow == nil ? "unknown" : "hidden"))"); return
        }
        var shown = (d.dictionary(forKey: K.toastShown) as? [String: Date]) ?? [:]
        shown[version] = Date()
        d.set(shown, forKey: K.toastShown)
        readyToast = true
        Self.log("toast shown \(version)")
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { Updater.shared.closeToast() }
        }
    }

    /// A Mac notification only for people who haven't opened Orca's window for 3 days, or for an important fix.
    /// Once per version.
    private func maybeNotify() {
        guard hasUpdate, phase != .installing, !version.isEmpty, d.string(forKey: K.notified) != version else { return }
        let seen = d.object(forKey: K.windowSeen) as? Date ?? .now
        let forced = ProcessInfo.processInfo.environment["ORCA_UPDATE_NOTIFY_NOW"] != nil
        guard critical || forced || Date.now.timeIntervalSince(seen) > 3 * 24 * 3600 else { return }
        guard forced || !NSApp.isActive else { return }
        d.set(version, forKey: K.notified)
        let content = UNMutableNotificationContent()
        content.title = "A better Orca is ready"
        content.body = "\(notes.first.map { $0.title + "." } ?? "Fixes and small improvements.") Update in one click, it takes about 10 seconds."
        content.categoryIdentifier = "orca.update"
        let request = UNNotificationRequest(identifier: "orca.update.\(version)", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            if ok { center.add(request) }
        }
    }

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let update = UNNotificationAction(identifier: "update", title: "Update", options: [])
        let later = UNNotificationAction(identifier: "later", title: "Later", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "orca.update", actions: [update, later], intentIdentifiers: [])])
    }

    /// The welcome-back card shows once after an update (not on a fresh install).
    private func prepareWelcome() {
        let cur = currentVersion
        if ProcessInfo.processInfo.environment["ORCA_SHOW_WELCOME"] != nil, let w = WhatsNew.bundled { welcome = w.notes; return }
        let seen = d.string(forKey: K.lastSeen)
        guard seen != cur else { return }
        // Only when moving *up* (not after going back to an older copy).
        if let seen, cur.compare(seen, options: .numeric) != .orderedDescending { d.set(cur, forKey: K.lastSeen); return }
        // No record + never onboarded = a brand-new install: nothing to welcome back to.
        // No record + onboarded = someone on a version from before Orca could update itself.
        guard seen != nil || Preferences.shared.onboarded,
              let w = WhatsNew.bundled, w.version == cur, !w.notes.isEmpty else { d.set(cur, forKey: K.lastSeen); return }
        welcome = w.notes
        Self.log("welcome card for \(cur) (last seen \(seen ?? "none"))")
    }

    // MARK: - Feed item → plain notes

    private func adopt(_ item: SUAppcastItem) {
        version = item.displayVersionString
        notes = Self.parseNotes(item.itemDescription)
        released = item.date
        critical = item.isCriticalUpdate
    }

    /// The feed's notes are `<li data-symbol="photo"><b>Title</b> — detail</li>` (written by tools/release.sh).
    static func parseNotes(_ html: String?) -> [UpdateNote] {
        guard let html, !html.isEmpty else { return [] }
        let li = try! NSRegularExpression(pattern: #"<li(?:\s+data-symbol="([^"]*)")?\s*>(.*?)</li>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = html as NSString
        var out: [UpdateNote] = []
        for m in li.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let symbol = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : "sparkles"
            let inner = ns.substring(with: m.range(at: 2))
            var title = inner, detail = ""
            if let b = inner.range(of: #"<b>(.*?)</b>"#, options: .regularExpression) {
                title = String(inner[b]); detail = String(inner[b.upperBound...])
            }
            title = plain(title)
            detail = plain(detail).trimmingCharacters(in: CharacterSet(charactersIn: " —–-:"))
            if !title.isEmpty { out.append(UpdateNote(symbol: symbol.isEmpty ? "sparkles" : symbol, title: title, detail: detail)) }
        }
        if out.isEmpty {
            let text = plain(html)
            if !text.isEmpty { out = [UpdateNote(symbol: "sparkles", title: text, detail: "")] }
        }
        return out
    }

    private static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - From the user driver (Sparkle calls these on the main thread)

    fileprivate func found(_ item: SUAppcastItem, stage: SPUUserUpdateStage, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if item.isInformationOnlyUpdate { reply(.dismiss); return }
        adopt(item)
        if installWhenReady {
            reply(.install)
            phase = stage == .notDownloaded ? .downloading(0) : .installing
            return
        }
        pendingChoice = reply
        phase = stage == .notDownloaded ? .found : .ready
        maybeShowToast()
        maybeNotify()
    }

    fileprivate func checking() { if !hasUpdate { phase = .checking } }
    fileprivate func downloadStarted() { expected = 0; received = 0; phase = .downloading(0) }
    fileprivate func downloadExpected(_ n: UInt64) { expected = n }
    fileprivate func downloadReceived(_ n: UInt64) {
        received += n
        phase = .downloading(expected > 0 ? min(0.99, Double(received) / Double(expected)) : 0)
    }
    fileprivate func extracting(_ p: Double) { phase = .downloading(0.99) }

    fileprivate func readyToInstall(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installWhenReady { phase = .installing; reply(.install); return }
        pendingChoice = reply
        phase = .ready
        maybeShowToast()
        maybeNotify()
    }

    fileprivate func installing() { phase = .installing }

    fileprivate func notFound() {
        phase = .upToDate
        installWhenReady = false
        lastChecked = Date()
    }

    fileprivate func failed(_ error: Error) {
        installWhenReady = false
        lastChecked = sparkle?.lastUpdateCheckDate ?? lastChecked
        let ns = error as NSError
        // Offline / feed unreachable reads as a plain sentence, not an error code.
        if ns.domain == NSURLErrorDomain || (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSURLErrorDomain {
            phase = .failed("Couldn’t reach the update server. Check your internet connection.")
        } else {
            phase = .failed("Couldn’t check for updates right now. Orca will try again later.")
        }
    }

    fileprivate func dismissed() {
        guard installOnQuitNow == nil else { return }
        pendingChoice = nil
        installWhenReady = false
        switch phase { case .upToDate, .failed: break; default: phase = .idle }
    }

    fileprivate func focus() {
        AppState.shared.openMainWindow()
        popoverOpen = true
    }

    /// Test hook for snapshots: put the UI into a given state without a feed.
    func debugSet(phase: Phase, version: String = "1.1.0", notes: [UpdateNote]? = nil, toast: Bool = false, welcome: [UpdateNote]? = nil) {
        self.phase = phase
        self.version = version
        self.notes = notes ?? WhatsNew.bundled?.notes ?? []
        self.readyToast = toast
        self.welcome = welcome
        self.lastChecked = Date().addingTimeInterval(-60)
        tick += 1
    }
}

// MARK: - Sparkle delegate

extension Updater: SPUUpdaterDelegate {
    /// ORCA_UPDATE_FEED (or the `updateFeedURL` default) points a test build at a local feed.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["ORCA_UPDATE_FEED"] ?? UserDefaults.standard.string(forKey: "updateFeedURL")
    }

    /// Downloaded in the background: it goes in when Orca quits. We keep the "install now" handle for Restart.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            let u = Updater.shared
            u.adopt(item)
            u.installOnQuitNow = immediateInstallHandler
            u.pendingChoice = nil
            if u.installWhenReady { u.phase = .installing; immediateInstallHandler(); return true }
            u.phase = .ready
            u.maybeShowToast()
            u.maybeNotify()
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated { Updater.shared.lastChecked = updater.lastUpdateCheckDate }
    }
}

// MARK: - Notifications

extension Updater: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let ours = response.notification.request.content.categoryIdentifier == "orca.update"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard ours else { return }
                switch action {
                case "update": Updater.shared.updateNow()
                case "later", UNNotificationDismissActionIdentifier: break
                default: Updater.shared.focus()
                }
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

// MARK: - User driver: every Sparkle UI moment lands in Updater; nothing of Sparkle's own UI is shown.

final class UpdateDriver: NSObject, SPUUserDriver {
    weak var owner: Updater?

    private func on(_ f: @escaping @MainActor (Updater) -> Void) {
        MainActor.assumeIsolated { if let o = owner { f(o) } }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { on { $0.checking() } }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        on { $0.found(appcastItem, stage: state.stage, reply: reply) }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { on { $0.notFound() }; acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { on { $0.failed(error) }; acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { on { $0.downloadStarted() } }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { on { $0.downloadExpected(expectedContentLength) } }
    func showDownloadDidReceiveData(ofLength length: UInt64) { on { $0.downloadReceived(length) } }
    func showDownloadDidStartExtractingUpdate() { on { $0.extracting(0) } }
    func showExtractionReceivedProgress(_ progress: Double) { on { $0.extracting(progress) } }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { on { $0.readyToInstall(reply) } }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { on { $0.installing() } }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { on { $0.dismissed() } }
    func showUpdateInFocus() { on { $0.focus() } }
}

// MARK: - Menu bar icon with a dot (idea 02)

extension MenuBarGlyph {
    /// The orca glyph in the menu bar's text colour with a blue dot at the top-right.
    /// Drawn at draw time so it follows a light or dark menu bar (a template image can't carry the blue).
    static let withDot: NSImage = {
        let size = NSSize(width: 22, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let glyph = MenuBarGlyph.image
            let g = NSRect(x: 0, y: 0, width: 18, height: 18)
            NSGraphicsContext.current?.saveGraphicsState()
            glyph.draw(in: g)
            NSColor.labelColor.set()
            g.fill(using: .sourceAtop)
            NSGraphicsContext.current?.restoreGraphicsState()
            let dot = NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 7, height: 7)
            NSColor.clear.set()
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill(with: .copy)
            NSColor.systemBlue.set()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.isTemplate = false
        return img
    }()
}

private extension NSRect {
    func fill(using op: NSCompositingOperation) { __NSRectFillUsingOperation(self, op) }
}

private extension NSBezierPath {
    func fill(with op: NSCompositingOperation) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = op
        fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
