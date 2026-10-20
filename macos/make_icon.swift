// Draws the app icon as a 1024px PNG: a monoline "fi" ligature on a charcoal tile.
// The f's crossbar flows into the i's stem, and the f's hook stands in for the i's dot.
// Usage: swift make_icon.swift <output.png>

import Cocoa

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Work top-down (y grows downwards) so the coordinates below read like a design file.
let flip = NSAffineTransform()
flip.translateX(by: 0, yBy: size)
flip.scaleX(by: 1, yBy: -1)
flip.concat()

// macOS icon grid: 824px body centred in 1024 with ~185px corner radius
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)  // shadow offsets ignore the flip: negative y points down
shadow.set()
rgb(0x1C1C1E).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

// A barely-there top-to-bottom sheen and a hairline inner edge keep the dark tile from looking flat.
NSGradient(starting: rgb(0x2A2A2D), ending: rgb(0x161618))!.draw(in: tile, angle: 90)
NSColor.white.withAlphaComponent(0.06).setStroke()
let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 183.5, yRadius: 183.5)
edge.lineWidth = 3
edge.stroke()

// The glyph: one monoline stroke with round caps and joins.
let stroke: CGFloat = 54
let baseline: CGFloat = 744
let crossbar: CGFloat = 452       // x-height: the crossbar and the top of the i
let hookTop: CGFloat = 288        // top of the f's hook, which doubles as the i's dot
let fStem: CGFloat = 430
let iStem: CGFloat = 614
let hookRadius: CGFloat = 112
let dx: CGFloat = 28, dy: CGFloat = -6  // optical centring on the tile

let f = NSBezierPath()
f.move(to: NSPoint(x: fStem + dx, y: baseline + dy))
f.line(to: NSPoint(x: fStem + dx, y: hookTop + hookRadius + dy))
// Quarter turn from the stem into the hook
f.appendArc(withCenter: NSPoint(x: fStem + hookRadius + dx, y: hookTop + hookRadius + dy), radius: hookRadius,
            startAngle: 180, endAngle: 270, clockwise: false)
f.line(to: NSPoint(x: iStem + dx, y: hookTop + dy))

let bar = NSBezierPath()
bar.move(to: NSPoint(x: fStem - 84 + dx, y: crossbar + dy))
bar.line(to: NSPoint(x: iStem + dx, y: crossbar + dy))
bar.line(to: NSPoint(x: iStem + dx, y: baseline + dy))

rgb(0xF2EEE6).setStroke()
for path in [f, bar] {
    path.lineWidth = stroke
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
