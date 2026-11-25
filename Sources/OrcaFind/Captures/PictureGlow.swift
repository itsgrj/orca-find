import AppKit
import QuartzCore

/// The "soft glow" around the picture under the mouse while the capture shortcut is up: a thin rainbow
/// edge that slowly turns, and a blurred halo of the same colours that breathes just outside the picture,
/// like Siri listening, since OrcaFind starts listening the moment you click.
/// The halo is masked to the outside, so the picture itself is never tinted.
/// With Reduce Motion on, the colours stand still and nothing breathes.
@MainActor
final class PictureGlow {
    let root = CALayer()

    private let ringBox = CALayer()
    private let ringMask = CAShapeLayer()
    private let ringColors = PictureGlow.conic()

    private let haloBox = CALayer()       // clips the halo to outside the picture
    private let haloOutside = CAShapeLayer()
    private let haloBlur = CALayer()      // blurs and breathes
    private let haloRing = CALayer()
    private let haloRingMask = CAShapeLayer()
    private let haloColors = PictureGlow.conic()

    private var shown: NSRect?
    private var shownRadius: CGFloat = 0
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    static let edge: CGFloat = 3        // outline gap from the picture
    static let haloReach: CGFloat = 44  // how far the halo layer extends past the outline

    init() {
        root.isHidden = true
        root.opacity = 0

        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = 3
        ringBox.mask = ringMask
        ringBox.addSublayer(ringColors)

        haloRingMask.fillColor = nil
        haloRingMask.strokeColor = NSColor.black.cgColor
        haloRingMask.lineWidth = 22
        haloRing.mask = haloRingMask
        haloRing.addSublayer(haloColors)
        haloBlur.addSublayer(haloRing)
        haloBlur.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 16]) as Any].compactMap { $0 }
        haloBlur.masksToBounds = false
        haloOutside.fillRule = .evenOdd
        haloOutside.fillColor = NSColor.black.cgColor
        haloBox.mask = haloOutside
        haloBox.addSublayer(haloBlur)

        root.addSublayer(haloBox)
        root.addSublayer(ringBox)
    }

    /// Rainbow sweep: blue, violet, pink, amber, cyan, back to blue.
    private static func conic() -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .conic
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        g.colors = [0x4F8CFF, 0xB46BFF, 0xFF7AA8, 0xFFB35C, 0x4FD1FF, 0x4F8CFF].map { NSColor(hex: UInt32($0)).cgColor }
        return g
    }

    /// `rect`: the picture in the host layer's coordinates, or nil to hide.
    /// `radius`: how rounded the picture's own corners are; the edge runs around them at the same curve.
    func show(_ rect: NSRect?, radius: CGFloat = 0) {
        guard rect != shown || radius != shownRadius else { return }
        let wasHidden = shown == nil
        shown = rect
        shownRadius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let rect else {
            root.isHidden = true
            root.opacity = 0
            root.removeAllAnimations()
            return
        }
        layout(rect, radius: radius)
        root.isHidden = false
        root.opacity = 1
        if wasHidden { appear() }
    }

    private func layout(_ rect: NSRect, radius: CGFloat) {
        let outline = rect.insetBy(dx: -Self.edge, dy: -Self.edge)
        // Same centre as the picture's corner, so the gap between picture and edge stays even all round.
        let corner = min(radius + Self.edge, min(outline.width, outline.height) / 2)
        let side = hypot(outline.width, outline.height) + 2 * Self.haloReach

        // Edge
        ringBox.frame = outline.insetBy(dx: -4, dy: -4)
        let ringLocal = outline.offsetBy(dx: -ringBox.frame.minX, dy: -ringBox.frame.minY)
        ringMask.frame = ringBox.bounds
        ringMask.path = CGPath(roundedRect: ringLocal, cornerWidth: corner, cornerHeight: corner, transform: nil)
        square(ringColors, side: side, in: ringBox.bounds)

        // Halo, outside the picture only
        haloBox.frame = outline.insetBy(dx: -Self.haloReach, dy: -Self.haloReach)
        let haloLocal = outline.offsetBy(dx: -haloBox.frame.minX, dy: -haloBox.frame.minY)
        let outside = CGMutablePath()
        outside.addRect(haloBox.bounds)
        outside.addPath(CGPath(roundedRect: haloLocal, cornerWidth: corner, cornerHeight: corner, transform: nil))
        haloOutside.frame = haloBox.bounds
        haloOutside.path = outside
        haloBlur.frame = haloBox.bounds
        haloRing.frame = haloBox.bounds
        haloRingMask.frame = haloRing.bounds
        haloRingMask.path = CGPath(roundedRect: haloLocal, cornerWidth: corner, cornerHeight: corner, transform: nil)
        square(haloColors, side: side, in: haloRing.bounds)

        if !reduceMotion { spin() }
    }

    /// The gradient is a square bigger than the picture's diagonal, so turning it never shows a corner.
    private func square(_ g: CAGradientLayer, side: CGFloat, in bounds: CGRect) {
        g.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        g.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func spin() {
        for g in [ringColors, haloColors] where g.animation(forKey: "spin") == nil {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = 6
            a.repeatCount = .infinity
            g.add(a, forKey: "spin")
        }
        if haloBlur.animation(forKey: "breathe") == nil {
            let b = CABasicAnimation(keyPath: "opacity")
            b.fromValue = 1.0
            b.toValue = 0.55
            b.duration = 1.5
            b.autoreverses = true
            b.repeatCount = .infinity
            b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            haloBlur.add(b, forKey: "breathe")
        }
    }

    /// Fades in while the edge settles from slightly larger, with a small spring.
    private func appear() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(fade, forKey: "appear")
        guard !reduceMotion else { return }
        let settle = CASpringAnimation(keyPath: "transform.scale")
        settle.fromValue = 1.04
        settle.toValue = 1
        settle.mass = 1
        settle.stiffness = 420
        settle.damping = 26
        settle.duration = settle.settlingDuration
        ringBox.add(settle, forKey: "settle")
        haloBox.add(settle, forKey: "settle")
    }
}
