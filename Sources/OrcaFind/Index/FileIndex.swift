import Foundation
import Observation
import CoreServices

/// Patch produced by the background enricher.
struct ItemPatch {
    var camera: String?
    var width: Int?
    var height: Int?
    var duration: Double?
    var bundleSize: Int64?
    var hasText: Bool?
}

@MainActor
@Observable
final class FileIndex {
    static let shared = FileIndex()

    private(set) var items: [FileItem] = []
    private(set) var version = 0
    var isScanning = false
    var isReady = false
    var scannedCount = 0
    var textDone = 0
    var textTotal = 0
    var visualDone = 0
    var visualTotal = 0
    var lastScan: Date?

    @ObservationIgnored private var positions: [String: Int] = [:]
    @ObservationIgnored private var watcher: FSWatcher?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var roots: [FileScanner.Root] = []
    @ObservationIgnored var onChange: [() -> Void] = []
    @ObservationIgnored var onReady: [() -> Void] = []
    /// Used by the developer snapshot mode to index a fixture folder instead of the home folders.
    @ObservationIgnored static var overrideRoots: [FileScanner.Root]?

    func item(_ path: String) -> FileItem? {
        guard let i = positions[path], i < items.count else { return nil }
        return items[i]
    }

    func start() { rescan() }

    func rescan() {
        generation += 1
        let gen = generation
        let prefs = Preferences.shared
        roots = FileIndex.overrideRoots
            ?? FileScanner.roots(extraFolders: prefs.extraFolders, disabledDefaults: Set(prefs.disabledDefaultFolders))
        let roots = self.roots
        isScanning = true
        scannedCount = 0
        Enricher.shared.cancel()

        Task.detached(priority: .userInitiated) {
            var scanned = FileScanner.scan(roots: roots) { n in
                Task { @MainActor in
                    if gen == FileIndex.shared.generation { FileIndex.shared.scannedCount = n }
                }
            }
            let meta = Database.shared.loadMeta()
            let texts = Database.shared.loadTextState()
            let visuals = Database.shared.loadVisual()
            let ocr = Preferences.ocrEnabledValue
            let smartPictures = Preferences.smartPicturesValue
            let clip = smartPictures && MobileCLIP.isBundled
            let embeddings = clip ? Database.shared.loadEmbeddings(model: MobileCLIP.modelID) : [:]
            var needsMeta: [FileItem] = []
            var needsText: [FileItem] = []
            var needsVisual: [FileItem] = []
            var visualMap: [String: VisualInfo] = [:]
            var vectorMap: [String: [Float]] = [:]
            for i in scanned.indices {
                let stamp = scanned[i].modifiedStamp
                if let m = meta[scanned[i].path], m.mtime == stamp {
                    FileIndex.applyMeta(m, to: &scanned[i])
                } else if Enricher.wantsMeta(scanned[i]) {
                    needsMeta.append(scanned[i])
                }
                if let t = texts[scanned[i].path], t.mtime == stamp {
                    scanned[i].hasText = t.hasText
                } else if TextExtractor.wantsText(scanned[i], ocrEnabled: ocr) {
                    needsText.append(scanned[i])
                }
                var labelled = false, embedded = !clip
                if let v = visuals[scanned[i].path], v.mtime == stamp {
                    labelled = true
                    if !v.info.labels.isEmpty || !v.info.colours.isEmpty { visualMap[scanned[i].path] = v.info }
                }
                if clip, let e = embeddings[scanned[i].path], e.mtime == stamp {
                    embedded = true
                    if let vec = e.vector { vectorMap[scanned[i].path] = vec }
                }
                if (!labelled || !embedded) && smartPictures && VisualAnalyzer.wants(scanned[i]) {
                    needsVisual.append(scanned[i])
                }
            }
            VisualStore.shared.replaceAll(visualMap)
            EmbeddingStore.shared.replaceAll(vectorMap)
            let finalItems = scanned
            let metaQueue = needsMeta
            let textQueue = needsText
            let visualQueue = needsVisual
            await MainActor.run {
                let index = FileIndex.shared
                guard gen == index.generation else { return }
                index.setItems(finalItems)
                index.isScanning = false
                index.lastScan = Date()
                let firstReady = !index.isReady
                index.isReady = true
                index.startWatcher()
                index.textDone = 0
                index.textTotal = textQueue.count
                index.visualDone = 0
                index.visualTotal = visualQueue.count
                Enricher.shared.start(meta: metaQueue, text: textQueue, visual: visualQueue)
                if firstReady { index.onReady.forEach { $0() } }
            }
        }
    }

    nonisolated static func applyMeta(_ m: CachedMeta, to item: inout FileItem) {
        item.camera = m.camera
        item.pixelWidth = m.width
        item.pixelHeight = m.height
        item.duration = m.duration
        if let b = m.bundleSize, b > 0 { item.size = b }
    }

