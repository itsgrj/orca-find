import Foundation
import CoreML
import CoreImage
import CoreVideo
import AppKit

/// "Erase an object": paint over something and an inpainting model fills it from its surroundings.
/// Only a square around the painted area goes through the model; everything else keeps full resolution.
///   Best  — LaMa (Samsung AI), 800×800, Core ML conversion by john-rocky
///   Quick — MI-GAN (Picsart AI Research, MIT), 512×512, converted by tools/eraser/convert_migan.py
enum Eraser {
    enum Model: String, CaseIterable, Identifiable {
        case best = "Best", quick = "Quick"
        var id: String { rawValue }
        var file: String { self == .best ? "LaMa" : "MIGAN" }
        var side: Int { self == .best ? 800 : 512 }
        var credit: String { self == .best ? "LaMa by Samsung AI" : "MI-GAN by Picsart AI Research" }
    }

    /// Quick ships in the app; Best is downloaded once (the "Pro eraser" in Orca's private AI).
    static func url(_ m: Model) -> URL? { PrivateAI.find(m.file + ".mlmodelc") }
    static func isAvailable(_ m: Model) -> Bool { url(m) != nil }
    static var available: [Model] { Model.allCases.filter(isAvailable) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [Model: MLModel] = [:]

    static func model(_ m: Model) throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let x = loaded[m] { return x }
        guard let u = url(m) else { throw EditError.message(m == .best ? "Unlock the Pro eraser first" : "The eraser isn’t installed") }
        let cfg = MLModelConfiguration()
        // LaMa was converted and checked for all compute units; MI-GAN is float32, which the Neural Engine can't run.
        cfg.computeUnits = m == .best ? .all : .cpuAndGPU
        let x = try MLModel(contentsOf: u, configuration: cfg)
        loaded[m] = x
        return x
    }

    /// After the Pro eraser is downloaded or removed.
    static func reload() { lock.lock(); loaded = [:]; lock.unlock() }

