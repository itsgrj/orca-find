import AppKit
import Vision
import PDFKit
import ImageIO
import AVFoundation

/// Everything that reads inside a file runs here, on the Mac. Nothing is uploaded.
enum TextExtractor {
    static let plainTextExts: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "log", "json", "yaml", "yml", "xml", "srt", "vtt", "ini", "conf"]
    static let richTextExts: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "wordml"]

    static func loadCGImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func recognize(_ image: CGImage, fast: Bool = false) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// For captures: one pass over the whole picture, then every small line is read again up close.
    /// Screenshots of web pages are full of 8–10px labels (chart axes, table rows, timestamps) that a
    /// whole-picture pass misreads ("Repeated wet searches", "8003180S"). Cropping each small line and
    /// enlarging it so the letters are ~48px tall fixes nearly all of them. Costs about a second.
    static func recognizeCloseUp(_ image: CGImage) -> String {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let first = textRequest()
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([first]) } catch { return "" }
        var rereads = 0
        return (first.results ?? []).compactMap { obs -> String? in
            guard let best = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox
            let linePx = box.height * H
            guard linePx < 30, rereads < 150 else { return withoutIconGlyph(best.string) }
            rereads += 1
            let pad = linePx * 0.6
            let rect = CGRect(x: box.minX * W - pad, y: (1 - box.maxY) * H - pad,
                              width: box.width * W + 2 * pad, height: linePx + 2 * pad)
                .integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard let crop = image.cropping(to: rect), let big = enlarge(crop, by: max(2, 48 / max(linePx, 1))) else { return best.string }
            let again = textRequest()
            guard (try? VNImageRequestHandler(cgImage: big, options: [:]).perform([again])) != nil else { return best.string }
            // Only text from the middle of the crop: the padding can catch the edge of the line above or below.
            let words = (again.results ?? [])
                .filter { abs($0.boundingBox.midY - 0.5) < 0.25 }
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first }
            guard !words.isEmpty, words.allSatisfy({ $0.confidence >= 0.3 }) else { return best.string }
            return withoutIconGlyph(bestOfBoth(first: best.string, closeUp: words.map(\.string).joined(separator: " ")))
        }
        .joined(separator: "\n")
    }

    /// The close-up reading is usually right, but now and then it breaks a word the first pass had
    /// ("request" → "reauest"). When both readings have the same words in the same places, keep the
    /// first pass's word wherever it's a real word and the close-up's isn't. Otherwise trust the close-up.
    static func bestOfBoth(first: String, closeUp: String) -> String {
        let a = first.split(separator: " ", omittingEmptySubsequences: true)
        let b = closeUp.split(separator: " ", omittingEmptySubsequences: true)
        guard a.count == b.count, a != b else { return closeUp }
        return zip(a, b).map { x, y in
            isWord(x) && !isWord(y) && letters(y).count > 0 ? String(x) : String(y)
        }.joined(separator: " ")
    }

    /// Checkmarks and list icons at the start of a line come out as a stray "V", "~" or "/" — drop a lone
    /// one when a capitalised word follows ("V Track failure trends" → "Track failure trends").
    static func withoutIconGlyph(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, ["V", "v", "~", "/", "\\", "✓", "✔", "√", "•", "·", "»", "›"].contains(String(parts[0])),
              parts[1].first?.isUppercase == true, parts[1].contains(" ") else { return line }
        return String(parts[1])
    }

    private static func letters(_ token: Substring) -> String { token.lowercased().filter(\.isLetter) }

    /// The Mac's built-in English word list (/usr/share/dict/words), loaded once on first use.
    private static let dictionary: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    private static func isWord(_ token: Substring) -> Bool {
        let w = letters(token)
        guard w.count >= 2, !dictionary.isEmpty else { return false }
        if dictionary.contains(w) { return true }
        // The list has no plurals or -ed/-ing forms: "failed" counts if "fail" is there.
        for suffix in ["s", "es", "ed", "d", "ing", "ly"] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            if dictionary.contains(String(w.dropLast(suffix.count))) { return true }
        }
        return false
    }

    private static func textRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return request
    }

    private static func enlarge(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) * factor), h = Int(CGFloat(image.height) * factor)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func ocr(_ url: URL) -> String {
        guard let image = loadCGImage(url, maxPixel: 2600) else { return "" }
        return recognize(image)
    }

    static func pdfText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var parts: [String] = []
        let pages = min(doc.pageCount, 60)
        for i in 0..<pages {
            if let s = doc.page(at: i)?.string { parts.append(s) }
        }
        var text = parts.joined(separator: "\n")
        // Scanned PDF: no text layer, so read the first pages with Vision.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            var ocrParts: [String] = []
            for i in 0..<min(doc.pageCount, 3) {
                guard let page = doc.page(at: i) else { continue }
                let thumb = page.thumbnail(of: NSSize(width: 1800, height: 1800), for: .mediaBox)
                if let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ocrParts.append(recognize(cg))
                }
            }
            text = ocrParts.joined(separator: "\n")
        }
        return text
    }

    static func documentText(_ url: URL, ext: String) -> String {
        if plainTextExts.contains(ext) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 400_000)) ?? Data()
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        if richTextExts.contains(ext) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
        }
        return ""
    }

    static func wantsText(_ item: FileItem, ocrEnabled: Bool) -> Bool {
        if item.isCloudOnly || item.isFolder { return false }
        switch item.category {
        case .images:
            return ocrEnabled && item.size > 2_000 && item.size < 80_000_000 && item.ext != "svg" && item.ext != "icns"
        case .documents:
            return item.ext == "pdf" || plainTextExts.contains(item.ext) || richTextExts.contains(item.ext)
        default:
            return false
        }
    }

    static func extract(_ item: FileItem) -> String {
        switch item.category {
        case .images: return ocr(item.url)
        case .documents:
            if item.ext == "pdf" { return pdfText(item.url) }
            return documentText(item.url, ext: item.ext)
        default: return ""
        }
    }

    /// Text for "Copy Text": cached text if we have it, otherwise run Vision now.
    static func textForCopy(_ item: FileItem) -> String {
        if let cached = Database.shared.text(for: item.path), !cached.isEmpty { return cached }
        let text = extract(item)
        Database.shared.saveText(item.path, mtime: item.modifiedStamp, body: text)
        return text
    }
}

