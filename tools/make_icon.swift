// Renders the Orca Find app icon: an orca's dorsal fin inside a magnifier, over an ocean gradient.
// Usage: swift tools/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body, ~185pt corner radius, centred.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let colors = [NSColor(red: 0.04, green: 0.16, blue: 0.28, alpha: 1).cgColor,
              NSColor(red: 0.03, green: 0.45, blue: 0.56, alpha: 1).cgColor,
              NSColor(red: 0.20, green: 0.74, blue: 0.80, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Waves along the bottom.
func wave(y: CGFloat, amp: CGFloat, phase: CGFloat, alpha: CGFloat) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 100, y: 100))
    p.addLine(to: CGPoint(x: 100, y: y))
    var x: CGFloat = 100
    while x <= 924 {
        p.addLine(to: CGPoint(x: x, y: y + sin((x / 824) * .pi * 2.6 + phase) * amp))
        x += 8
    }
    p.addLine(to: CGPoint(x: 924, y: 100))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    ctx.fillPath()
}
wave(y: 300, amp: 22, phase: 0.4, alpha: 0.10)
wave(y: 250, amp: 16, phase: 2.0, alpha: 0.10)
ctx.restoreGState()

// Magnifier lens + handle.
let center = CGPoint(x: 470, y: 560)
let radius: CGFloat = 215
ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(58)
ctx.move(to: CGPoint(x: center.x + radius * 0.72, y: center.y - radius * 0.72))
ctx.addLine(to: CGPoint(x: 760, y: 270))
ctx.strokePath()

ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.setFillColor(NSColor(red: 0.02, green: 0.10, blue: 0.18, alpha: 0.55).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Orca dorsal fin inside the lens.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - radius + 20, y: center.y - radius + 20, width: (radius - 20) * 2, height: (radius - 20) * 2))
ctx.clip()
let fin = CGMutablePath()
fin.move(to: CGPoint(x: center.x - 150, y: center.y - 95))
fin.addCurve(to: CGPoint(x: center.x + 35, y: center.y + 170),
             control1: CGPoint(x: center.x - 40, y: center.y - 60),
             control2: CGPoint(x: center.x - 30, y: center.y + 120))
fin.addCurve(to: CGPoint(x: center.x + 120, y: center.y - 95),
             control1: CGPoint(x: center.x + 40, y: center.y + 60),
             control2: CGPoint(x: center.x + 60, y: center.y - 50))
fin.closeSubpath()
ctx.addPath(fin)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
// Water line through the lens.
let water = CGMutablePath()
water.move(to: CGPoint(x: center.x - radius, y: center.y - 95))
var wx = center.x - radius
while wx <= center.x + radius {
    water.addLine(to: CGPoint(x: wx, y: center.y - 95 + sin(wx / 34) * 7))
    wx += 6
}
water.addLine(to: CGPoint(x: center.x + radius, y: center.y - radius))
water.addLine(to: CGPoint(x: center.x - radius, y: center.y - radius))
water.closeSubpath()
ctx.addPath(water)
ctx.setFillColor(NSColor(red: 0.13, green: 0.62, blue: 0.72, alpha: 0.95).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.setLineWidth(46)
ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
