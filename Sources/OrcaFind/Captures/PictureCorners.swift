import AppKit

/// A still of one screen, taken as the capture shortcut comes up (Orca's own windows left out).
/// Pictures are measured on it (how rounded their corners are), and a clicked picture is cut out of it,
/// so nothing waits on a fresh screen grab after the click.
struct ScreenStill: @unchecked Sendable {
    let image: CGImage
    /// The screen, in global AppKit coordinates.
    let frame: NSRect
    let scale: CGFloat

    /// `rect` (global AppKit coordinates) in the still's pixels, top-left origin.
    func pixels(_ rect: NSRect) -> CGRect {
        CGRect(x: (rect.minX - frame.minX) * scale, y: (frame.maxY - rect.maxY) * scale,
               width: rect.width * scale, height: rect.height * scale).integral
    }

    func crop(_ rect: NSRect) -> CGImage? {
        let r = pixels(rect).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return r.isEmpty ? nil : image.cropping(to: r)
    }

    @MainActor static func take(_ screen: NSScreen) async -> ScreenStill? {
        let frame = screen.frame, scale = screen.backingScaleFactor
        guard let image = try? await ScreenGrab.capture(rect: frame, on: screen) else { return nil }
        return ScreenStill(image: image, frame: frame, scale: scale)
    }
}

/// How rounded a picture's corners are on the page, so the glow and the dim follow its real shape.
/// Pages don't say (Accessibility only gives a box), so it's measured on the screen: from each corner,
/// walk in along the diagonal and see how far the page's background reaches before the picture starts.
/// A round corner of radius r leaves r × (1 − 1/√2) of background on the diagonal.
enum PictureCorners {
    /// Points, or nil when it can't tell (every corner the same colour as the page, or off the screen).
    static func radius(of rect: NSRect, in still: ScreenStill) -> CGFloat? {
        let px = still.pixels(rect)
        let cap = min(min(px.width, px.height) / 2, 48 * still.scale)
        let reach = Int((cap * diagonal).rounded(.up)) + 2
        guard reach >= 3 else { return nil }
        let margin = 3, side = reach + margin
        let bounds = CGRect(x: 0, y: 0, width: still.image.width, height: still.image.height)
        var found: [CGFloat] = []
        for (dx, dy) in [(1, 1), (-1, 1), (1, -1), (-1, -1)] {
            let tile = CGRect(x: dx > 0 ? Int(px.minX) - margin : Int(px.maxX) - reach,
                              y: dy > 0 ? Int(px.minY) - margin : Int(px.maxY) - reach,
                              width: side, height: side)
            guard bounds.contains(tile), let rgb = pixels(still.image, tile) else { continue }
            func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                let i = (y * side + x) * 4
                return (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
            }
            // The first pixel inside the picture at this corner, and the page just outside it.
            let cx = dx > 0 ? margin : reach - 1, cy = dy > 0 ? margin : reach - 1
            let page = at(cx - 2 * dx, cy - 2 * dy)
            // The page around the corner has to be one colour, or there's nothing to measure against.
            guard !differs(page, at(cx - 2 * dx, cy)), !differs(page, at(cx, cy - 2 * dy)) else { continue }
            guard let k = (0..<reach).first(where: { differs(at(cx + dx * $0, cy + dy * $0), page) }) else { continue }
            found.append(k == 0 ? 0 : (CGFloat(k) + 0.3) / diagonal / still.scale)
        }
        guard !found.isEmpty else { return nil }
        return found.sorted()[found.count / 2].rounded()
    }

    private static let diagonal: CGFloat = 1 - 1 / 2.squareRoot()

    private static func differs(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) > 28
    }

    /// RGBA bytes of part of the image, top row first.
    private static func pixels(_ image: CGImage, _ r: CGRect) -> [UInt8]? {
        guard let part = image.cropping(to: r), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = Int(r.width), h = Int(r.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