enum MetadataReader {
    static func imageMeta(_ url: URL) -> CachedMeta {
        var m = CachedMeta(mtime: 0)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return m }
        m.width = props[kCGImagePropertyPixelWidth] as? Int
        m.height = props[kCGImagePropertyPixelHeight] as? Int
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let combined = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !combined.isEmpty { m.camera = combined }
        }
        return m
    }

    static func mediaMeta(_ url: URL, isVideo: Bool) async -> CachedMeta {
        var m = CachedMeta(mtime: 0)
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration), d.seconds.isFinite { m.duration = d.seconds }
        if isVideo {
            if let tracks = try? await asset.loadTracks(withMediaType: .video), let t = tracks.first,
               let size = try? await t.load(.naturalSize) {
                m.width = Int(abs(size.width)); m.height = Int(abs(size.height))
            }
            if let md = try? await asset.load(.metadata) {
                var make = "", model = ""
                for item in md {
                    let key = (item.identifier?.rawValue ?? "").lowercased()
                    if key.contains("model"), let v = try? await item.load(.stringValue) { model = v }
                    else if key.contains("make"), let v = try? await item.load(.stringValue) { make = v }
                }
                let combined = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
                if !combined.isEmpty { m.camera = combined }
            }
        }
        return m
    }

    static func bundleSize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            if let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func lastUsedDate(_ url: URL) -> Date? {
        guard let md = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
    }
}
