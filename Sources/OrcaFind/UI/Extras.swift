import SwiftUI
import Speech

// MARK: - Menu bar

struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let downloads = Array(state.homeStats.latestDownloads.prefix(10))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Latest downloads").font(DS.headingSM).foregroundStyle(DS.text)
                Spacer()
                Button("Open Orca Find") { open() }.buttonStyle(.plain).font(DS.bodySM).foregroundStyle(DS.link)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if downloads.isEmpty {
                Text(state.index.isReady ? "Nothing in Downloads yet" : "Getting ready…").font(DS.bodySM).foregroundStyle(DS.text2).frame(maxWidth: .infinity).padding(24)
            } else {
                VStack(spacing: 1) { ForEach(downloads) { MenuDownloadRow(item: $0) } }.padding(.horizontal, 6)
            }
            if let cur = state.player.current {
                Rectangle().fill(DS.border).frame(height: 1).padding(.top, 6)
                HStack(spacing: 10) {
                    Thumb(item: cur, size: 60).frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.player.title).font(DS.bodySM).foregroundStyle(DS.text).lineLimit(1)
                        Text("\(Fmt.duration(state.player.position)) / \(Fmt.duration(state.player.duration))").font(DS.caption).foregroundStyle(DS.text2)
                    }
                    Spacer()
                    Button { state.player.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain)
                    Button { state.player.toggle() } label: { Image(systemName: state.player.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
                    Button { state.player.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
                }
                .font(.system(size: 12)).foregroundStyle(DS.text)
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            Rectangle().fill(DS.border).frame(height: 1).padding(.top, 6)
            HStack(spacing: 10) {
                Button { QuickSearchController.shared.show() } label: {
                    HStack(spacing: 6) { Image(systemName: "magnifyingglass"); Text("Quick Search").font(DS.bodySM); Kbd(state.prefs.quickSearchHotKey.display) }
                }.buttonStyle(.plain)
                Spacer()
                Button { NSApp.activate(ignoringOtherApps: true); openSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
                Button { NSApp.terminate(nil) } label: { Text("Quit").font(DS.bodySM) }.buttonStyle(.plain)
            }
            .foregroundStyle(DS.text2)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 380)
        .onAppear { if state.openWindowAction == nil { state.openWindowAction = openWindow } }
    }

    private func open() {
        if state.openWindowAction == nil { state.openWindowAction = openWindow }
        state.openMainWindow()
    }
}

