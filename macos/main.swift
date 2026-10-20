// Ligatures.app: a native window around the local font manager.
// Starts fontmanager.py (bundled in Resources) on a private port, shows it in a
// WKWebView, and stops the server when the app quits.

import Cocoa
import WebKit

let port = 8766  // fixed so the web view's saved preferences survive relaunches; 8765 is left for terminal use

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var server: Process?
    var status: NSTextField!
    var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        if let server, server.isRunning {
            server.interrupt()  // SIGINT: lets Python finish cleanly
            server.waitUntilExit()
        }
    }

    // MARK: - Server

    func startServer() {
        guard let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("fontmanager.py").path

        if portIsOpen() {
            // Something already listens on our port (e.g. a second copy of the app): just use it.
            loadPage()
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script, "--no-browser", "--exit-with-parent"]
        p.currentDirectoryURL = resources
        var env = ProcessInfo.processInfo.environment
        env["FONTMANAGER_PORT"] = String(port)
        env["PYTHONDONTWRITEBYTECODE"] = "1"  // don't write into the signed app bundle
        p.environment = env

        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("FontManager.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.quitting else { return }
                self.showError("The font server stopped unexpectedly (exit code \(proc.terminationStatus)).\nDetails are in ~/Library/Logs/FontManager.log")
            }
        }
        do {
            try p.run()
            server = p
        } catch {
            showError("Couldn't start Python: \(error.localizedDescription)\nLigatures needs /usr/bin/python3 (Xcode Command Line Tools).")
            return
        }
        waitForServer(attempt: 0)
    }

    func waitForServer(attempt: Int) {
        if portIsOpen() { loadPage(); return }
        if attempt > 150 { showError("The font server didn't start in time.\nDetails are in ~/Library/Logs/FontManager.log"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForServer(attempt: attempt + 1) }
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

    // MARK: - Menu

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ligatures", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
