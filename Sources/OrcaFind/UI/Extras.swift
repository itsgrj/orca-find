import SwiftUI
import Speech

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppState.self) private var state
    enum Pane: String, CaseIterable { case general = "General", menuBar = "Menu Bar", captures = "Captures", library = "Library", voice = "Search & Voice", privateAI = "Private AI", cleanup = "Clean Up", privacy = "Privacy" }
    @State private var pane: Pane
    init(pane: Pane = .general) { _pane = State(initialValue: pane) }

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
                    case .menuBar: menuBar
                    case .captures: CapturesSettings()
                    case .library: library
                    case .voice: voice
                    case .privateAI: PrivateAISettings()
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
        case .menuBar: return "menubar.rectangle"
        case .captures: return "viewfinder"
        case .library: return "folder"
        case .voice: return "mic"
        case .privateAI: return "sparkles"
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
                                    else if let t = Art.image("dotgrid-tile@2x.png") { Image(nsImage: t).resizable(resizingMode: .tile) }
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
        group("Quick Search") {
            line("Quick Search shortcut") { ShortcutRecorder(combo: $p.quickSearchHotKey) }
            line("Open OrcaFind at login", last: true) { Toggle("", isOn: Binding(get: { p.launchAtLogin }, set: { p.launchAtLogin = $0 })).toggleStyle(.switch).labelsHidden() }
        }
        group("Cards") {
            line("Card size", last: true) { Slider(value: $p.cardSize, in: 110...320).frame(width: 220) }
        }
        UpdatesSettings()
    }

    @ViewBuilder private var menuBar: some View {
        @Bindable var p = state.prefs
        group("Menu bar") {
            line("Show OrcaFind in the menu bar", last: true) { Toggle("", isOn: $p.showMenuBar).toggleStyle(.switch).labelsHidden() }
        }
        Text(p.showMenuBar ? "Click the orca for your latest downloads. Drag a file onto it to put it away."
             : "The orca is hidden. Quick Search (\(p.quickSearchHotKey.display)) still works from anywhere.")
            .font(DS.caption).foregroundStyle(DS.text2)
        group("In the dropdown") {
            line("Search box") { Toggle("", isOn: $p.menuShowSearch).toggleStyle(.switch).labelsHidden() }
            line("Tabs for each kind of download") { Toggle("", isOn: $p.menuShowTabs).toggleStyle(.switch).labelsHidden() }
            line("Capture button") {
                Toggle("", isOn: $p.menuShowCapture).toggleStyle(.switch).labelsHidden().disabled(!p.capturesEnabled)
            }
            line("Downloads shown before scrolling", last: true) {
                Picker("", selection: $p.menuDownloadCount) {
                    ForEach([5, 8, 10, 12, 15], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 90)
            }
        }
        .disabled(!p.showMenuBar).opacity(p.showMenuBar ? 1 : 0.5)
        Text(p.capturesEnabled ? "The dropdown opens on your newest downloads. Scroll down for older ones from the past month."
             : "Captures are turned off in Settings › Captures, so the Capture button stays hidden.")
            .font(DS.caption).foregroundStyle(DS.text2)
        group("Drop Shelf") {
            line("Drop Shelf") { Toggle("", isOn: $p.shelfEnabled).toggleStyle(.switch).labelsHidden() }
            line("Open it when you start dragging a file") { Toggle("", isOn: $p.shelfOnDrag).toggleStyle(.switch).labelsHidden().disabled(!p.shelfEnabled) }
            line("Open it when the pointer rests on the notch") { Toggle("", isOn: $p.shelfOnNotch).toggleStyle(.switch).labelsHidden().disabled(!p.shelfEnabled) }
            line("Shortcut", last: true) { ShortcutRecorder(combo: $p.shelfHotKey, defaultCombo: .defaultShelf).disabled(!p.shelfEnabled) }
        }
        Text("A place to park files while you move them between apps. Drop on a pinned folder to file it there, or leave it in Holding and drag it out later.")
            .font(DS.caption).foregroundStyle(DS.text2)
    }

    @ViewBuilder private var library: some View {
        @Bindable var p = state.prefs
        group("Folders OrcaFind looks in") {
            ForEach(FileScanner.defaultFolderNames(), id: \.self) { name in
                line(name) {
                    Toggle("", isOn: Binding(get: { !p.disabledDefaultFolders.contains(name) }, set: { on in
                        if on { p.disabledDefaultFolders.removeAll { $0 == name } } else { p.disabledDefaultFolders.append(name) }
                        state.index.rescan()
                    })).toggleStyle(.switch).labelsHidden()
                }
            }
            line("Everything else in your home folder") {
                Toggle("", isOn: Binding(get: { !p.disabledDefaultFolders.contains(FileScanner.homeSettingName) }, set: { on in
                    if on { p.disabledDefaultFolders.removeAll { $0 == FileScanner.homeSettingName } }
                    else { p.disabledDefaultFolders.append(FileScanner.homeSettingName) }
                    state.index.rescan()
                })).toggleStyle(.switch).labelsHidden()
            }
            ForEach(p.extraFolders, id: \.self) { path in
                line((path as NSString).abbreviatingWithTildeInPath) { Button("Remove") { p.extraFolders.removeAll { $0 == path } }.buttonStyle(.secondary) }
            }
            line("Applications", last: true) { Text("Always included").font(DS.bodySM).foregroundStyle(DS.text2) }
        }
        Text(homeFolderNote).font(DS.caption).foregroundStyle(DS.text2)
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
        VoiceNotesSettings()
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
            Text("Your files never leave this Mac. Reading text, looking at pictures, understanding sentences (Apple Intelligence), duplicate checks and voice all run locally; OrcaFind doesn't send anything anywhere.")
                .font(DS.body).foregroundStyle(DS.Tone.success.fg)
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(DS.Tone.success.bg))
        group("Permissions") {
            line("Desktop, Documents & Downloads") { Button("Open System Settings") { Onboarding.openFilesPrivacy() }.buttonStyle(.secondary) }
            line("Microphone & Speech Recognition", last: true) { Button("Open System Settings") { Onboarding.openMicPrivacy() }.buttonStyle(.secondary) }
        }
    }

    /// "Your own folders, like Claude and SigmaFlow, are searched too. Orca never suggests cleaning them up…"
    private var homeFolderNote: String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let names = FileScanner.homeRoots(home: home, skipping: Set(FileScanner.defaultFolderNames()))
            .filter { $0.maxDepth > 1 }.map(\.name)
        let like: String
        switch names.count {
        case 0: like = "Folders you keep in your home folder"
        case 1: like = "Your own folders, like \(names[0]),"
        default: like = "Your own folders, like \(names.prefix(2).joined(separator: " and ")),"
        }
        return "\(like) are searched too. Orca never suggests cleaning them up, and it skips the hidden Library folder, where apps keep their own data."
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
    var defaultCombo: HotKeyCombo = .defaultQuickSearch
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Kbd(recording ? "Type a shortcut…" : combo.display)
            Button(recording ? "Cancel" : "Record new") { recording ? stop() : start() }.buttonStyle(.secondary)
            if combo != defaultCombo && !recording { Button("Reset") { combo = defaultCombo }.buttonStyle(.plainP) }
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
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    static func openMicPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
