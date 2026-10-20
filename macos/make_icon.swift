// Draws the app icon (an SVG logo on a white rounded square) as a 1024px PNG.
// Usage: swift make_icon.swift <logo.svg> <output.png>

import Cocoa

let size: CGFloat = 1024
let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: swift make_icon.swift <logo.svg> <output.png>\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// macOS icon grid: 824px body centred in 1024 with ~185px corner radius
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// The SVG is a 16×16 canvas whose artwork spans x 1–16, y 2–13 (15×11 units).
// Scale that artwork to ~560px wide and centre it optically on the body.
let unit: CGFloat = 560 / 15
let canvas = 16 * unit
let artCenter = NSPoint(x: 8.5 * unit, y: (16 - 7.5) * unit)  // centre of the artwork, in flipped-to-AppKit coordinates
let origin = NSPoint(x: body.midX - artCenter.x, y: body.midY - artCenter.y)
logo.draw(in: NSRect(x: origin.x, y: origin.y, width: canvas, height: canvas),
          from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
