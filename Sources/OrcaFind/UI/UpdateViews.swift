import SwiftUI
import AppKit

// Every place Orca says "a better version is ready". State lives in Services/Updater.swift.
// Mockups: Figma "Proposals · Updates" — 01 top-bar button, 02 menu bar row, 04 corner card,
// 07 Settings › Updates, 08 installs-when-you-quit toast, 10 welcome-back card. (03 is a Mac notification.)

private let updateBlue = Color(nsColor: .systemBlue)

// MARK: - 01 Top-bar button + its card

struct UpdatePill: View {
    var up = Updater.shared
    var body: some View {
        @Bindable var u = up
        if up.hasUpdate {
            Button { up.popoverOpen.toggle() } label: {
                HStack(spacing: 6) {
                    if case .downloading(let p) = up.phase {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.3), lineWidth: 2.2)
                            Circle().trim(from: 0, to: max(0.04, p)).stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).rotationEffect(.degrees(-90))
                        }
                        .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.down.circle").font(.system(size: 12, weight: .semibold))
                    }
                    Text(label).font(DS.bodySM)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(updateBlue))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).handCursor()
            .popover(isPresented: $u.popoverOpen, arrowEdge: .bottom) { UpdatePopover() }
            .help("A better version of Orca is ready")
        }
    }

    private var label: String {
        switch up.phase {
        case .downloading(let p): return "Updating · \(Int(p * 100))%"
        case .installing: return "Restarting…"
        default: return "Update"
        }
    }
}

struct UpdateNotesList: View {
    let notes: [UpdateNote]
    var limit = 3
    var detail = false
    var body: some View {
        VStack(alignment: .leading, spacing: detail ? 14 : 8) {
            ForEach(Array(notes.prefix(limit).enumerated()), id: \.offset) { i, n in
                if detail {
                    HStack(alignment: .top, spacing: 12) {
                        ToneIcon(symbol: n.symbol, tone: [DS.Tone.info, .success, .attention, .magic][i % 4])
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.title).font(DS.body).foregroundStyle(DS.text)
                            if !n.detail.isEmpty { Text(n.detail).font(DS.bodySM).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: n.symbol).font(.system(size: 12)).foregroundStyle(DS.text).frame(width: 16)
                        Text(n.title).font(DS.body).foregroundStyle(DS.text2)
                    }
                }
            }
        }
    }
}

