// Draws Seek's app icon (1024×1024 PNG). Run: swift Tools/make-icon.swift out.png
// build.sh turns it into Resources/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, a])!
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray,
               locations: stops.map { $0.2 })!
}

// macOS icon grid: 824 pt tile centred in 1024, continuous corners.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x1A1446))
ctx.fillPath()
ctx.restoreGState()

// Background: deep indigo → electric blue → cyan, diagonal.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(gradient([(0x1B1150, 1, 0), (0x3A2FD8, 1, 0.48), (0x22C7E8, 1, 1)]),
                       start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
// Soft glow behind the lens.
ctx.drawRadialGradient(gradient([(0x8FE9FF, 0.55, 0), (0x8FE9FF, 0, 1)]),
                       startCenter: CGPoint(x: 450, y: 580), startRadius: 0,
                       endCenter: CGPoint(x: 450, y: 580), endRadius: 420, options: [])
// Glass sheen across the top.
ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.28, 0), (0xFFFFFF, 0.0, 1)]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY + 40), options: [])
ctx.restoreGState()

// Thin inner rim, like Liquid Glass edges.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.35))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

// Magnifying glass: lens centred up-left, handle to the bottom right.
let lens = CGPoint(x: 452, y: 578)
let radius: CGFloat = 196
let ring: CGFloat = 62

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x0A0630, 0.45))

// Handle.
let angle = -CGFloat.pi / 4
let start = CGPoint(x: lens.x + cos(angle) * (radius + ring / 2 - 6), y: lens.y + sin(angle) * (radius + ring / 2 - 6))
let end = CGPoint(x: lens.x + cos(angle) * (radius + 230), y: lens.y + sin(angle) * (radius + 230))
ctx.setLineCap(.round)
ctx.setLineWidth(92)
ctx.setStrokeColor(color(0xF4F7FF))
ctx.move(to: start); ctx.addLine(to: end)
ctx.strokePath()

// Ring.
ctx.setLineWidth(ring)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.addEllipse(in: CGRect(x: lens.x - radius, y: lens.y - radius, width: radius * 2, height: radius * 2))
ctx.strokePath()
ctx.restoreGState()

// Glass inside the lens.
ctx.saveGState()
let inner = radius - ring / 2
ctx.addEllipse(in: CGRect(x: lens.x - inner, y: lens.y - inner, width: inner * 2, height: inner * 2))
ctx.clip()
ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.30, 0), (0xFFFFFF, 0.06, 0.55), (0xFFFFFF, 0.14, 1)]),
                       start: CGPoint(x: lens.x - inner, y: lens.y + inner), end: CGPoint(x: lens.x + inner, y: lens.y - inner), options: [])
ctx.restoreGState()

// Spark in the lens: a four-point star.
func star(center c: CGPoint, r: CGFloat, waist: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y + waist))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + waist, y: c.y - waist))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y - waist))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - waist, y: c.y + waist))
    p.closeSubpath()
    return p
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: color(0xFFFFFF, 0.9))
ctx.addPath(star(center: CGPoint(x: lens.x, y: lens.y), r: 92, waist: 14))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.addPath(star(center: CGPoint(x: lens.x + 74, y: lens.y + 78), r: 34, waist: 6))
ctx.setFillColor(color(0xDDFBFF))
ctx.fillPath()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
