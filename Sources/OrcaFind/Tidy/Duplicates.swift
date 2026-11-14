import Foundation
import CryptoKit
import Vision

struct DuplicateGroup: Identifiable, Hashable {
    enum Kind: String { case identical, lookAlike }
    let id: String
    let kind: Kind
    var items: [FileItem]
    var keepID: String
    var included = true

    var reclaimable: Int64 { items.filter { $0.id != keepID }.reduce(0) { $0 + $1.size } }
    var extras: [FileItem] { items.filter { $0.id != keepID } }
}

/// Finds identical files by content (SHA-256) and look-alike photos with Vision feature prints.
/// Files that live only in iCloud are skipped, so nothing gets downloaded behind your back.
enum DuplicateFinder {
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { (try? h.read(upToCount: 1 << 20)) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Cheap pre-filter: hash of the first and last 16 KB.
    static func edgeHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        if let head = try? h.read(upToCount: 16_384) { hasher.update(data: head) }
        if size > 32_768 {
            try? h.seek(toOffset: UInt64(size - 16_384))
            if let tail = try? h.read(upToCount: 16_384) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func preferredKeep(_ items: [FileItem], lookAlike: Bool) -> String {
        if lookAlike {
            return items.max { a, b in
                let pa = (a.pixelWidth ?? 0) * (a.pixelHeight ?? 0), pb = (b.pixelWidth ?? 0) * (b.pixelHeight ?? 0)
                if pa != pb { return pa < pb }
                return a.size < b.size
            }?.id ?? items[0].id
        }
        // Keep the copy outside Downloads if there is one, then the oldest (most likely the original).
        return items.min { a, b in
            let da = a.rootName == "Downloads", db = b.rootName == "Downloads"
            if da != db { return !da }
            return (a.created ?? a.activityDate) < (b.created ?? b.activityDate)
        }?.id ?? items[0].id
    }

    static func identical(_ items: [FileItem], progress: (Double) -> Void) -> [DuplicateGroup] {
        let candidates = items.filter { !$0.isFolder && !$0.isPackage && !$0.isCloudOnly && $0.size > 0 && $0.category != .apps }
        let bySize = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }
        let total = max(1, bySize.count)
        var groups: [DuplicateGroup] = []
        for (n, sameSize) in bySize.enumerated() {
            if n % 25 == 0 { progress(Double(n) / Double(total)) }
            let byEdge = Dictionary(grouping: sameSize) { edgeHash($0.url, size: $0.size) ?? UUID().uuidString }
            for (_, edgeGroup) in byEdge where edgeGroup.count > 1 {
                var byHash: [String: [FileItem]] = [:]
                for item in edgeGroup {
                    let stamp = item.modifiedStamp
                    let sha: String?
                    if let cached = Database.shared.hash(for: item.path, mtime: stamp, size: item.size) {
                        sha = cached
                    } else {
                        sha = sha256(item.url)
                        if let sha { Database.shared.saveHash(item.path, mtime: stamp, size: item.size, sha: sha) }
                    }
                    if let sha { byHash[sha, default: []].append(item) }
                }
                for (sha, same) in byHash where same.count > 1 {
                    groups.append(DuplicateGroup(id: "i-" + sha, kind: .identical, items: same,
                                                 keepID: preferredKeep(same, lookAlike: false)))
                }
            }
        }
        progress(1)
        return groups
    }

    static func featurePrint(_ item: FileItem) -> VNFeaturePrintObservation? {
        let stamp = item.modifiedStamp
        if let data = Database.shared.featurePrint(for: item.path, mtime: stamp),
           let obs = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) {
            return obs
        }
        return autoreleasepool {
            guard let image = TextExtractor.loadCGImage(item.url, maxPixel: 512) else { return nil }
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let obs = request.results?.first else { return nil }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true) {
                Database.shared.saveFeaturePrint(item.path, mtime: stamp, data: data)
            }
            return obs
        }
    }

    static func lookAlikes(_ items: [FileItem], excluding: Set<String>, threshold: Float,
                           progress: (Double) -> Void) -> [DuplicateGroup] {
        let photoExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tiff", "tif", "webp", "dng"]
        let images = items.filter {
            $0.category == .images && !$0.isCloudOnly && $0.size > 20_000 && photoExts.contains($0.ext) && !excluding.contains($0.id)
        }.sorted { ($0.created ?? $0.activityDate) < ($1.created ?? $1.activityDate) }
        guard images.count > 1 else { return [] }

        var prints: [FeaturePrintBox?] = []
        prints.reserveCapacity(images.count)
        for (i, item) in images.enumerated() {
            if i % 20 == 0 { progress(Double(i) / Double(images.count) * 0.85) }
            prints.append(featurePrint(item).map(FeaturePrintBox.init))
        }

        // Union-find over nearby photos (taken within 3 hours) plus same-name HEIC/JPEG pairs.
        var parent = Array(0..<images.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }

        func distance(_ a: Int, _ b: Int) -> Float? {
            guard let pa = prints[a]?.obs, let pb = prints[b]?.obs else { return nil }
            var d: Float = 0
            do { try pa.computeDistance(&d, to: pb) } catch { return nil }
            return d
        }

        for i in 0..<images.count {
            let di = images[i].created ?? images[i].activityDate
            var j = i + 1
            while j < images.count && j < i + 40 {
                let dj = images[j].created ?? images[j].activityDate
                if dj.timeIntervalSince(di) > 3 * 3600 { break }
                if let d = distance(i, j), d < threshold { union(i, j) }
                j += 1
            }
        }
        let byBase = Dictionary(grouping: images.indices) { images[$0].parentPath + "/" + images[$0].baseName.lowercased() }
        for (_, idxs) in byBase where idxs.count > 1 {
            for k in 1..<idxs.count {
                if let d = distance(idxs[0], idxs[k]), d < threshold * 2.2 { union(idxs[0], idxs[k]) }
            }
        }

        var clusters: [Int: [Int]] = [:]
        for i in images.indices { clusters[find(i), default: []].append(i) }
        progress(1)
        return clusters.values.filter { $0.count > 1 }.map { idxs in
            let members = idxs.map { images[$0] }
            return DuplicateGroup(id: "l-" + members.map(\.id).sorted().joined().hashValue.description,
                                  kind: .lookAlike, items: members, keepID: preferredKeep(members, lookAlike: true),
                                  included: false)   // Your call: look-alikes start unticked
        }
    }

    final class FeaturePrintBox {
        let obs: VNFeaturePrintObservation
        init(_ obs: VNFeaturePrintObservation) { self.obs = obs }
    }
}

