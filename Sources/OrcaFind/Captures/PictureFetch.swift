import Foundation
import ImageIO

/// Fetches the original file behind a picture clicked on a web page, so the capture is the picture itself:
/// no Save button or hover icons on top, and usually sharper than the screen.
enum PictureFetch {
    /// The biggest copies worth trying first, then the file the page showed.
    /// Pinterest boards show a small copy (236x); the same path under /originals/ or /736x/ is the full pin.
    static func candidates(_ raw: String) -> [URL] {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return [] }
        if scheme == "data" { return [url] }
        guard scheme == "http" || scheme == "https" else { return [] } // blob: and the like can't be fetched
        var out: [URL] = []
        if url.host?.hasSuffix("pinimg.com") == true {
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
            if let size = parts.first, size == "originals" || size.range(of: #"^\d+x(\d+)?"#, options: .regularExpression) != nil {
                let rest = parts.dropFirst().joined(separator: "/")
                for better in ["originals", "736x"] where better != size {
                    if let u = URL(string: "https://\(url.host!)/\(better)/\(rest)") { out.append(u) }
                }
            }
        }
        out.append(url)
        return out
    }

    /// The picture, or nil when the site won't hand it over (then the screen grab stays).
    /// `shown`: the picture's size on screen in points, to reject lazy-load placeholders and sprites.
    static func image(from raw: String, referer: String?, shown: CGSize) async -> CGImage? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        for url in candidates(raw) {
            var req = URLRequest(url: url)
            if url.scheme != "data" {
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
                req.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
                if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
            }
            guard let (data, response) = try? await session.data(for: req) else { continue }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { continue }
            guard let img = decode(data), fits(img, shown: shown) else { continue }
            return img
        }
        return nil
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 4096,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Real picture, not a 1×1 placeholder or a sprite sheet: big enough, and roughly the shape shown.
    /// (Sites crop pictures to fit a card, so the shape only has to be in the same family.)
    private static func fits(_ img: CGImage, shown: CGSize) -> Bool {
        guard img.width >= 64, img.height >= 64, shown.width > 0, shown.height > 0 else { return false }
        let a = Double(img.width) / Double(img.height)
        let b = Double(shown.width) / Double(shown.height)
        return max(a / b, b / a) <= 2.5
    }
}

/// ~/Library/Logs/OrcaFind/capture.log: why a picture did or didn't light up, and whether its file arrived.
enum CaptureLog {
    private static let queue = DispatchQueue(label: "orcafind.capturelog")
    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OrcaFind")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("capture.log")
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: file) }
        }
    }
}
