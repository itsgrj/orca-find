import AppKit
import QuickLookThumbnailing

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 2000 }

    static func bucket(_ size: CGFloat) -> Int {
        size <= 40 ? 64 : size <= 120 ? 160 : size <= 240 ? 320 : 640
    }

    func cached(_ item: FileItem, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(item, ThumbnailCache.bucket(size)))
    }

    private func key(_ item: FileItem, _ bucket: Int) -> NSString {
        "\(item.path)|\(item.modifiedStamp)|\(bucket)" as NSString
    }

    func image(for item: FileItem, size: CGFloat) async -> NSImage? {
        let b = ThumbnailCache.bucket(size)
        let k = key(item, b)
        if let img = cache.object(forKey: k) { return img }
        if item.isFolder || item.category == .apps {
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            cache.setObject(icon, forKey: k)
            return icon
        }
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: b, height: b),
                                                   scale: 2, representationTypes: .all)
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let img = rep.nsImage
            cache.setObject(img, forKey: k)
            return img
        } catch {
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            cache.setObject(icon, forKey: k)
            return icon
        }
    }
}