private struct MenuDownloadRow: View {
    let item: FileItem
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            Thumb(item: item, size: 60, mode: item.category == .images || item.category == .videos ? .fill : (item.category == .documents ? .page : .fit))
                .frame(width: 30, height: 30).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(DS.bodySM).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.size(item.size)) · \(Fmt.relative(item.added ?? item.activityDate))").font(DS.caption).foregroundStyle(DS.text2).lineLimit(1)
            }
            Spacer()
            if hovering {
                HStack(spacing: 4) { Image(systemName: "hand.draw"); Text("Drag into any app") }.font(DS.caption).foregroundStyle(DS.text2)
            } else if let s = item.source { Badge(s.name, tone: .info) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? DS.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { FileActions.open([item]) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu { Button("Show in Finder") { FileActions.revealInFinder([item]) } }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppState.self) private var state
    enum Pane: String, CaseIterable { case general = "General", library = "Library", voice = "Search & Voice", cleanup = "Clean Up", privacy = "Privacy" }
    @State private var pane: Pane = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases, id: \.self) { p in
                    Button { pane = p } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(p)).frame(width: 16)
                            Text(p.rawValue).font(DS.body)
                            Spacer()
                        }
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(pane == p ? DS.surface : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 200)
            .background(DS.nav)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch pane {
                    case .general: general
                    case .library: library
                    case .voice: voice
                    case .cleanup: cleanup
                    case .privacy: privacy
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)
            .background(DS.surface)
        }
        .frame(width: 860, height: 640)
    }

    private func icon(_ p: Pane) -> String {
        switch p {
        case .general: return "gearshape"
        case .library: return "folder"
        case .voice: return "mic"
        case .cleanup: return "sparkles"
        case .privacy: return "lock"
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PixelLabel(title)
            VStack(spacing: 0) { content() }.background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
        }
    }

    private func line<R: View>(_ label: String, last: Bool = false, @ViewBuilder _ right: () -> R) -> some View {
        VStack(spacing: 0) {
            HStack { Text(label).font(DS.body).foregroundStyle(DS.text); Spacer(); right() }.padding(.horizontal, 14).padding(.vertical, 10)
            if !last { Rectangle().fill(DS.border).frame(height: 1) }
        }
    }

    @ViewBuilder private var general: some View {
        @Bindable var p = state.prefs
        group("Look") {
            line("Appearance") {
                Picker("", selection: $p.appearance) { ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Background").font(DS.body).foregroundStyle(DS.text); Spacer(); Text("Applies to every screen · dark mode uses Night sea").font(DS.caption).foregroundStyle(DS.text2) }
                HStack(spacing: 10) {
                    ForEach(BackgroundStyle.allCases) { b in
                        Button { p.background = b } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    DS.app
                                    if let f = b.file, let img = Art.image(f) { Image(nsImage: img).resizable().scaledToFill() }
                                    else { if let t = Art.image("dotgrid-tile@2x.png") { Image(nsImage: t).resizable(resizingMode: .tile) }; if let a = Art.image("orca-dither@2x.png") { Image(nsImage: a).resizable().scaledToFit() } }
                                }
                                .frame(width: 96, height: 62).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.background == b ? DS.brand : DS.border, lineWidth: p.background == b ? 2 : 1))
                                Text(b.title).font(DS.caption).foregroundStyle(p.background == b ? DS.text : DS.text2)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        group("Quick Search & menu bar") {
            line("Quick Search shortcut") { ShortcutRecorder(combo: $p.quickSearchHotKey) }
            line("Show latest downloads in the menu bar") { Toggle("", isOn: $p.showMenuBar).toggleStyle(.switch).labelsHidden() }
            line("Open Orca Find at login", last: true) { Toggle("", isOn: Binding(get: { p.launchAtLogin }, set: { p.launchAtLogin = $0 })).toggleStyle(.switch).labelsHidden() }
        }
        group("Cards") {
            line("Card size", last: true) { Slider(value: $p.cardSize, in: 110...320).frame(width: 220) }
        }
    }

    @ViewBuilder private var library: some View {
        @Bindable var p = state.prefs
        group("Folders Orca Find looks in") {
            ForEach(FileScanner.defaultFolderNames(), id: \.self) { name in
                line(name) {
                    Toggle("", isOn: Binding(get: { !p.disabledDefaultFolders.contains(name) }, set: { on in
                        if on { p.disabledDefaultFolders.removeAll { $0 == name } } else { p.disabledDefaultFolders.append(name) }
                    })).toggleStyle(.switch).labelsHidden()
                }
            }
            ForEach(p.extraFolders, id: \.self) { path in
                line((path as NSString).abbreviatingWithTildeInPath) { Button("Remove") { p.extraFolders.removeAll { $0 == path } }.buttonStyle(.secondary) }
            }
            line("Applications", last: true) { Text("Always included").font(DS.bodySM).foregroundStyle(DS.text2) }
        }
        HStack {
            Button("Add Folder…") { addFolder() }.buttonStyle(.secondary)
            Button("Rescan Now") { state.index.rescan() }.buttonStyle(.secondary)
            Spacer()
            Text("\(Fmt.count(state.homeStats.totalCount)) files · cache \(Fmt.size(Database.shared.fileSize))").font(DS.caption).foregroundStyle(DS.text2)
        }
        group("Smart folders") {
            ForEach(BuiltinFolder.allCases) { b in
                line("Show “\(b.title)” in Library") {
                    Toggle("", isOn: Binding(get: { !state.hiddenBuiltins.contains(b.rawValue) },
                                             set: { on in if on { state.hiddenBuiltins.remove(b.rawValue) } else { state.hiddenBuiltins.insert(b.rawValue) } }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            line("Large files start at", last: true) { Stepper("\(p.largeFileMB) MB", value: $p.largeFileMB, in: 10...10_000, step: 50).font(DS.bodySM) }
        }
    }

    @ViewBuilder private var voice: some View {
        @Bindable var p = state.prefs
        let ai = SentenceUnderstanding.status
        group("Smart search") {
            line("Understand what's in photos and PDF covers") {
                Toggle("", isOn: $p.smartPictures).toggleStyle(.switch).labelsHidden()
                    .onChange(of: p.smartPictures) { _, on in if on { state.index.rescan() } }
            }
            if p.smartPictures && state.index.visualTotal > 0 && state.index.visualDone < state.index.visualTotal {
                line("Looking at photos · \(Fmt.count(state.index.visualDone)) of \(Fmt.count(state.index.visualTotal))") {
                    ProgressView(value: Double(state.index.visualDone), total: Double(max(1, state.index.visualTotal))).frame(width: 160).tint(DS.brand)
                }
            }
            line("Understand full sentences (Apple Intelligence)", last: true) {
                Badge(SentenceUnderstanding.statusText, tone: ai == .available ? .success : .neutral)
                Toggle("", isOn: $p.smartSentences).toggleStyle(.switch).labelsHidden().disabled(ai != .available)
            }
        }
        Text((ai == .available
             ? "Long sentences like “that tiger photo I downloaded a few days ago” are read by Apple Intelligence on this Mac."
             : "No Apple Intelligence? Dates, sizes, kinds and sources are still understood, and photos are still found by what's in them.")
             + (MobileCLIP.isBundled ? " Descriptions like “people around a whiteboard” are matched by Apple's MobileCLIP model, also on this Mac." : ""))
            .font(DS.caption).foregroundStyle(DS.text2)
        group("Search & voice") {
            line("Read text in screenshots, photos and scanned PDFs") { Toggle("", isOn: $p.ocrEnabled).toggleStyle(.switch).labelsHidden() }
            line("Voice search (⌥⌘F)") { Toggle("", isOn: $p.voiceEnabled).toggleStyle(.switch).labelsHidden() }
            line("Voice language") {
                Picker("", selection: $p.voiceLocale) {
                    ForEach(SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }, id: \.identifier) { l in
                        Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                    }
                }.labelsHidden().frame(width: 220)
            }
            line("Keep audio on this Mac (on-device only)", last: true) { Toggle("", isOn: $p.voiceOnDevice).toggleStyle(.switch).labelsHidden() }
        }
        HStack {
            Button("Read All Text Again") { Database.shared.resetText(); state.index.rescan() }.buttonStyle(.secondary)
            Button("Look at All Pictures Again") { Database.shared.resetVisual(); state.index.rescan() }.buttonStyle(.secondary)
        }
    }

    @ViewBuilder private var cleanup: some View {
        @Bindable var p = state.prefs
        group("Automatic clean up — off until you turn them on") {
            line("Move installers to the Trash after \(p.autoInstallerDays) days") { Toggle("", isOn: $p.autoTrashInstallers).toggleStyle(.switch).labelsHidden() }
            line("File screenshots into a folder per month", last: true) { Toggle("", isOn: $p.autoSortScreenshots).toggleStyle(.switch).labelsHidden() }
        }
        group("What counts as old") {
            line("Forgotten downloads") { Stepper("\(p.forgottenDays) days", value: $p.forgottenDays, in: 7...365, step: 7).font(DS.bodySM) }
            line("Old installers") { Stepper("\(p.installerDays) days", value: $p.installerDays, in: 1...180).font(DS.bodySM) }
            line("Old screenshots") { Stepper("\(p.screenshotDays) days", value: $p.screenshotDays, in: 7...365, step: 7).font(DS.bodySM) }
            line("Big videos over") { Stepper("\(p.videoMinMB) MB", value: $p.videoMinMB, in: 100...10_000, step: 100).font(DS.bodySM) }
            line("…untouched for") { Stepper("\(p.videoDays) days", value: $p.videoDays, in: 30...1_000, step: 30).font(DS.bodySM) }
            line("Unused apps", last: true) { Stepper("\(p.appDays) days", value: $p.appDays, in: 30...730, step: 15).font(DS.bodySM) }
        }
        if !p.autoLog.isEmpty {
            group("Recent automatic actions") {
                ForEach(Array(p.autoLog.prefix(6).enumerated()), id: \.element.id) { i, e in
                    line(e.message, last: i == min(5, p.autoLog.count - 1)) { Text(Fmt.relative(e.date)).font(DS.caption).foregroundStyle(DS.text2) }
                }
            }
        }
    }

    @ViewBuilder private var privacy: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield").foregroundStyle(DS.Tone.success.fg)
            Text("Your files never leave this Mac. Reading text, looking at pictures, understanding sentences (Apple Intelligence), duplicate checks and voice all run locally; Orca Find doesn't send anything anywhere.")
                .font(DS.body).foregroundStyle(DS.Tone.success.fg)
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(DS.Tone.success.bg))
        group("Permissions") {
            line("Desktop, Documents & Downloads") { Button("Open System Settings") { Onboarding.openFilesPrivacy() }.buttonStyle(.secondary) }
            line("Microphone & Speech Recognition", last: true) { Button("Open System Settings") { Onboarding.openMicPrivacy() }.buttonStyle(.secondary) }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let p = state.prefs
        for url in panel.urls where !p.extraFolders.contains(url.path) { p.extraFolders.append(url.path) }
        state.index.rescan()
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: HotKeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Kbd(recording ? "Type a shortcut…" : combo.display)
            Button(recording ? "Cancel" : "Record new") { recording ? stop() : start() }.buttonStyle(.secondary)
            if combo != .defaultQuickSearch && !recording { Button("Reset") { combo = .defaultQuickSearch }.buttonStyle(.plainP) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53 { stop(); return nil }
            guard !mods.isEmpty, mods != [.shift] else { NSSound.beep(); return nil }
            combo = HotKeyCombo(keyCode: UInt32(e.keyCode), modifiers: mods.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeyCenter.shared.resume() }
        recording = false
    }
}

// MARK: - First run

enum Onboarding {
    static func canRead(_ name: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/" + name)) != nil
    }
    static func openFilesPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }
    static func openMicPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var access: [String: Bool] = [:]
    private let folders = [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc.text"), ("Downloads", "arrow.down.circle")]

    var body: some View {
        ZStack {
            AppBackground(style: .orca, showArt: false)
            if let art = Art.image("orca-dither@2x.png") {
                VStack { Spacer(); Image(nsImage: art).resizable().scaledToFit().opacity(0.8) }.ignoresSafeArea()
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("Welcome to Orca Find").font(DS.display).foregroundStyle(DS.text)
                Text("Your files as big, clear cards — and a search that understands plain English, or your voice. First, let it see your folders.")
                    .font(DS.body).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(folders.enumerated()), id: \.offset) { i, f in
                        HStack(spacing: 12) {
                            Image(systemName: f.1).frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 8).fill(DS.surface)).foregroundStyle(DS.text)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.0).font(DS.body).foregroundStyle(DS.text)
                                Text(access[f.0] == true ? "Allowed" : "Needed to show and search these files").font(DS.caption).foregroundStyle(DS.text2)
                            }
                            Spacer()
                            if access[f.0] == true { Badge("Allowed ✓", tone: .success) }
                            else { Button("Allow access") { request(f.0) }.buttonStyle(.primary) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        if i < folders.count - 1 { Rectangle().fill(DS.border).frame(height: 1) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(DS.surface2))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(state.index.isScanning ? "Getting to know your files…" : state.index.isReady ? "Found \(Fmt.count(state.homeStats.totalCount)) files" : "Starting…").font(DS.body).foregroundStyle(DS.text)
                        Spacer()
                        if state.index.isScanning { Text("\(Fmt.count(state.index.scannedCount)) so far").font(DS.bodySM).foregroundStyle(DS.text2) }
                    }
                    ProgressView(value: state.index.isReady ? (state.index.textTotal == 0 ? 1 : Double(state.index.textDone) / Double(max(1, state.index.textTotal))) : 0.15)
                        .tint(DS.brand)
                    if state.index.textTotal > 0 && state.index.textDone < state.index.textTotal {
                        Text("Reading text in images · \(Fmt.count(state.index.textDone)) of \(Fmt.count(state.index.textTotal)) — you can start searching now")
                            .font(DS.caption).foregroundStyle(DS.text2)
                    }
                    if state.index.visualTotal > 0 && state.index.visualDone < state.index.visualTotal {
                        Text("Looking at photos · \(Fmt.count(state.index.visualDone)) of \(Fmt.count(state.index.visualTotal)) — picture matches fill in as it goes")
                            .font(DS.caption).foregroundStyle(DS.text2)
                    }
                }
                HStack {
                    Badge("Nothing leaves this Mac", tone: .success)
                    Spacer()
                    Button("Start searching") { state.prefs.onboarded = true; state.focusSearch() }.buttonStyle(.primary)
                }
            }
            .padding(34)
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.surface))
            .shadow(color: .black.opacity(0.16), radius: 30, y: 16)
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func refresh() {
        let names = folders.map(\.0)
        Task.detached {
            var out: [String: Bool] = [:]
            for n in names { out[n] = Onboarding.canRead(n) }
            await MainActor.run { access = out }
        }
    }

    private func request(_ name: String) {
        Task.detached {
            let ok = Onboarding.canRead(name)   // the first read triggers the macOS prompt
            await MainActor.run {
                if !ok { Onboarding.openFilesPrivacy() }
                refresh()
                if ok { state.index.rescan() }
            }
        }
    }
}
