import SwiftUI

enum CleanupKind: String, CaseIterable, Identifiable, Hashable {
    case forgottenDownloads, oldInstallers, duplicates, lookAlikes, bigOldVideos, oldScreenshots, unusedApps, mailAttachments, appLeftovers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forgottenDownloads: return "Forgotten Downloads"
        case .oldInstallers: return "Old Installers"
        case .duplicates: return "Exact Duplicates"
        case .lookAlikes: return "Look-alike Photos"
        case .bigOldVideos: return "Big Old Videos"
        case .oldScreenshots: return "Old Screenshots"
        case .unusedApps: return "Unused Apps"
        case .mailAttachments: return "Mail Attachments"
        case .appLeftovers: return "Leftovers from Deleted Apps"
        }
    }

    /// Safe to clear: Orca is sure these are spare, so they come ticked. Everything else is your call.
    var isSafe: Bool { [.oldInstallers, .duplicates, .mailAttachments].contains(self) }

    @MainActor
    var detail: String {
        let p = Preferences.shared
        switch self {
        case .forgottenDownloads: return "In Downloads and not opened for \(p.forgottenDays) days."
        case .oldInstallers: return ".dmg and .pkg installers older than \(p.installerDays) days, for apps you already have."
        case .duplicates: return "Byte-for-byte copies of the same file. One copy is always kept."
        case .lookAlikes: return "Near-identical photos: bursts, edits, HEIC + JPEG pairs."
        case .mailAttachments: return "Copies Mail saved when you opened an attachment. The emails keep theirs."
        case .appLeftovers: return "Settings and caches left behind by apps that are no longer on this Mac."
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
        case .lookAlikes: return "photo.stack"
        case .bigOldVideos: return "film"
        case .oldScreenshots: return "camera.viewfinder"
        case .unusedApps: return "moon.zzz"
        case .mailAttachments: return "paperclip"
        case .appLeftovers: return "puzzlepiece.extension"
        }
    }

    var color: UInt32 {
        switch self {
        case .forgottenDownloads: return 0x3BA4FF
        case .oldInstallers: return 0xFFB020
        case .duplicates: return 0x7C5CFF
        case .lookAlikes: return 0xB18CFF
        case .bigOldVideos: return 0xFF5C9A
        case .oldScreenshots: return 0xFF7A59
        case .unusedApps: return 0x22B573
        case .mailAttachments: return 0x2FB8C6
        case .appLeftovers: return 0x9A8C7A
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
    /// Checks still running; each card fills in as soon as its own check is done.
    var pending: Set<CleanupKind> = []
    /// Mail's folder couldn't be read (needs Full Disk Access).
    var mailNeedsAccess = false

    func isChecking(_ kind: CleanupKind) -> Bool {
        if kind == .duplicates || kind == .lookAlikes { return DuplicatesModel.shared.isScanning }
        return pending.contains(kind)
    }

    func total(_ kind: CleanupKind) -> Int64 {
        if kind == .duplicates { return DuplicatesModel.shared.reclaimable(.identical) }
        if kind == .lookAlikes { return DuplicatesModel.shared.reclaimable(.lookAlike) }
        return (results[kind] ?? []).reduce(0) { $0 + $1.item.size }
    }

    func count(_ kind: CleanupKind) -> Int {
        if kind == .duplicates { return DuplicatesModel.shared.extraCount(.identical) }
        if kind == .lookAlikes { return DuplicatesModel.shared.extraCount(.lookAlike) }
        return results[kind]?.count ?? 0
    }

    /// What comes ticked on a review screen: everything in a Safe to clear card (for installers, only the
    /// ones whose app is installed), nothing in a Your call card.
    func preticked(_ kind: CleanupKind) -> Set<String> {
        guard kind.isSafe else { return [] }
        let list = results[kind] ?? []
        if kind == .oldInstallers { return Set(list.filter { $0.note.hasSuffix("is installed ✓") }.map(\.id)) }
        return Set(list.map(\.id))
    }

    var grandTotal: Int64 { CleanupKind.allCases.reduce(0) { $0 + total($1) } }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        pending = Set(CleanupKind.allCases).subtracting([.duplicates, .lookAlikes])
        let items = FileIndex.shared.tidyItems
        let p = Preferences.shared
        let cfg = (forgotten: p.forgottenDays, installers: p.installerDays, shots: p.screenshotDays,
                   videoDays: p.videoDays, videoMB: p.videoMinMB, apps: p.appDays)
        Task.detached(priority: .userInitiated) {
            let now = Date()
            func ago(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
            var out: [CleanupKind: [CleanupCandidate]] = [:]
            let local = items.filter { !$0.isCloudOnly && !$0.isFolder }
            /// Shows one card's results straight away.
            func publish(_ k: CleanupKind, _ list: [CleanupCandidate]) async {
                let sorted = list.sorted { $0.item.size > $1.item.size }
                await MainActor.run {
                    TidyModel.shared.results[k] = sorted
                    TidyModel.shared.pending.remove(k)
                }
            }

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
            await publish(.forgottenDownloads, out[.forgottenDownloads] ?? [])

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
            await publish(.oldInstallers, out[.oldInstallers] ?? [])

            out[.oldScreenshots] = local.compactMap { item in
                guard item.isScreenshot, item.activityDate < ago(cfg.shots) else { return nil }
                return CleanupCandidate(item: item, note: "Taken \(Fmt.relative(item.created ?? item.activityDate))")
            }
            await publish(.oldScreenshots, out[.oldScreenshots] ?? [])

            out[.bigOldVideos] = local.compactMap { item in
                guard item.category == .videos, item.size >= Int64(cfg.videoMB) * 1_000_000 else { return nil }
                let used = MetadataReader.lastUsedDate(item.url)
                let last = max(used ?? .distantPast, item.activityDate)
                guard last < ago(cfg.videoDays) else { return nil }
                return CleanupCandidate(item: item, note: "Last touched \(Fmt.relative(last))")
            }
            await publish(.bigOldVideos, out[.bigOldVideos] ?? [])

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

            await publish(.unusedApps, out[.unusedApps] ?? [])

            let mail = LibraryCleanup.mailAttachments()
            await MainActor.run { TidyModel.shared.mailNeedsAccess = mail == nil }
            await publish(.mailAttachments, mail ?? [])
            await publish(.appLeftovers, LibraryCleanup.appLeftovers())

            await MainActor.run {
                let m = TidyModel.shared
                m.pending = []
                m.isScanning = false
                m.lastScan = Date()
            }
        }
    }

    func remove(paths: Set<String>) {
        for k in results.keys { results[k]?.removeAll { paths.contains($0.id) } }
    }
}
