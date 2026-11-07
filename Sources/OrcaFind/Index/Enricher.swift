import Foundation

/// Background worker: reads image/video metadata, app bundle sizes, and text inside files.
/// Runs at utility priority, newest and most useful files first, and caches results in SQLite.
final class Enricher: @unchecked Sendable {
    static let shared = Enricher()

    private let lock = NSLock()
    private var metaQueue: [FileItem] = []
    private var textQueue: [FileItem] = []
    private var visualQueue: [FileItem] = []
    private var running = false
    private var generation = 0

    static func wantsMeta(_ item: FileItem) -> Bool {
        if item.isCloudOnly || item.isFolder { return false }
        switch item.category {
        case .images, .videos, .music: return true
        case .apps: return item.isPackage
        default: return false
        }
    }

    private static func prioritized(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            if a.isScreenshot != b.isScreenshot { return a.isScreenshot }
            let ad = a.rootName == "Downloads", bd = b.rootName == "Downloads"
            if ad != bd { return ad }
            return a.activityDate > b.activityDate
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        metaQueue = []
        textQueue = []
        visualQueue = []
        lock.unlock()
    }

    func start(meta: [FileItem], text: [FileItem], visual: [FileItem] = []) {
        lock.lock()
        metaQueue = Enricher.prioritized(meta)
        textQueue = Enricher.prioritized(text)
        visualQueue = Enricher.prioritized(visual)
        lock.unlock()
        kick()
    }

    func enqueue(meta: [FileItem], text: [FileItem], visual: [FileItem] = []) {
        guard !meta.isEmpty || !text.isEmpty || !visual.isEmpty else { return }
        lock.lock()
        metaQueue.insert(contentsOf: meta, at: 0)
        textQueue.insert(contentsOf: text, at: 0)
        visualQueue.insert(contentsOf: visual, at: 0)
        lock.unlock()
        if !text.isEmpty || !visual.isEmpty {
            Task { @MainActor in
                FileIndex.shared.textTotal += text.count
                FileIndex.shared.visualTotal += visual.count
            }
        }
        kick()
    }

    private func kick() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        Task.detached(priority: .utility) { await self.loop() }
    }

    private enum Job { case meta(FileItem), text(FileItem), visual(FileItem) }

    private func isStale(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen != generation
    }

    private func next(_ n: Int) -> (gen: Int, jobs: [Job]) {
        lock.lock(); defer { lock.unlock() }
        var jobs: [Job] = []
        while jobs.count < n, !metaQueue.isEmpty { jobs.append(.meta(metaQueue.removeFirst())) }
        // Text reading and picture looking share the rest, so neither waits for the other to finish.
        while jobs.count < n, !textQueue.isEmpty || !visualQueue.isEmpty {
            if !visualQueue.isEmpty { jobs.append(.visual(visualQueue.removeFirst())) }
            if jobs.count < n, !textQueue.isEmpty { jobs.append(.text(textQueue.removeFirst())) }
        }
        if jobs.isEmpty { running = false }
        return (generation, jobs)
    }

    private func loop() async {
        while true {
            let (gen, jobs) = next(12)
            if jobs.isEmpty { return }
            var patches: [(String, ItemPatch)] = []
            var textCount = 0
            var visualCount = 0
            for job in jobs {
                switch job {
                case .meta(let item):
                    if let p = await enrichMeta(item) { patches.append((item.path, p)) }
                case .text(let item):
                    let body = autoreleasepool { TextExtractor.extract(item) }
                    Database.shared.saveText(item.path, mtime: item.modifiedStamp, body: body)
                    let has = body.trimmingCharacters(in: .whitespacesAndNewlines).count > 2
                    patches.append((item.path, ItemPatch(hasText: has)))
                    textCount += 1
                case .visual(let item):
                    // Labels + colours (Vision) and the MobileCLIP embedding share one decode of the picture.
                    let embed = MobileCLIP.isAvailable
                    let seen = VisualAnalyzer.look(item, labels: true, embed: embed)
                    let info = seen?.info ?? VisualInfo()
                    Database.shared.saveVisual(item.path, mtime: item.modifiedStamp, info)
                    if !info.labels.isEmpty || !info.colours.isEmpty { VisualStore.shared.set(item.path, info) }
                    if embed {
                        Database.shared.saveEmbedding(item.path, mtime: item.modifiedStamp, model: MobileCLIP.modelID, seen?.vector)
                        if let v = seen?.vector { EmbeddingStore.shared.set(item.path, v) }
                    }
                    visualCount += 1
                }
                if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            if isStale(gen) { continue }
            let batch = patches, done = textCount, seen = visualCount
            await MainActor.run {
                FileIndex.shared.apply(batch)
                FileIndex.shared.textDone += done
                FileIndex.shared.visualDone += seen
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func enrichMeta(_ item: FileItem) async -> ItemPatch? {
        var meta: CachedMeta
        switch item.category {
        case .images:
            meta = MetadataReader.imageMeta(item.url)
        case .videos:
            meta = await MetadataReader.mediaMeta(item.url, isVideo: true)
        case .music:
            meta = await MetadataReader.mediaMeta(item.url, isVideo: false)
        case .apps:
            meta = CachedMeta(mtime: 0, bundleSize: MetadataReader.bundleSize(item.url))
        default:
            return nil
        }
        meta.mtime = item.modifiedStamp
        Database.shared.saveMeta(item.path, meta)
        return ItemPatch(camera: meta.camera, width: meta.width, height: meta.height,
                         duration: meta.duration, bundleSize: meta.bundleSize)
    }
}