    /// `image` is normalised (origin 0,0). `mask` is 8-bit grey, same pixel size, white = erase.
    static func erase(_ image: CIImage, mask: CGImage, using m: Model) throws -> CIImage {
        let W = Int(image.extent.width), H = Int(image.extent.height)
        guard W > 0, H > 0, mask.width == W, mask.height == H else { throw EditError.message("Mask doesn’t match the picture") }
        guard let box = paintedBox(mask) else { return image }        // top-left based

        // A square around the painting, with enough surroundings for the model to copy from.
        let need = max(box.width, box.height)
        var side = min(max(need * 2.2 + 64, 192), CGFloat(min(W, H)))
        var region: CGRect
        if need >= CGFloat(min(W, H)) * 0.92 {
            region = CGRect(x: 0, y: 0, width: W, height: H)
        } else {
            side = side.rounded()
            var x = box.midX - side / 2, y = box.midY - side / 2
            x = min(max(0, x), CGFloat(W) - side); y = min(max(0, y), CGFloat(H) - side)
            region = CGRect(x: x, y: y, width: side, height: side).integral
        }
        let ciRegion = CGRect(x: region.minX, y: CGFloat(H) - region.maxY, width: region.width, height: region.height)
        let N = CGFloat(m.side)
        let toModel = CGAffineTransform(translationX: -ciRegion.minX, y: -ciRegion.minY)
            .concatenating(CGAffineTransform(scaleX: N / ciRegion.width, y: N / ciRegion.height))
        let maskCI = CIImage(cgImage: mask)
        let regionImage = image.transformed(by: toModel).cropped(to: CGRect(x: 0, y: 0, width: N, height: N))
        // Grow the painted area a little so edges and soft shadows go too.
        let regionMask = maskCI.transformed(by: toModel)
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 4])
            .cropped(to: CGRect(x: 0, y: 0, width: N, height: N))

        let filled: CIImage
        switch m {
        case .best: filled = try runLaMa(regionImage, regionMask, side: m.side)
        case .quick: filled = try runMIGAN(regionImage, regionMask, side: m.side)
        }
        let back = filled.transformed(by: toModel.inverted())

        // Only the painted pixels change; a soft edge hides the seam.
        let feather = maskCI.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": max(3, need / 120)])
            .clampedToExtent().applyingGaussianBlur(sigma: max(1.5, Double(need) / 200)).cropped(to: image.extent)
        let f = CIFilter(name: "CIBlendWithMask")!
        f.setValue(back.cropped(to: ciRegion), forKey: kCIInputImageKey)
        f.setValue(image, forKey: kCIInputBackgroundImageKey)
        f.setValue(feather, forKey: kCIInputMaskImageKey)
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    /// Bounding box of the white pixels, top-left based; nil when nothing is painted.
    static func paintedBox(_ mask: CGImage) -> CGRect? {
        let w = mask.width, h = mask.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        bytes.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where p[row + x] > 127 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: Models

    private static let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])

    private static func pixelBuffer(_ img: CIImage, side: Int, format: OSType) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, format, attrs, &pb) == kCVReturnSuccess, let pb else {
            throw EditError.message("Couldn’t prepare the picture for the eraser")
        }
        let space = format == kCVPixelFormatType_OneComponent8 ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: space)
        return pb
    }

    private static func runLaMa(_ image: CIImage, _ mask: CIImage, side: Int) throws -> CIImage {
        let model = try model(.best)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: try pixelBuffer(image, side: side, format: kCVPixelFormatType_32BGRA)),
            "mask": MLFeatureValue(pixelBuffer: try pixelBuffer(mask, side: side, format: kCVPixelFormatType_OneComponent8)),
        ])
        let out = try model.prediction(from: input)
        guard let pb = out.featureValue(for: "output")?.imageBufferValue else { throw EditError.message("The eraser returned nothing") }
        return CIImage(cvPixelBuffer: pb)
    }

    private static func runMIGAN(_ image: CIImage, _ mask: CIImage, side n: Int) throws -> CIImage {
        let model = try model(.quick)
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        var gray = [UInt8](repeating: 0, count: n * n)
        let r = CGRect(x: 0, y: 0, width: n, height: n)
        ctx.render(image, toBitmap: &rgba, rowBytes: n * 4, bounds: r, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        ctx.render(mask, toBitmap: &gray, rowBytes: n, bounds: r, format: .L8, colorSpace: nil)
        let img = try MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
        let msk = try MLMultiArray(shape: [1, 1, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
        let ip = img.dataPointer.bindMemory(to: Float.self, capacity: 3 * n * n)
        let mp = msk.dataPointer.bindMemory(to: Float.self, capacity: n * n)
        let plane = n * n
        for i in 0..<plane {
            ip[i] = Float(rgba[i * 4]); ip[plane + i] = Float(rgba[i * 4 + 1]); ip[2 * plane + i] = Float(rgba[i * 4 + 2])
            mp[i] = gray[i] > 127 ? 0 : 255            // MI-GAN: 255 = keep, 0 = fill
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk]))
        guard let res = out.featureValue(for: "result")?.multiArrayValue else { throw EditError.message("The eraser returned nothing") }
        var px = [UInt8](repeating: 255, count: plane * 4)
        let strides = res.strides.map(\.intValue)
        func at(_ c: Int, _ y: Int, _ x: Int) -> Float {
            let off = c * strides[1] + y * strides[2] + x * strides[3]
            return res.dataType == .float16 ? Float(res.dataPointer.assumingMemoryBound(to: Float16.self)[off])
                                            : res.dataPointer.assumingMemoryBound(to: Float.self)[off]
        }
        for y in 0..<n { for x in 0..<n {
            let o = (y * n + x) * 4
            for c in 0..<3 { px[o + c] = UInt8(max(0, min(255, at(c, y, x).rounded()))) }
        } }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw EditError.message("Couldn’t read the eraser’s result")
        }
        return CIImage(cgImage: cg)
    }

    /// White strokes on black, at the picture's pixel size. Points are 0…1 from the top-left; width is relative to the longer side.
    static func mask(strokes: [(points: [CGPoint], width: CGFloat)], size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        c.setFillColor(gray: 0, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
        c.setStrokeColor(gray: 1, alpha: 1); c.setLineCap(.round); c.setLineJoin(.round)
        let side = CGFloat(max(w, h))
        for s in strokes {
            guard let first = s.points.first else { continue }
            c.setLineWidth(max(2, s.width * side))
            c.beginPath(); c.move(to: CGPoint(x: first.x * CGFloat(w), y: first.y * CGFloat(h)))
            for p in s.points.dropFirst() { c.addLine(to: CGPoint(x: p.x * CGFloat(w), y: p.y * CGFloat(h))) }
            if s.points.count == 1 { c.addLine(to: CGPoint(x: first.x * CGFloat(w) + 0.1, y: first.y * CGFloat(h))) }
            c.strokePath()
        }
        return c.makeImage()
    }
}
