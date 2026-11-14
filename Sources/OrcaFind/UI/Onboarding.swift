import SwiftUI
import AppKit

/// First launch: show what Orca does before asking for anything, let people make it theirs, then get
/// Full Disk Access right the first time (guided, with a check that says what Orca can really open).
struct OnboardingView: View {
    enum Step: Int, CaseIterable { case demo, look, access, ai }

    @Environment(AppState.self) private var state
    @State private var step: Step

    init(showAI: Bool = false, step: Step? = nil) {
        _step = State(initialValue: step ?? (showAI ? .ai : .demo))
    }

    var body: some View {
        ZStack {
            AppBackground(style: state.prefs.background)
            VStack(alignment: .leading, spacing: 18) {
                if step != .ai { dots }
                switch step {
                case .demo: OnboardingDemo { go(.look) }
                case .look: OnboardingLook { go(.access) }
                case .access: OnboardingAccess { finishAccess() }
                case .ai: PrivateAIOnboarding { done() }
                }
            }
            .padding(34)
            .frame(width: 680)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.surface))
            .shadow(color: .black.opacity(0.16), radius: 30, y: 16)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach([Step.demo, .look, .access], id: \.self) { s in
                Capsule().fill(s == step ? DS.brand : DS.border).frame(width: s == step ? 20 : 7, height: 7)
            }
            Spacer()
            if step != .demo {
                Button("Back") { go(Step(rawValue: step.rawValue - 1) ?? .demo) }.buttonStyle(.plainP)
            }
        }
    }

    private func go(_ s: Step) { withAnimation(.easeOut(duration: 0.22)) { step = s } }

    private func finishAccess() {
        if PrivateAI.shared.locked.isEmpty { done() } else { go(.ai) }
    }

    private func done() {
        state.prefs.onboarded = true
        state.index.rescan()
        state.focusSearch()
    }
}

// MARK: - 1 · Before and after

/// Made-up files show what Orca does, before it asks for anything.
private struct OnboardingDemo: View {
    let next: () -> Void
    @State private var after = false
    @State private var timer: Timer?

