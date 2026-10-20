// Ligatures.app: a native window around the font manager.
// Runs the built-in FontServer (a Swift port of fontmanager.py) on a private port and
// shows it in a WKWebView. Needs nothing else installed: no Python, no developer tools.

import Cocoa
import WebKit

let port = 8766  // fixed so the web view's saved preferences survive relaunches; 8765 is left for terminal use

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var server: FontServer?
    var status: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    // MARK: - Server

    func startServer() {
        if portIsOpen() {
            // Another copy of the app is already serving on our port: just use it.
            loadPage()
            return
        }
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            showError("The app is missing its index.html. Try reinstalling Ligatures.")
            return
        }
        let server = FontServer(port: UInt16(port), indexHTML: html)
        server.onReady = { [weak self] in DispatchQueue.main.async { self?.loadPage() } }
        server.onFailed = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.portIsOpen() { self.loadPage(); return }
                self.showError("Couldn't start the font server: \(error.localizedDescription)\nDetails are in ~/Library/Logs/FontManager.log")
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            showError("Couldn't start the font server: \(error.localizedDescription)")
        }
    }

    func portIsOpen() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    func loadPage() {
        status.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
    }

    func showError(_ message: String) {
        webView.isHidden = true
        status.isHidden = false
        status.stringValue = message
    }

    // MARK: - Window

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Ligatures"
        window.minSize = NSSize(width: 420, height: 400)
        window.setFrameAutosaveName("FontManagerMainWindow")
        if !window.setFrameUsingName("FontManagerMainWindow") { window.center() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // keeps preferences (layout, preview text, …) between launches
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isHidden = true
        webView.setValue(false, forKey: "drawsBackground")  // no white flash before the page paints

        status = NSTextField(wrappingLabelWithString: "Checking Google Fonts for new families…")
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 14)
        status.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(webView)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Links that leave the app (e.g. "Open on Google Fonts") open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.host != "127.0.0.1", navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    @objc func reloadPage(_ sender: Any?) { webView.reload() }

    // MARK: - About

    static let projectURL = URL(string: "https://github.com/khanh-ly/Ligatures")!

    var aboutWindow: NSWindow?

    /// A custom About window (the standard panel can't hold a button): icon, name, version,
    /// description, a button to the GitHub project, and the copyright line.
    @objc func showAbout(_ sender: Any?) {
        if aboutWindow == nil { aboutWindow = makeAboutWindow() }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeAboutWindow() -> NSWindow {
        let info = Bundle.main.infoDictionary ?? [:]
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.alignment = .center
            field.isSelectable = false
            field.preferredMaxLayoutWidth = 240
            return field
        }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 96), icon.heightAnchor.constraint(equalToConstant: 96)])

        let button = NSButton(title: "Ligatures on Github", target: self, action: #selector(openProjectPage(_:)))
        button.bezelStyle = .rounded
        button.toolTip = AppDelegate.projectURL.absoluteString

        let stack = NSStackView(views: [
            icon,
            label("Ligatures", size: 18, weight: .bold),
            label("Version \(info["CFBundleShortVersionString"] as? String ?? "1.0")", size: 11, color: .secondaryLabelColor),
            label("The free fonts manager.", size: 12, weight: .semibold),
            label("Browse and install Google Fonts and Fontshare families on your Mac.", size: 11, color: .secondaryLabelColor),
            button,
            label(info["NSHumanReadableCopyright"] as? String ?? "", size: 10, color: .tertiaryLabelColor),
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(12, after: stack.views[2])  // version → tagline
        stack.setCustomSpacing(16, after: stack.views[4])  // description → button
        stack.setCustomSpacing(14, after: button)
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 24, bottom: 20, right: 24)  // top clears the transparent title bar
        stack.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = stack
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalToConstant: 288)])
        window.setContentSize(stack.fittingSize)
        return window
    }

    @objc func openProjectPage(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.projectURL) }

    // MARK: - Menu

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ligatures", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ligatures", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ligatures", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Ligatures on GitHub", action: #selector(openProjectPage(_:)), keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