struct UpdatePopover: View {
    var up = Updater.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A better Orca is ready").font(DS.headingSM).foregroundStyle(DS.text)
            UpdateNotesList(notes: up.notes)
            switch up.phase {
            case .downloading(let p):
                ProgressView(value: p).progressViewStyle(.linear)
                Text("Downloading… Orca restarts by itself when it’s done.").font(DS.caption).foregroundStyle(DS.text3)
            case .installing:
                Text("Restarting Orca…").font(DS.caption).foregroundStyle(DS.text3)
            default:
                HStack(spacing: 8) {
                    Button("Update now") { up.updateNow() }.buttonStyle(.primary)
                    Button("Later") { up.later() }.buttonStyle(.plainP)
                }
                Text(up.isReady ? "Takes about 10 seconds. Orca reopens right where you were. Or keep working: it goes in when you quit."
                                : "Takes about 10 seconds. Orca reopens right where you were.")
                    .font(DS.caption).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - 02 Menu bar row (+ the "Quit & update" footer label)

struct UpdateMenuRow: View {
    var up = Updater.shared
    var body: some View {
        if up.hasUpdate {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.system(size: 17, weight: .medium)).foregroundStyle(updateBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A new version is ready").font(DS.body).foregroundStyle(MenuLook.text)
                    Text(subtitle).font(DS.bodySM).foregroundStyle(MenuLook.text2).lineLimit(1)
                }
                Spacer(minLength: 6)
                if !up.isDownloading && up.phase != .installing {
                    Button(up.isReady ? "Restart" : "Update") { up.updateNow() }.buttonStyle(.primary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(DS.Tone.info.bg.opacity(MenuLook.glass ? 0.7 : 1)))
            .padding(.horizontal, 8).padding(.bottom, 6)
        }
    }
    private var subtitle: String {
        switch up.phase {
        case .downloading(let p): return "Downloading · \(Int(p * 100))%"
        case .installing: return "Restarting Orca…"
        case .ready: return "Restart Orca to get it · about 10 sec"
        default: return "Get it in one click · about 10 sec"
        }
    }
}

/// "Quit" in the menu bar footer; "• Quit & update" once an update is waiting to go in.
struct UpdateQuitLabel: View {
    var up = Updater.shared
    var body: some View {
        HStack(spacing: 6) {
            if up.isReady { Circle().fill(updateBlue).frame(width: 7, height: 7) }
            Text(up.isReady ? "Quit & update" : "Quit").font(DS.bodySM)
        }
    }
}

// MARK: - Main-window overlays: 04 corner card, 08 toast, 10 welcome-back card

struct UpdateOverlays: ViewModifier {
    var up = Updater.shared
    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if up.showsCornerCard && state.prefs.onboarded {
                    UpdateCornerCard().padding(24).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if up.readyToast && state.toast == nil {
                    UpdateReadyToast().padding(.bottom, 26).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if let notes = up.welcome, state.prefs.onboarded {
                    ZStack {
                        Color.black.opacity(0.32).ignoresSafeArea().onTapGesture { up.dismissWelcome() }
                        WelcomeBackCard(notes: notes)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.35), value: up.showsCornerCard)
            .animation(.spring(duration: 0.3), value: up.readyToast)
            .animation(.easeOut(duration: 0.2), value: up.welcome == nil)
    }
}

struct UpdateCornerCard: View {
    var up = Updater.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: MenuBarGlyph.image).resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 20, height: 20).foregroundStyle(DS.onBrand)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.brand))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orca got better").font(DS.headingSM).foregroundStyle(DS.text)
                    Text(sentence).font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { up.closeCard() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.text3).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor().help("Hide until the next update")
            }
            HStack(spacing: 8) {
                Button(up.isReady ? "Restart to update" : "Update now") { up.updateNow() }.buttonStyle(.primary)
                Button("Remind me tomorrow") { up.remindTomorrow() }.buttonStyle(.plainP)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .card(16)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    /// "Photo search finds more, and the menu bar list is easier to read."
    private var sentence: String {
        let t = up.notes.prefix(2).map(\.title)
        guard let first = t.first else { return "Fixes and small improvements." }
        guard t.count > 1 else { return first + "." }
        let second = t[1].prefix(1).lowercased() + t[1].dropFirst()
        return "\(first), and \(second)."
    }
}

struct UpdateReadyToast: View {
    var up = Updater.shared
    var body: some View {
        DarkPill {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
            Text("Update downloaded. It goes in the next time you quit Orca.").font(DS.body)
            Button { up.updateNow() } label: {
                Text("Restart now").font(DS.bodySM).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(updateBlue))
            }
            .buttonStyle(.plain).handCursor()
            Button { up.closeToast() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.onDark2).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).handCursor()
        }
    }
}

