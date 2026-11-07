import SwiftUI

enum CleanupKind: String, CaseIterable, Identifiable, Hashable {
    case forgottenDownloads, oldInstallers, duplicates, bigOldVideos, oldScreenshots, unusedApps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forgottenDownloads: return "Forgotten Downloads"
        case .oldInstallers: return "Old Installers"
        case .duplicates: return "Duplicates & Look-alikes"
        case .bigOldVideos: return "Big Old Videos"
        case .oldScreenshots: return "Old Screenshots"
        case .unusedApps: return "Unused Apps"
        }
    }

    @MainActor
    var detail: String {
        let p = Preferences.shared
        switch self {
        case .forgottenDownloads: return "In Downloads and not opened for \(p.forgottenDays) days."
        case .oldInstallers: return ".dmg and .pkg installers older than \(p.installerDays) days. The app is already installed."
        case .duplicates: return "Identical copies and near-identical photos: bursts, edits, HEIC + JPEG pairs."
        case .bigOldVideos: return "Videos over \(p.videoMinMB) MB you haven't touched in \(p.videoDays) days."
        case .oldScreenshots: return "Screenshots older than \(p.screenshotDays) days."
        case .unusedApps: return "Apps you haven't opened in \(p.appDays) days."
        }
    }

    var symbol: String {
        switch self {
        case .forgottenDownloads: return "tray.and.arrow.down"
        case .oldInstallers: return "shippingbox"
        case .duplicates: return "square.on.square"
        case .bigOldVideos: return "film"
        case .oldScreenshots: return "camera.viewfinder"
        case .unusedApps: return "moon.zzz"
        }
    }

    var color: UInt32 {
        switch self {
        case .forgottenDownloads: return 0x3BA4FF
        case .oldInstallers: return 0xFFB020
        case .duplicates: return 0x7C5CFF
        case .bigOldVideos: return 0xFF5C9A
        case .oldScreenshots: return 0xFF7A59
        case .unusedApps: return 0x22B573
        }
    }
}

struct CleanupCandidate: Identifiable, Hashable {
    var item: FileItem
    var note: String
    var id: String { item.id }
}

@MainActor
@Observable
final class TidyModel {
    static let shared = TidyModel()

    var results: [CleanupKind: [CleanupCandidate]] = [:]
    var isScanning = false
    var lastScan: Date?

    func total(_ kind: CleanupKind) -> Int64 {
        if kind == .duplicates { return DuplicatesModel.shared.totalReclaimable }
        return (results[kind] ?? []).reduce(0) { $0 + $1.item.size }
    }

    func count(_ kind: CleanupKind) -> Int {
        if kind == .duplicates { return DuplicatesModel.shared.duplicateFileCount }
        return results[kind]?.count ?? 0
    }

    var grandTotal: Int64 { CleanupKind.allCases.reduce(0) { $0 + total($1) } }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let items = FileIndex.shared.items
        let p = Preferences.shared
        let cfg = (forgotten: p.forgottenDays, installers: p.installerDays, shots: p.screenshotDays,
                   videoDays: p.videoDays, videoMB: p.videoMinMB, apps: p.appDays)
        Task.detached(priority: .userInitiated) {
            let now = Date()
            func ago(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
            var out: [CleanupKind: [CleanupCandidate]] = [:]
            let local = items.filter { !$0.isCloudOnly && !$0.isFolder }

            // Forgotten downloads
            out[.forgottenDownloads] = local.compactMap { item in
                guard item.rootName == "Downloads", !item.isInstaller else { return nil }
                let arrived = item.added ?? item.activityDate
                guard arrived < ago(cfg.forgotten) else { return nil }
                let used = MetadataReader.lastUsedDate(item.url)
                let last = max(used ?? .distantPast, arrived)
                guard last < ago(cfg.forgotten) else { return nil }
                let note = used.map { "Last opened \(Fmt.relative($0))" } ?? "Downloaded \(Fmt.relative(arrived)) · never opened"
                return CleanupCandidate(item: item, note: note)
            }

            let appNames = Set(items.filter { $0.category == .apps }.map { $0.baseName.lowercased() })
            func installedApp(for installer: FileItem) -> String? {
                var base = installer.baseName.lowercased()
                for p in ["install ", "installer ", "setup "] where base.hasPrefix(p) { base = String(base.dropFirst(p.count)) }
                let token = base.split(whereSeparator: { "-_ .".contains($0) || $0.isNumber }).first.map(String.init) ?? base
                guard token.count >= 2 else { return nil }
                return appNames.first { $0 == token || $0.hasPrefix(token) || token.hasPrefix($0) }
            }
            out[.oldInstallers] = local.compactMap { item in
                guard item.isInstaller else { return nil }
                let arrived = item.added ?? item.activityDate
                guard arrived < ago(cfg.installers) else { return nil }
                if let app = installedApp(for: item) { return CleanupCandidate(item: item, note: "\(app.capitalized) is installed ✓") }
                return CleanupCandidate(item: item, note: "Not installed · added \(Fmt.relative(arrived))")
            }

            out[.oldScreenshots] = local.compactMap { item in
                guard item.isScreenshot, item.activityDate < ago(cfg.shots) else { return nil }
                return CleanupCandidate(item: item, note: "Taken \(Fmt.relative(item.created ?? item.activityDate))")
            }

            out[.bigOldVideos] = local.compactMap { item in
                guard item.category == .videos, item.size >= Int64(cfg.videoMB) * 1_000_000 else { return nil }
                let used = MetadataReader.lastUsedDate(item.url)
                let last = max(used ?? .distantPast, item.activityDate)
                guard last < ago(cfg.videoDays) else { return nil }
                return CleanupCandidate(item: item, note: "Last touched \(Fmt.relative(last))")
            }

            let selfID = Bundle.main.bundleIdentifier ?? ""
            out[.unusedApps] = local.compactMap { item in
                guard item.category == .apps, item.rootName == "Applications" else { return nil }
                let bid = Bundle(url: item.url)?.bundleIdentifier ?? ""
                guard !bid.hasPrefix("com.apple."), bid != selfID else { return nil }
                let used = MetadataReader.lastUsedDate(item.url)
                let last = used ?? item.added ?? item.created ?? item.activityDate
                guard last < ago(cfg.apps) else { return nil }
                let note = used.map { "Last opened \(Fmt.relative($0))" } ?? "Never opened since it was installed"
                return CleanupCandidate(item: item, note: note)
            }

            for k in out.keys { out[k]?.sort { $0.item.size > $1.item.size } }
            let final = out
            await MainActor.run {
                let m = TidyModel.shared
                m.results = final
                m.isScanning = false
                m.lastScan = Date()
            }
        }
    }

    func remove(paths: Set<String>) {
        for k in results.keys { results[k]?.removeAll { paths.contains($0.id) } }
    }
}