@MainActor
@Observable
final class DuplicatesModel {
    static let shared = DuplicatesModel()

    var groups: [DuplicateGroup] = []
    var isScanning = false
    var progress: Double = 0
    var phase = ""
    var skippedCloud = 0
    var lastScan: Date?
    var includeLookAlikes = true

    /// Which kind the Duplicates screen opens on (set by the Tidy card that was clicked).
    var focus: DuplicateGroup.Kind?
    var totalReclaimable: Int64 { groups.filter(\.included).reduce(0) { $0 + $1.reclaimable } }
    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.items.count - 1 } }
    /// Everything that could be freed for one kind, ticked or not (what the Tidy card shows).
    func reclaimable(_ kind: DuplicateGroup.Kind) -> Int64 { groups.filter { $0.kind == kind }.reduce(0) { $0 + $1.reclaimable } }
    func extraCount(_ kind: DuplicateGroup.Kind) -> Int { groups.filter { $0.kind == kind }.reduce(0) { $0 + $1.items.count - 1 } }
    var selectedExtras: [FileItem] { groups.filter(\.included).flatMap(\.extras) }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        phase = "Comparing file fingerprints…"
        let items = FileIndex.shared.tidyItems
        let lookAlikes = includeLookAlikes
        let threshold = Float(Preferences.shared.lookAlikeThreshold)
        skippedCloud = items.filter(\.isCloudOnly).count
        Task.detached(priority: .userInitiated) {
            let exact = DuplicateFinder.identical(items) { p in
                Task { @MainActor in DuplicatesModel.shared.progress = lookAlikes ? p * 0.4 : p }
            }
            var all = exact
            if lookAlikes {
                await MainActor.run { DuplicatesModel.shared.phase = "Looking for look-alike photos…" }
                let used = Set(exact.flatMap { $0.items.map(\.id) })
                all += DuplicateFinder.lookAlikes(items, excluding: used, threshold: threshold) { p in
                    Task { @MainActor in DuplicatesModel.shared.progress = 0.4 + p * 0.6 }
                }
            }
            all.sort { $0.reclaimable > $1.reclaimable }
            let final = all
            await MainActor.run {
                let m = DuplicatesModel.shared
                m.groups = final
                m.isScanning = false
                m.progress = 1
                m.phase = ""
                m.lastScan = Date()
            }
        }
    }

    func setKeep(_ groupID: String, _ itemID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keepID = itemID
    }

    func toggle(_ groupID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].included.toggle()
    }

    func setAll(included: Bool, kind: DuplicateGroup.Kind?) {
        for i in groups.indices where kind == nil || groups[i].kind == kind { groups[i].included = included }
    }

    func removeTrashed(_ paths: Set<String>) {
        for i in groups.indices { groups[i].items.removeAll { paths.contains($0.id) } }
        groups.removeAll { $0.items.count < 2 }
    }
}