    private func setItems(_ new: [FileItem]) {
        items = new
        rebuildPositions()
        bump()
    }

    private func rebuildPositions() {
        positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.path, $0) })
    }

    private func bump() {
        version += 1
        onChange.forEach { $0() }
    }

    func apply(_ patches: [(String, ItemPatch)]) {
        guard !patches.isEmpty else { return }
        for (path, p) in patches {
            guard let i = positions[path] else { continue }
            if let v = p.camera { items[i].camera = v }
            if let v = p.width { items[i].pixelWidth = v }
            if let v = p.height { items[i].pixelHeight = v }
            if let v = p.duration { items[i].duration = v }
            if let v = p.bundleSize, v > 0 { items[i].size = v }
            if let v = p.hasText { items[i].hasText = v }
        }
        bump()
    }

    func upsert(_ new: [FileItem]) {
        guard !new.isEmpty else { return }
        for var item in new {
            if let i = positions[item.path] {
                let old = items[i]
                if old.modified == item.modified {
                    item.camera = old.camera; item.pixelWidth = old.pixelWidth; item.pixelHeight = old.pixelHeight
                    item.duration = old.duration; item.hasText = old.hasText
                    if item.isPackage { item.size = old.size }
                }
                items[i] = item
            } else {
                positions[item.path] = items.count
                items.append(item)
            }
        }
        bump()
    }

    func remove(paths: [String]) {
        guard !paths.isEmpty else { return }
        let exact = Set(paths)
        // Paths we don't know as items may be folders: then everything inside them goes too.
        let mayBeFolders = paths.contains { positions[$0] == nil }
        let before = items.count
        items.removeAll { item in
            if exact.contains(item.path) { return true }
            guard mayBeFolders else { return false }
            var p = item.parentPath
            while p.count > 1 {
                if exact.contains(p) { return true }
                p = (p as NSString).deletingLastPathComponent
            }
            return false
        }
        VisualStore.shared.remove(paths)
        EmbeddingStore.shared.remove(paths)
        if items.count != before {
            rebuildPositions()
            bump()
        }
        let removed = paths
        Task.detached(priority: .utility) { Database.shared.remove(paths: removed) }
    }

    // MARK: - Live updates

    private func startWatcher() {
        watcher = FSWatcher(paths: roots.map { $0.url.path }) { paths in
            Task { @MainActor in FileIndex.shared.handle(events: paths) }
        }
    }

    private func handle(events: [String]) {
        let roots = self.roots
        let unique = Array(Set(events))
        Task.detached(priority: .utility) {
            var upserts: [FileItem] = []
            var removals: [String] = []
            for p in unique {
                let comps = p.split(separator: "/")
                if comps.contains(where: { $0.hasPrefix(".") }) { continue }
                if comps.contains(where: { FileScanner.protectedPackageExts.contains((String($0) as NSString).pathExtension.lowercased()) }) { continue }
                guard let root = roots.first(where: { p.hasPrefix($0.url.path + "/") }) else { continue }
                let url = URL(fileURLWithPath: p)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                    let values = try? url.resourceValues(forKeys: FileScanner.keySet)
                    if isDir.boolValue && values?.isPackage != true {
                        upserts += FileScanner.scan(roots: [FileScanner.Root(url: url, name: root.name, maxDepth: 8)])
                    } else if let item = FileScanner.makeItem(url: url, rootName: root.name, values: values) {
                        upserts.append(item)
                    }
                } else {
                    removals.append(p)
                }
            }
            let up = upserts, rm = removals
            await MainActor.run {
                FileIndex.shared.remove(paths: rm)
                FileIndex.shared.upsert(up)
                let ocr = Preferences.shared.ocrEnabled
                Enricher.shared.enqueue(meta: up.filter(Enricher.wantsMeta),
                                        text: up.filter { TextExtractor.wantsText($0, ocrEnabled: ocr) },
                                        visual: Preferences.shared.smartPictures ? up.filter(VisualAnalyzer.wants) : [])
            }
        }
    }

    // MARK: - Convenience

    var downloads: [FileItem] {
        items.filter { $0.rootName == "Downloads" }
            .sorted { ($0.added ?? $0.activityDate) > ($1.added ?? $1.activityDate) }
    }

    var latestDownload: FileItem? { downloads.first }
}

/// FSEvents wrapper: reports changed file paths under the watched roots.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let callback: ([String]) -> Void

    init(paths: [String], callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, FSWatcher.eventCallback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(paths, to: NSArray.self)
        let list = (0..<count).compactMap { array[$0] as? String }
        watcher.callback(list)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