    private let messy = ["IMG_4100 copy.JPG", "Invoice-March (1).pdf", "Screen Shot 2026-11-03 at 09.14.22.png", "IMG_4101.HEIC",
                         "final_FINAL_v3.key", "untitled folder 4", "Rectangle-0.85.dmg", "brand-board-v3.jpg",
                         "IMG-20261103-WA0012.jpg", "Team notes.docx", "dataset-2026.zip", "IMG_4102.HEIC", "Scan 12.pdf"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to OrcaFind").font(DS.display).foregroundStyle(DS.text)
            Text("Your files as big, clear cards, and a search that understands plain English or your voice.")
                .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            ZStack {
                if after { cards.transition(.opacity.combined(with: .scale(scale: 0.98))) } else { list.transition(.opacity) }
            }
            .frame(height: 250)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.surface2))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 2) {
                    seg("Before", !after) { after = false }
                    seg("With OrcaFind", after) { after = true }
                }
                .padding(2).background(Capsule().fill(DS.surface)).padding(10)
            }
            HStack {
                Text("These are made-up files. Your own show up in a moment.").font(DS.caption).foregroundStyle(DS.text2)
                Spacer()
                Button("Get started") { next() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            // Flips between the two by itself, so the point lands without a click.
            timer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: true) { _ in
                MainActor.assumeIsolated { withAnimation(.easeInOut(duration: 0.45)) { after.toggle() } }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func seg(_ t: String, _ on: Bool, _ a: @escaping () -> Void) -> some View {
        Button { timer?.invalidate(); withAnimation(.easeInOut(duration: 0.3)) { a() } } label: {
            Text(t).font(DS.bodySM).foregroundStyle(on ? DS.onBrand : DS.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(on ? DS.brand : .clear))
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(messy.prefix(10).enumerated()), id: \.offset) { i, name in
                HStack(spacing: 8) {
                    Image(systemName: name.hasPrefix("untitled") ? "folder" : "doc").font(.system(size: 11)).foregroundStyle(DS.text3).frame(width: 14)
                    Text(name).font(.system(size: 11)).foregroundStyle(DS.text2).lineLimit(1)
                    Spacer()
                    Text(["12 KB", "1.2 MB", "340 KB", "2.8 MB"][i % 4]).font(.system(size: 10)).foregroundStyle(DS.text3)
                }
                .padding(.horizontal, 14).padding(.vertical, 2.5)
                .background(i % 2 == 0 ? Color.clear : DS.text.opacity(0.03))
            }
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
        .frame(height: 250, alignment: .top)
        .clipped()
    }

    private var cards: some View {
        HStack(spacing: 14) {
            GlassFolder(title: "Images", meta: "1,284 · 6.2 GB", palette: .of(.images), style: .of(.images), items: [], width: 140)
            GlassFolder(title: "Documents", meta: "642 · 1.1 GB", palette: .of(.documents), style: .of(.documents), items: [], width: 140)
            GlassFolder(title: "Downloads", meta: "From Gmail, Slack…", palette: .brand(0x3BA4FF), style: .icons, items: [], width: 140)
            GlassFolder(title: "Videos", meta: "38 · 12 GB", palette: .of(.videos), style: .of(.videos), items: [], width: 140)
        }
        .padding(.top, 30)
    }
}

// MARK: - 2 · Make it yours

/// Each choice changes the preview straight away (and the app, since they're the real settings).
private struct OnboardingLook: View {
    @Environment(AppState.self) private var state
    let next: () -> Void

    var body: some View {
        @Bindable var p = state.prefs
        VStack(alignment: .leading, spacing: 16) {
            Text("Make it yours").font(DS.display).foregroundStyle(DS.text)
            Text("Pick how OrcaFind looks. You can change any of this later in Settings.").font(DS.body).foregroundStyle(DS.text2)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        PixelLabel("Appearance")
                        Picker("", selection: $p.appearance) { ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PixelLabel("Background")
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 8), count: 3), alignment: .leading, spacing: 8) {
                            ForEach(BackgroundStyle.allCases) { b in
                                Button { p.background = b } label: {
                                    VStack(spacing: 3) {
                                        AppBackground(style: b).frame(width: 72, height: 46).clipShape(RoundedRectangle(cornerRadius: 7))
                                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.background == b ? DS.brand : DS.border, lineWidth: p.background == b ? 2 : 1))
                                        Text(b.title).font(DS.caption).foregroundStyle(p.background == b ? DS.text : DS.text2).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PixelLabel("Card size")
                        Slider(value: $p.cardSize, in: 110...240).frame(width: 230)
                    }
                }
                .frame(width: 240, alignment: .leading)
                preview
            }
            HStack {
                Spacer()
                Button("Continue") { next() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var preview: some View {
        let w = CGFloat(state.prefs.cardSize) * 0.62
        return ZStack {
            AppBackground(style: state.prefs.background)
            HStack(spacing: 10) {
                GlassFolder(title: "Images", meta: "1,284", palette: .of(.images), style: .of(.images), items: [], width: w)
                GlassFolder(title: "Documents", meta: "642", palette: .of(.documents), style: .of(.documents), items: [], width: w)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.border))
        .animation(.easeOut(duration: 0.2), value: state.prefs.cardSize)
    }
}

// MARK: - 3 · Full Disk Access, guided

private struct OnboardingAccess: View {
    @Environment(AppState.self) private var state
    let next: () -> Void
    @State private var results: [AccessCheck.Result] = []
    @State private var checking = false
    @State private var checkedOnce = false

    var body: some View {
        let allOpen = !results.isEmpty && results.allSatisfy(\.open)
        VStack(alignment: .leading, spacing: 16) {
            Text("Let OrcaFind see all your files").font(DS.display).foregroundStyle(DS.text)
            Text("OrcaFind searches your whole home folder. macOS keeps some of it behind Full Disk Access, and without it searches quietly miss files. Nothing ever leaves this Mac.")
                .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                stepRow(1, "Open Privacy & Security › Full Disk Access") {
                    Button("Open System Settings") { AccessHelper.shared.show() }.buttonStyle(.primary)
                }
                stepRow(2, "Drag the OrcaFind icon from the small window into the list, then turn it on") { EmptyView() }
                stepRow(3, "Come back and check") {
                    Button(checking ? "Checking…" : "Check now") { check() }.buttonStyle(.secondary).disabled(checking)
                }
            }
            .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.name) { i, r in
                        HStack(spacing: 10) {
                            Image(systemName: r.symbol).frame(width: 20).foregroundStyle(DS.text2)
                            Text(r.name).font(DS.body).foregroundStyle(DS.text)
                            Spacer()
                            if r.open { Badge("Can open ✓", tone: .success) } else { Badge("Can’t open yet", tone: .attention) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        if i < results.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
                if checkedOnce && !allOpen {
                    Text("Just turned it on? macOS may ask OrcaFind to quit and reopen before it counts.")
                        .font(DS.caption).foregroundStyle(DS.text2)
                }
            }
            HStack {
                Badge("Nothing leaves this Mac", tone: .success)
                Spacer()
                Button(allOpen ? "Continue" : "Skip for now") { AccessHelper.shared.hide(); next() }
                    .buttonStyle(allOpen ? .primary : .secondary).keyboardShortcut(.defaultAction)
            }
        }
        .task { check(first: true) }
    }

    private func stepRow<R: View>(_ n: Int, _ text: String, @ViewBuilder _ trailing: () -> R) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(DS.bodySM).foregroundStyle(DS.onBrand).frame(width: 22, height: 22).background(Circle().fill(DS.brand))
            Text(text).font(DS.body).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
    }

    private func check(first: Bool = false) {
        checking = true
        Task.detached {
            let r = AccessCheck.run()
            await MainActor.run {
                results = r
                checking = false
                if !first { checkedOnce = true }
                if r.allSatisfy(\.open) { AccessHelper.shared.hide() }
            }
        }
    }
}

/// Folder by folder, what Orca can actually open right now.
enum AccessCheck {
    struct Result: Sendable {
        let name: String
        let symbol: String
        let open: Bool
    }

    static func run() -> [Result] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func can(_ rel: String) -> Bool { (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(rel).path)) != nil }
        var out = [Result(name: "Desktop", symbol: "menubar.dock.rectangle", open: can("Desktop")),
                   Result(name: "Documents", symbol: "doc.text", open: can("Documents")),
                   Result(name: "Downloads", symbol: "arrow.down.circle", open: can("Downloads"))]
        // These only open with Full Disk Access: a clear yes/no for whether it's on.
        if fm.fileExists(atPath: home.appendingPathComponent("Library/Mail").path) {
            out.append(Result(name: "Mail attachments", symbol: "paperclip", open: can("Library/Mail")))
        }
        out.append(Result(name: "The Trash", symbol: "trash", open: can(".Trash")))
        out.append(Result(name: "Everything else in your home folder", symbol: "house", open: can("Library/Safari") || can("Library/Mail")))
        return out
    }
}

/// The small window to drag the app icon from, beside System Settings.
@MainActor
final class AccessHelper {
    static let shared = AccessHelper()
    private var panel: NSPanel?

    func show() {
        Onboarding.openFullDiskAccess()
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = "Drag OrcaFind into the list"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: AccessHelperView().frame(width: 300, height: 120))
            panel = p
        }
        guard let p = panel, let vf = NSScreen.main?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: vf.maxX - p.frame.width - 40, y: vf.minY + 60))
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private struct AccessHelperView: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 64, height: 64)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .modifier(GrabCursor(pressed: false, hovering: true))
            VStack(alignment: .leading, spacing: 4) {
                Text("Drag this icon").font(DS.body).foregroundStyle(DS.text)
                Text("into the Full Disk Access list in System Settings, then turn OrcaFind on.")
                    .font(DS.caption).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }
}