struct WelcomeBackCard: View {
    let notes: [UpdateNote]
    var up = Updater.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                DS.surface
                if let art = Art.image("orca-dither@2x.png") {
                    // Show the right-hand part of the picture, where the orca leaps (55% of its width).
                    let w = 480 / 0.55, h = w * art.size.height / max(1, art.size.width)
                    Image(nsImage: art).resizable()
                        .frame(width: w, height: h)
                        .offset(x: (w - 480) / 2 - 0.42 * w, y: (h - 170) / 2 - 0.25 * h)
                }
            }
            .frame(width: 480, height: 170).clipped()
            VStack(alignment: .leading, spacing: 16) {
                PixelLabel("You’re up to date")
                Text("Orca just got better").font(DS.headingMD).foregroundStyle(DS.text)
                UpdateNotesList(notes: notes, limit: 4, detail: true)
                HStack {
                    Button("See everything that changed") {
                        NSWorkspace.shared.open(Updater.releasesPage.appendingPathComponent("tag/v\(up.currentVersion)"))
                    }
                    .buttonStyle(.plain).font(DS.body).foregroundStyle(DS.link).handCursor()
                    Spacer()
                    Button("Got it") { up.dismissWelcome() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 480)
        .card(16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
    }
}

// MARK: - 07 Settings › General › Updates

struct UpdatesSettings: View {
    var up = Updater.shared
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PixelLabel("Updates")
            VStack(spacing: 0) {
                status
                divider
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Keep Orca up to date automatically").font(DS.body).foregroundStyle(DS.text)
                        Text("New versions download in the background and go in when you quit Orca, so nothing is interrupted.")
                            .font(DS.caption).foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { up.automatic }, set: { up.automatic = $0 })).toggleStyle(.switch).labelsHidden()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                divider
                HStack {
                    Text(footer).font(DS.caption).foregroundStyle(DS.text3)
                    Spacer()
                    if up.phase == .checking { ProgressView().controlSize(.small) }
                    Button("Check now") { up.checkNow() }.buttonStyle(.plainP).disabled(up.phase == .checking || up.hasUpdate)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
        }
    }

    private var divider: some View { Rectangle().fill(DS.border).frame(height: 1) }

    @ViewBuilder private var status: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 15, weight: .medium)).foregroundStyle(up.hasUpdate ? updateBlue : DS.text2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.body).foregroundStyle(DS.text)
                if let sub = subtitle { Text(sub).font(DS.caption).foregroundStyle(DS.text2) }
            }
            Spacer()
            if up.hasUpdate {
                Button("See what’s new") { showNotes.toggle() }.buttonStyle(.plainP)
                    .popover(isPresented: $showNotes, arrowEdge: .bottom) {
                        UpdateNotesList(notes: up.notes, limit: 6, detail: true).padding(16).frame(width: 340, alignment: .leading)
                    }
                if case .downloading(let p) = up.phase {
                    ProgressView(value: p).frame(width: 90)
                } else if up.phase != .installing {
                    Button(up.isReady ? "Restart to update" : "Update now") { up.updateNow() }.buttonStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var statusSymbol: String {
        if up.hasUpdate { return "arrow.down.circle" }
        if case .failed = up.phase { return "exclamationmark.circle" }
        return "checkmark.circle"
    }
    private var title: String {
        switch up.phase {
        case .found, .ready: return "A new version is ready"
        case .downloading: return "Downloading the new version…"
        case .installing: return "Restarting Orca…"
        case .checking: return "Checking…"
        case .failed(let msg): return msg
        default: return "Orca is up to date"
        }
    }
    private var subtitle: String? {
        switch up.phase {
        case .found, .ready, .downloading: return up.summary
        default: return nil
        }
    }
    private var footer: String {
        var s = "OrcaFind \(up.currentVersion)"
        if let d = up.lastChecked { s += " · last checked \(Fmt.relative(d))" }
        return s
    }
}

// MARK: - Dev: `OrcaFind --update-snapshot <dir> [dark]` renders every update surface to PNGs (run from the .app).

enum UpdateDebug {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--update-snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1]); let dark = args.contains("dark")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            FontLoader.register()
            NSAppearance.current = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let up = Updater.shared
            let bg = dark ? Color(hex: 0x0E1116) : Color(hex: 0xF1F1F1)
            @MainActor func shot<V: View>(_ name: String, _ v: V) {
                let r = ImageRenderer(content: v.padding(20).background(bg).environment(\.colorScheme, dark ? .dark : .light))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(name + ".png")); print("wrote", name)
                }
            }
            up.debugSet(phase: .ready)
            shot("01-pill", HStack { UpdatePill() }.padding(10).background(DS.topbar))
            shot("01-popover", UpdatePopover().background(DS.surface))
            up.debugSet(phase: .downloading(0.42))
            shot("01-pill-downloading", HStack { UpdatePill() }.padding(10).background(DS.topbar))
            up.debugSet(phase: .ready)
            shot("02-menu-row", VStack(spacing: 0) { UpdateMenuRow(); HStack { Spacer(); UpdateQuitLabel() }.padding(14) }.frame(width: 380).background(DS.surface))
            up.debugSet(phase: .found)
            shot("02-menu-row-found", UpdateMenuRow().frame(width: 380).background(DS.surface))
            shot("02-menubar-dot", Image(nsImage: MenuBarGlyph.withDot).padding(6).background(dark ? Color.black : Color.white))
            shot("04-corner-card", UpdateCornerCard())
            up.debugSet(phase: .ready)
            shot("08-toast", UpdateReadyToast())
            shot("10-welcome", WelcomeBackCard(notes: WhatsNew.bundled?.notes ?? []))
            shot("07-settings-ready", UpdatesSettings().frame(width: 612))
            up.debugSet(phase: .idle)
            shot("07-settings-idle", UpdatesSettings().frame(width: 612))
            up.debugSet(phase: .failed("Couldn’t reach the update server. Check your internet connection."))
            shot("07-settings-failed", UpdatesSettings().frame(width: 612))
        }
        exit(0)
    }
}
