import Foundation

/// Optional rules (off until you turn them on): move old installers to the Trash, and file
/// screenshots into one folder per month. Runs at launch and then every hour.
@MainActor
final class AutoCleanup {
    static let shared = AutoCleanup()
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AutoCleanup.shared.run() }
        }
        if FileIndex.shared.isReady { run() } else { FileIndex.shared.onReady.append { AutoCleanup.shared.run() } }
    }

    static var screenshotFolder: URL {
        let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        if let raw, !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    static func monthFolderName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM MMMM"
        return f.string(from: date)
    }

    func run() {
        let prefs = Preferences.shared
        let index = FileIndex.shared
        guard index.isReady else { return }
        let now = Date()

        if prefs.autoTrashInstallers {
            let cutoff = now.addingTimeInterval(-Double(prefs.autoInstallerDays) * 86_400)
            let targets = index.items.filter {
                $0.isInstaller && !$0.isCloudOnly && ["Downloads", "Desktop"].contains($0.rootName)
                    && ($0.added ?? $0.activityDate) < cutoff
            }
            if !targets.isEmpty {
                let r = Trash.move(targets)
                if r.count > 0 {
                    prefs.log("Moved \(Fmt.plural(r.count, "old installer")) to the Trash (\(Fmt.size(r.bytes))).")
                }
            }
        }

        if prefs.autoSortScreenshots {
            let folder = AutoCleanup.screenshotFolder.standardizedFileURL
            let cutoff = now.addingTimeInterval(-86_400)
            let targets = index.items.filter {
                $0.isScreenshot && !$0.isCloudOnly
                    && $0.url.deletingLastPathComponent().standardizedFileURL.path == folder.path
                    && ($0.created ?? $0.activityDate) < cutoff
            }
            var moved = 0
            let fm = FileManager.default
            for item in targets {
                let month = AutoCleanup.monthFolderName(for: item.created ?? item.activityDate)
                let dest = folder.appendingPathComponent("Screenshots", isDirectory: true).appendingPathComponent(month, isDirectory: true)
                do {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    var target = dest.appendingPathComponent(item.name)
                    var n = 2
                    while fm.fileExists(atPath: target.path) {
                        target = dest.appendingPathComponent("\(item.baseName) \(n).\(item.ext)")
                        n += 1
                    }
                    try fm.moveItem(at: item.url, to: target)
                    moved += 1
                } catch {
                    NSLog("OrcaFind: could not file screenshot \(item.path): \(error)")
                }
            }
            if moved > 0 {
                prefs.log("Filed \(Fmt.plural(moved, "screenshot")) into monthly folders.")
            }
        }
    }
}
