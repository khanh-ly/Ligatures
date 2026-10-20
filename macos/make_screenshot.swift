// Renders the Ligatures page off-screen with WebKit and frames it as a macOS window mockup
// (title bar, traffic lights, rounded corners, soft shadow) for the README.
// Usually run through make_screenshots.sh, which starts a server with clean data first.
// Usage: make_screenshot <url> <output.png> <light|dark>

import Cocoa
import WebKit

let args = CommandLine.arguments
let pageURL = URL(string: args[1])!
let outPath = args[2]
let dark = args[3] == "dark"
let size = NSSize(width: 1280, height: 800)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

final class Shooter: NSObject, WKNavigationDelegate {
    let window: NSWindow
    let web: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()  // fresh preferences: default grid view, nothing saved
        web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = web
        super.init()
        window.orderBack(nil)
        web.navigationDelegate = self
        web.load(URLRequest(url: pageURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give the catalog time to load, then set a friendly preview sentence and wait for the fonts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let js = """
            const p = document.querySelector('#preview'); p.value = 'Sphinx of black quartz, judge my vow'; p.dispatchEvent(new Event('input'));
            const s = document.querySelector('#size'); s.value = 40; s.dispatchEvent(new Event('input'));
            document.activeElement && document.activeElement.blur(); window.scrollTo(0, 0); true
            """
            webView.evaluateJavaScript(js) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.snap() }
            }
        }
    }

    func snap() {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(origin: .zero, size: size)
        web.takeSnapshot(with: cfg) { image, error in
            guard let image, let content = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!); exit(1)
            }
            self.compose(content)
            exit(0)
        }
    }

    /// Frames the page in a macOS-style window: title bar with traffic lights, rounded corners, soft shadow.
    func compose(_ content: CGImage) {
        let scale = CGFloat(content.width) / size.width       // 2 on a Retina screen
        let titleBar: CGFloat = 28, radius: CGFloat = 12, margin: CGFloat = 56
        let win = NSRect(x: margin, y: margin, width: size.width, height: size.height + titleBar)
        let canvas = NSSize(width: win.width + margin * 2, height: win.height + margin * 2)

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let frame = NSBezierPath(roundedRect: win, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        (dark ? rgb(0x1E1E1E) : rgb(0xF6F6F6)).setFill()
        frame.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        // title bar
        let bar = NSRect(x: win.minX, y: win.maxY - titleBar, width: win.width, height: titleBar)
        (dark ? rgb(0x2A2A2A) : rgb(0xECECEC)).setFill()
        bar.fill()
        for (i, color) in [rgb(0xFF5F57), rgb(0xFEBC2E), rgb(0x28C840)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bar.minX + 14 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
        }
        let title = NSAttributedString(string: "Ligatures", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: dark ? rgb(0xE6E6E6) : rgb(0x3C3C3C)])
        title.draw(at: NSPoint(x: bar.midX - title.size().width / 2, y: bar.midY - title.size().height / 2))
        (dark ? rgb(0x000000, 0.6) : rgb(0x000000, 0.12)).setFill()
        NSRect(x: win.minX, y: bar.minY - 1, width: win.width, height: 1).fill()
        // page
        NSGraphicsContext.current!.cgContext.draw(content, in: NSRect(x: win.minX, y: win.minY, width: size.width, height: size.height - 1))
        NSGraphicsContext.restoreGraphicsState()

        // hairline edge around the window
        (dark ? rgb(0xFFFFFF, 0.12) : rgb(0x000000, 0.14)).setStroke()
        let edge = NSBezierPath(roundedRect: win.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()

        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let shooter = Shooter()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { FileHandle.standardError.write("timed out\n".data(using: .utf8)!); exit(2) }
app.run()
