import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Picture edits built only on Apple frameworks: Vision (subject masks, text), Core Image
/// (adjustments, looks, redaction, geometry) and ImageIO (formats, size, metadata).
enum ImageEngine {
    static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func load(_ url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Source metadata (EXIF, GPS, TIFF…) so copies keep what they should.
    static func properties(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return p
    }

    static func hasLocation(_ props: [String: Any]) -> Bool { props[kCGImagePropertyGPSDictionary as String] != nil }

    static func cgImage(_ image: CIImage, maxSide: CGFloat? = nil) -> CGImage? {
        var img = image
        let e = image.extent
        guard e.width.isFinite, e.height.isFinite, e.width > 0, e.height > 0 else { return nil }
        if let maxSide, max(e.width, e.height) > maxSide {
            let s = maxSide / max(e.width, e.height)
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
        return context.createCGImage(img, from: CGRect(origin: .zero, size: img.extent.size).integral, format: .RGBA8, colorSpace: sRGB)
    }

    static func nsImage(_ image: CIImage, maxSide: CGFloat? = nil) -> NSImage? {
        guard let cg = cgImage(image, maxSide: maxSide) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Subject (Vision)

    /// Result of Vision's foreground request, kept so the user can pick which subjects to keep.
    final class Subjects: @unchecked Sendable {
        let observation: VNInstanceMaskObservation
        let handler: VNImageRequestHandler
        let extent: CGRect
        init(observation: VNInstanceMaskObservation, handler: VNImageRequestHandler, extent: CGRect) {
            self.observation = observation; self.handler = handler; self.extent = extent
        }
        var all: IndexSet { observation.allInstances }

        /// Full-size soft mask for the chosen subjects.
        func mask(_ instances: IndexSet) -> CIImage? {
            guard let buf = try? observation.generateScaledMaskForImage(forInstances: instances, from: handler) else { return nil }
            var m = CIImage(cvPixelBuffer: buf)
            let sx = extent.width / m.extent.width, sy = extent.height / m.extent.height
            if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 { m = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy)) }
            return m.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
        }

        /// Which subject sits under a point given as 0…1 from the top-left; nil for background.
        func instance(at p: CGPoint) -> Int? {
            let buf = observation.instanceMask
            CVPixelBufferLockBaseAddress(buf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
            let x = min(w - 1, max(0, Int(p.x * CGFloat(w)))), y = min(h - 1, max(0, Int(p.y * CGFloat(h))))
            guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
            let row = CVPixelBufferGetBytesPerRow(buf)
            let label = base.load(fromByteOffset: y * row + x, as: UInt8.self)
            return label == 0 ? nil : Int(label)
        }
    }

    static func findSubjects(_ image: CIImage) async throws -> Subjects {
        try await Task.detached(priority: .userInitiated) {
            // Vision works on a flattened copy; very large pictures are scaled to keep it quick.
            guard let cg = cgImage(image, maxSide: 4096) else { throw EditError.message("Couldn’t read the picture") }
            let handler = VNImageRequestHandler(cgImage: cg)
            let req = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([req])
            guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
                throw EditError.message("No clear subject found in this picture")
            }
            return Subjects(observation: obs, handler: handler, extent: image.extent)
        }.value
    }

    enum Behind: Equatable { case clear, white, black, color(NSColor), blurred }

    static func cutOut(_ image: CIImage, mask: CIImage, behind: Behind) -> CIImage {
        let e = image.extent
        let back: CIImage
        switch behind {
        case .clear: back = CIImage(color: .clear).cropped(to: e)
        case .white: back = CIImage(color: .white).cropped(to: e)
        case .black: back = CIImage(color: .black).cropped(to: e)
        case .color(let c): back = CIImage(color: CIColor(color: c.usingColorSpace(.sRGB) ?? c) ?? .white).cropped(to: e)
        case .blurred: back = image.clampedToExtent().applyingGaussianBlur(sigma: max(e.width, e.height) / 80).cropped(to: e)
        }
        let f = CIFilter.blendWithMask()
        f.inputImage = image; f.backgroundImage = back; f.maskImage = mask
        return (f.outputImage ?? image).cropped(to: e)
    }

    /// The cut-out with a white border, like a Messages sticker.
    static func sticker(_ cutout: CIImage) -> CIImage {
        let e = cutout.extent
        let r = max(4, min(e.width, e.height) / 60)
        let alpha = cutout.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)])
        let grown = alpha.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": r]).cropped(to: e)
        return cutout.composited(over: grown).cropped(to: e)
    }

    // MARK: Light and colour

    static func autoEnhance(_ image: CIImage) -> CIImage {
        var out = image
        for f in image.autoAdjustmentFilters(options: [.redEye: false]) {
            f.setValue(out, forKey: kCIInputImageKey)
            out = f.outputImage ?? out
        }
        return out.cropped(to: image.extent)
    }

    struct Adjustments: Equatable {
        var light: Double = 0      // −100…100
        var colour: Double = 0     // −100…100
        var warmth: Double = 0     // −100…100
        var sharpness: Double = 0  // 0…100
        var look: String?          // a CIPhotoEffect filter name
        var isNeutral: Bool { light == 0 && colour == 0 && warmth == 0 && sharpness == 0 && look == nil }
    }

    static let looks: [(name: String, filter: String?)] = [
        ("Original", nil), ("Vivid", "vivid"), ("Mono", "CIPhotoEffectMono"), ("Noir", "CIPhotoEffectNoir"),
        ("Chrome", "CIPhotoEffectChrome"), ("Fade", "CIPhotoEffectFade"), ("Instant", "CIPhotoEffectInstant"), ("Process", "CIPhotoEffectProcess"),
    ]

    static func adjust(_ image: CIImage, _ a: Adjustments) -> CIImage {
        let e = image.extent
        var out = image
        if a.light != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = out; f.ev = Float(a.light / 100 * 1.2); out = f.outputImage ?? out
        }
        if a.colour != 0 {
            let f = CIFilter.colorControls(); f.inputImage = out; f.saturation = Float(1 + a.colour / 100); out = f.outputImage ?? out
        }
        if a.warmth != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = out
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 6500 + a.warmth * 25, y: 0)
            out = f.outputImage ?? out
        }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = out; f.sharpness = Float(a.sharpness / 100 * 1.5); out = f.outputImage ?? out
        }
        if let look = a.look { out = applyLook(out, look) }
        return out.cropped(to: e)
    }

    static func applyLook(_ image: CIImage, _ look: String) -> CIImage {
        if look == "vivid" {
            let f = CIFilter.colorControls(); f.inputImage = image; f.saturation = 1.45; f.contrast = 1.08
            return f.outputImage ?? image
        }
        guard let f = CIFilter(name: look) else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        return f.outputImage ?? image
    }

    // MARK: Geometry (rects are 0…1 from the top-left, like the screen)

    static func ciRect(_ n: CGRect, in e: CGRect) -> CGRect {
        CGRect(x: e.minX + n.minX * e.width, y: e.minY + (1 - n.maxY) * e.height, width: n.width * e.width, height: n.height * e.height).integral
    }

    static func rotateLeft(_ image: CIImage) -> CIImage { normalize(image.oriented(.left)) }
    static func flip(_ image: CIImage) -> CIImage { normalize(image.oriented(.upMirrored)) }

    static func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        guard degrees != 0 else { return image }
        let f = CIFilter.straighten(); f.inputImage = image; f.angle = Float(degrees * .pi / 180)
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    static func crop(_ image: CIImage, to n: CGRect) -> CIImage {
        normalize(image.cropped(to: ciRect(n, in: image.extent)))
    }

    static func scaled(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let e = image.extent
        guard max(e.width, e.height) > maxSide else { return image }
        let s = maxSide / max(e.width, e.height)
        let f = CIFilter.lanczosScaleTransform(); f.inputImage = image; f.scale = Float(s); f.aspectRatio = 1
        return normalize(f.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: s, y: s)))
    }

    /// Moves the picture so its corner sits at 0,0 (keeps later maths simple).
    static func normalize(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
    }

    // MARK: Redaction

    enum RedactStyle: String, CaseIterable { case pixelate = "Pixelate", blur = "Blur", bar = "Bar" }

    static func redact(_ image: CIImage, _ n: CGRect, style: RedactStyle, block: Double) -> CIImage {
        let e = image.extent
        let r = ciRect(n, in: e).intersection(e)
        guard !r.isEmpty else { return image }
        let patch: CIImage
        switch style {
        case .pixelate:
            let scale = max(4, block * max(e.width, e.height) / 1200)
            let f = CIFilter.pixellate(); f.inputImage = image.clampedToExtent(); f.scale = Float(scale); f.center = CGPoint(x: r.minX, y: r.minY)
            patch = (f.outputImage ?? image).cropped(to: r)
        case .blur:
            patch = image.clampedToExtent().applyingGaussianBlur(sigma: max(8, Double(r.height) / 3)).cropped(to: r)
        case .bar:
            patch = CIImage(color: .black).cropped(to: r)
        }
        return patch.composited(over: image).cropped(to: e)
    }

    // MARK: Drawing

    struct Mark: Identifiable {
        enum Kind { case pen, highlighter, arrow, box, text }
        let id = UUID()
        var kind: Kind
        var points: [CGPoint]      // 0…1 from the top-left
        var color: NSColor
        var width: CGFloat         // relative to the picture's longer side, e.g. 0.006
        var text: String = ""
        var fontSize: CGFloat = 0.035
    }

    /// Paints marks onto the picture with Core Graphics.
    static func draw(_ marks: [Mark], onto image: CIImage) -> CIImage {
        let e = image.extent
        let w = Int(e.width), h = Int(e.height)
        guard w > 0, h > 0, !marks.isEmpty,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        render(marks, in: CGSize(width: w, height: h), ctx: ctx)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return image }
        let overlay = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        return overlay.composited(over: image).cropped(to: e)
    }

    /// Shared by the saved picture and the live overlay so they look the same. The context must be top-left based.
    static func render(_ marks: [Mark], in size: CGSize, ctx: CGContext) {
        let side = max(size.width, size.height)
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        for m in marks {
            ctx.saveGState()
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let lw = max(1.5, m.width * side)
            switch m.kind {
            case .pen, .highlighter:
                guard let first = m.points.first else { break }
                ctx.setStrokeColor(m.color.withAlphaComponent(m.kind == .highlighter ? 0.38 : 1).cgColor)
                ctx.setLineWidth(m.kind == .highlighter ? lw * 4 : lw)
                if m.kind == .highlighter { ctx.setBlendMode(.multiply); ctx.setLineCap(.square) }
                ctx.beginPath(); ctx.move(to: pt(first))
                for p in m.points.dropFirst() { ctx.addLine(to: pt(p)) }
                if m.points.count == 1 { ctx.addLine(to: pt(first)) }
                ctx.strokePath()
            case .box:
                guard m.points.count >= 2 else { break }
                let a = pt(m.points[0]), b = pt(m.points[m.points.count - 1])
                ctx.setStrokeColor(m.color.cgColor); ctx.setLineWidth(lw)
                ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
            case .arrow:
                guard m.points.count >= 2 else { break }
                let a = pt(m.points[0]), b = pt(m.points[m.points.count - 1])
                ctx.setStrokeColor(m.color.cgColor); ctx.setFillColor(m.color.cgColor); ctx.setLineWidth(lw)
                let ang = atan2(b.y - a.y, b.x - a.x), head = max(lw * 4.5, side * 0.022, 12)
                let base = CGPoint(x: b.x - cos(ang) * head * 0.8, y: b.y - sin(ang) * head * 0.8)
                ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: base); ctx.strokePath()
                ctx.beginPath(); ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(ang - 0.45) * head, y: b.y - sin(ang - 0.45) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(ang + 0.45) * head, y: b.y - sin(ang + 0.45) * head))
                ctx.closePath(); ctx.fillPath()
            case .text:
                guard let p = m.points.first, !m.text.isEmpty else { break }
                let font = NSFont.systemFont(ofSize: max(10, m.fontSize * side), weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: m.color]
                NSAttributedString(string: m.text, attributes: attrs).draw(at: pt(p))
            }
            ctx.restoreGState()
        }
    }

    // MARK: Text in pictures

    static func recognizeText(_ image: CIImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let cg = cgImage(image, maxSide: 3000) else { return "" }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    // MARK: Saving

    enum Format: String, CaseIterable, Identifiable {
        case original = "Same", jpeg = "JPEG", png = "PNG", heic = "HEIC", tiff = "TIFF", pdf = "PDF"
        var id: String { rawValue }
        var ext: String {
            switch self { case .jpeg: return "jpg"; case .png: return "png"; case .heic: return "heic"; case .tiff: return "tiff"; case .pdf: return "pdf"; case .original: return "" }
        }
        var utType: UTType {
            switch self { case .jpeg: return .jpeg; case .png: return .png; case .heic: return .heic; case .tiff: return .tiff; case .pdf: return .pdf; case .original: return .png }
        }
        var lossy: Bool { self == .jpeg || self == .heic }
        var keepsTransparency: Bool { self == .png || self == .tiff || self == .heic }

        static func from(ext: String) -> Format? {
            switch ext.lowercased() {
            case "jpg", "jpeg": return .jpeg
            case "png": return .png
            case "heic", "heif": return .heic
            case "tif", "tiff": return .tiff
            default: return nil
            }
        }
    }

    struct ExportSettings: Equatable {
        var format: Format = .original
        var maxSide: Int?            // nil keeps the size
        var quality: Double = 0.85
        var stripLocation = true     // copies drop GPS and camera serials by default
    }

    /// Encodes the picture. `source` is the original's metadata; orientation is reset because the pixels are already upright.
    static func encode(_ image: CIImage, format: Format, settings: ExportSettings, source: [String: Any]) throws -> Data {
        var img = image
        if let m = settings.maxSide { img = scaled(img, maxSide: CGFloat(m)) }
        guard let cg = cgImage(img) else { throw EditError.message("Couldn’t draw the picture") }
        if format == .pdf {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw EditError.message("Couldn’t make the PDF") }
            pdf.beginPDFPage(nil); pdf.draw(cg, in: box); pdf.endPDFPage(); pdf.closePDF()
            return data as Data
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw EditError.message("This Mac can’t write \(format.rawValue)")
        }
        var props = source
        props[kCGImagePropertyOrientation as String] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        props.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            if settings.stripLocation { tiff.removeValue(forKey: kCGImagePropertyTIFFMake as String); tiff.removeValue(forKey: kCGImagePropertyTIFFModel as String) }
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if settings.stripLocation {
            props.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
            props.removeValue(forKey: kCGImagePropertyMakerAppleDictionary as String)
            if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                for k in [kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifCameraOwnerName] { exif.removeValue(forKey: k as String) }
                props[kCGImagePropertyExifDictionary as String] = exif
            }
        }
        if format.lossy { props[kCGImageDestinationLossyCompressionQuality as String] = settings.quality }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EditError.message("Couldn’t save as \(format.rawValue)") }
        return data as Data
    }

    static func pngData(_ image: CIImage) -> Data? {
        guard let cg = cgImage(image) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Colour under a point (0…1 from the top-left) of an already-drawn picture.
    static func color(at p: CGPoint, in cg: CGImage) -> NSColor? {
        let rep = NSBitmapImageRep(cgImage: cg)
        let x = min(rep.pixelsWide - 1, max(0, Int(p.x * CGFloat(rep.pixelsWide))))
        let y = min(rep.pixelsHigh - 1, max(0, Int(p.y * CGFloat(rep.pixelsHigh))))
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }
}
