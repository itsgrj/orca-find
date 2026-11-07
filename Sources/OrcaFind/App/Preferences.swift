import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

enum Look: String, CaseIterable, Identifiable, Codable {
    case tide, orca
    var id: String { rawValue }
    var title: String { self == .tide ? "Tide" : "Orca" }
    var subtitle: String { self == .tide ? "Colourful, ocean-toned" : "Black, white and grey" }
    var next: Look { self == .tide ? .orca : .tide }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ViewMode: String, Codable { case grid, list }

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt

    static let defaultQuickSearch = HotKeyCombo(keyCode: UInt32(kVK_Space),
                                                modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + HotKeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`"
        ]
        return names[Int(code)] ?? "Key \(code)"
    }
}

struct AutoLogEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var message: String
}

@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()
    @ObservationIgnored private let d = UserDefaults.standard

    var look: Look { didSet { d.set(look.rawValue, forKey: "look") } }
    var background: BackgroundStyle { didSet { d.set(background.rawValue, forKey: "background") } }
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    var appearance: AppearanceMode {
        didSet { d.set(appearance.rawValue, forKey: "appearance"); NSApp?.appearance = appearance.nsAppearance }
    }
    var showMenuBar: Bool { didSet { d.set(showMenuBar, forKey: "showMenuBar") } }
    var quickSearchHotKey: HotKeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(quickSearchHotKey) { d.set(data, forKey: "quickSearchHotKey") }
            HotKeyCenter.shared.register(quickSearchHotKey)
        }
    }
    var cardSize: Double { didSet { d.set(cardSize, forKey: "cardSize") } }
    var viewMode: ViewMode { didSet { d.set(viewMode.rawValue, forKey: "viewMode") } }
    var ocrEnabled: Bool { didSet { d.set(ocrEnabled, forKey: "ocrEnabled") } }
    /// Look at photos and PDF covers while indexing (labels + main colours), for "Looks like" search.
    var smartPictures: Bool { didSet { d.set(smartPictures, forKey: "smartPictures") } }
    /// Use Apple Intelligence (on-device) to understand long, chatty queries.
    var smartSentences: Bool { didSet { d.set(smartSentences, forKey: "smartSentences") } }
    var extraFolders: [String] { didSet { d.set(extraFolders, forKey: "extraFolders") } }
    var disabledDefaultFolders: [String] { didSet { d.set(disabledDefaultFolders, forKey: "disabledDefaultFolders") } }
    var largeFileMB: Int { didSet { d.set(largeFileMB, forKey: "largeFileMB") } }

    // Voice
    var voiceEnabled: Bool { didSet { d.set(voiceEnabled, forKey: "voiceEnabled") } }
    var voiceLocale: String { didSet { d.set(voiceLocale, forKey: "voiceLocale") } }
    var voiceOnDevice: Bool { didSet { d.set(voiceOnDevice, forKey: "voiceOnDevice") } }
    var voiceAutoSearch: Bool { didSet { d.set(voiceAutoSearch, forKey: "voiceAutoSearch") } }

    // Clean Up thresholds
    var forgottenDays: Int { didSet { d.set(forgottenDays, forKey: "forgottenDays") } }
    var installerDays: Int { didSet { d.set(installerDays, forKey: "installerDays") } }
    var screenshotDays: Int { didSet { d.set(screenshotDays, forKey: "screenshotDays") } }
    var videoDays: Int { didSet { d.set(videoDays, forKey: "videoDays") } }
    var videoMinMB: Int { didSet { d.set(videoMinMB, forKey: "videoMinMB") } }
    var appDays: Int { didSet { d.set(appDays, forKey: "appDays") } }
    var lookAlikeThreshold: Double { didSet { d.set(lookAlikeThreshold, forKey: "lookAlikeThreshold") } }

    // Automatic clean up (off by default)
    var autoTrashInstallers: Bool { didSet { d.set(autoTrashInstallers, forKey: "autoTrashInstallers") } }
    var autoInstallerDays: Int { didSet { d.set(autoInstallerDays, forKey: "autoInstallerDays") } }
    var autoSortScreenshots: Bool { didSet { d.set(autoSortScreenshots, forKey: "autoSortScreenshots") } }
    var autoLog: [AutoLogEntry] {
        didSet { if let data = try? JSONEncoder().encode(autoLog) { d.set(data, forKey: "autoLog") } }
    }

    var launchAtLogin: Bool {
        get { _ = loginToken; return SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("OrcaFind: launch at login change failed: \(error)")
            }
            loginToken += 1
        }
    }
    private var loginToken = 0

    init() {
        look = Look(rawValue: d.string(forKey: "look") ?? "") ?? .tide
        background = BackgroundStyle(rawValue: d.string(forKey: "background") ?? "") ?? .orca
        onboarded = d.bool(forKey: "onboarded")
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        showMenuBar = d.object(forKey: "showMenuBar") as? Bool ?? true
        if let data = d.data(forKey: "quickSearchHotKey"), let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data) {
            quickSearchHotKey = combo
        } else {
            quickSearchHotKey = .defaultQuickSearch
        }
        cardSize = d.object(forKey: "cardSize") as? Double ?? 168
        viewMode = ViewMode(rawValue: d.string(forKey: "viewMode") ?? "") ?? .grid
        ocrEnabled = d.object(forKey: "ocrEnabled") as? Bool ?? true
        smartPictures = d.object(forKey: "smartPictures") as? Bool ?? true
        smartSentences = d.object(forKey: "smartSentences") as? Bool ?? true
        extraFolders = d.stringArray(forKey: "extraFolders") ?? []
        disabledDefaultFolders = d.stringArray(forKey: "disabledDefaultFolders") ?? []
        largeFileMB = d.object(forKey: "largeFileMB") as? Int ?? 100
        voiceEnabled = d.object(forKey: "voiceEnabled") as? Bool ?? true
        voiceLocale = d.string(forKey: "voiceLocale") ?? Locale.current.identifier
        voiceOnDevice = d.object(forKey: "voiceOnDevice") as? Bool ?? true
        voiceAutoSearch = d.object(forKey: "voiceAutoSearch") as? Bool ?? true
        forgottenDays = d.object(forKey: "forgottenDays") as? Int ?? 30
        installerDays = d.object(forKey: "installerDays") as? Int ?? 7
        screenshotDays = d.object(forKey: "screenshotDays") as? Int ?? 30
        videoDays = d.object(forKey: "videoDays") as? Int ?? 180
        videoMinMB = d.object(forKey: "videoMinMB") as? Int ?? 500
        appDays = d.object(forKey: "appDays") as? Int ?? 90
        lookAlikeThreshold = d.object(forKey: "lookAlikeThreshold") as? Double ?? 0.35
        autoTrashInstallers = d.object(forKey: "autoTrashInstallers") as? Bool ?? false
        autoInstallerDays = d.object(forKey: "autoInstallerDays") as? Int ?? 7
        autoSortScreenshots = d.object(forKey: "autoSortScreenshots") as? Bool ?? false
        if let data = d.data(forKey: "autoLog"), let log = try? JSONDecoder().decode([AutoLogEntry].self, from: data) {
            autoLog = log
        } else {
            autoLog = []
        }
    }

    func log(_ message: String) {
        autoLog.insert(AutoLogEntry(date: Date(), message: message), at: 0)
        if autoLog.count > 40 { autoLog = Array(autoLog.prefix(40)) }
    }

    func toggleDark() {
        let isDark = (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        appearance = isDark ? .light : .dark
    }

    /// Safe to read from background threads.
    nonisolated static var smartPicturesValue: Bool {
        UserDefaults.standard.object(forKey: "smartPictures") as? Bool ?? true
    }

    nonisolated static var ocrEnabledValue: Bool {
        UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true
    }
}
