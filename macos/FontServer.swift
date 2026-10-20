// The Mac app's built-in server: a Swift port of fontmanager.py, so the app needs no Python.
// It serves index.html and the same JSON API on 127.0.0.1, and reads and writes the same
// data files, so the app and the terminal version share installed fonts and favorites.

import Foundation
import Network

struct FMError: Error { let message: String }

final class FontServer {
    let port: UInt16
    let indexHTML: String
    let token: String
    var onReady: (() -> Void)?
    var onFailed: ((Error) -> Void)?

    // Honour $HOME like the Python version does (handy for testing against a scratch folder).
    private let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    private lazy var dataDir = home.appendingPathComponent("Library/Application Support/FontManager")
    private lazy var fontDir = home.appendingPathComponent("Library/Fonts")
    private lazy var catalogFile = dataDir.appendingPathComponent("catalog.json")
    private lazy var fontshareFile = dataDir.appendingPathComponent("fontshare.json")
    private lazy var stateFile = dataDir.appendingPathComponent("state.json")

    private let catalogURL = "https://fonts.google.com/metadata/fonts"
    private let fontshareURL = "https://api.fontshare.com/v2/fonts?limit=500"
    private let fontshareDownloadURL = "https://api.fontshare.com/v2/fonts/download/"
    private let downloadListURL = "https://fonts.google.com/download/list?family="
    private let catalogMaxAge: TimeInterval = 24 * 3600

    private let lock = NSLock()  // guards the state file and the cached catalog
    private var catalog: [String: Any]?
    private let startup = DispatchGroup()  // API requests wait for the launch-time new-font check
    private let queue = DispatchQueue(label: "fontserver", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?

    init(port: UInt16, indexHTML: String) {
        self.port = port
        self.indexHTML = indexHTML
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() throws {
        startup.enter()
        queue.async {
            self.checkForNewFonts()
            self.startup.leave()
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed(let error): self?.onFailed?(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
        log("Ligatures serving on http://127.0.0.1:\(port)/  (fonts install to \(fontDir.path))")
    }

    func stop() { listener?.cancel() }

    // MARK: - HTTP

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]  // lower-cased names
        let body: Data
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, Data())
    }

    private func receive(_ conn: NWConnection, _ soFar: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = soFar
            if let data { buffer.append(data) }
            if let request = self.parse(buffer) {
                self.respond(conn, to: request)
            } else if done || error != nil || buffer.count > 1_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer)
            }
        }
    }

    /// Returns a request once the headers and the whole body have arrived, otherwise nil.
    private func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let target = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: target?.path ?? "/", query: query, headers: headers,
                       body: data[bodyStart..<(bodyStart + length)])
    }

    private func send(_ conn: NWConnection, status: Int, type: String, body: Data) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendJSON(_ conn: NWConnection, _ object: Any, status: Int = 200) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(conn, status: status, type: "application/json", body: body)
    }

    private func respond(_ conn: NWConnection, to req: Request) {
        // Reject other Host names (blocks DNS-rebinding pages pretending to be localhost).
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(req.headers["host"] ?? "") else {
            return send(conn, status: 403, type: "text/plain", body: Data("Forbidden".utf8))
        }
        do {
            if req.method == "GET" {
                switch req.path {
                case "/", "/index.html":
                    send(conn, status: 200, type: "text/html; charset=utf-8",
                         body: Data(indexHTML.replacingOccurrences(of: "__FM_TOKEN__", with: token).utf8))
                case "/api/catalog":
                    startup.wait()
                    sendJSON(conn, try getCatalog(force: req.query["refresh"] != nil))
                case "/api/state":
                    startup.wait()
                    let state = loadState()
                    sendJSON(conn, ["installed": installedSummary(state), "favorites": state["favorites"] ?? [],
                                    "newFamilies": state["newFamilies"] ?? [:], "lastCheck": state["lastCheck"] ?? NSNull(),
                                    "fontDir": fontDir.path, "system": "Darwin"])
                default:
                    send(conn, status: 404, type: "text/plain", body: Data("Not Found".utf8))
                }
                return
            }
            guard req.method == "POST", req.headers["x-fm-token"] == token else {
                return send(conn, status: 403, type: "text/plain", body: Data("Forbidden".utf8))
            }
            startup.wait()
            let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            let family = payload["family"] as? String ?? ""
            if ["/api/install", "/api/uninstall", "/api/favorite"].contains(req.path), !(try familyNames()).contains(family) {
                return sendJSON(conn, ["error": "Unknown family"], status: 400)
            }
            switch req.path {
            case "/api/install":
                sendJSON(conn, try install(family))
            case "/api/uninstall":
                sendJSON(conn, try uninstall(family))
            case "/api/favorite":
                lock.lock()
                var state = loadState()
                var favorites = (state["favorites"] as? [String] ?? []).filter { $0 != family }
                if (payload["on"] as? Bool) == true { favorites.append(family) }
                state["favorites"] = favorites
                saveState(state)
                lock.unlock()
                sendJSON(conn, ["favorites": favorites])
            case "/api/new/clear":
                lock.lock()
                var state = loadState()
                state["newFamilies"] = [String: Any]()
                saveState(state)
                lock.unlock()
                sendJSON(conn, ["newFamilies": [String: Any]()])
            default:
                send(conn, status: 404, type: "text/plain", body: Data("Not Found".utf8))
            }
        } catch let error as FMError {
            sendJSON(conn, ["error": error.message], status: 500)
        } catch {
            sendJSON(conn, ["error": error.localizedDescription], status: 500)
        }
    }

    // MARK: - Storage

    private func loadState() -> [String: Any] {
        var state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        if state["installed"] as? [String: Any] == nil { state["installed"] = [String: Any]() }
        if state["favorites"] as? [String] == nil { state["favorites"] = [String]() }
        return state
    }

    private func saveState(_ state: [String: Any]) {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    private func fetch(_ url: String, timeout: TimeInterval = 60) throws -> Data {
        guard let u = URL(string: url) else { throw FMError(message: "Bad URL: \(url)") }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        request.setValue("FontManager/1.0", forHTTPHeaderField: "User-Agent")
        var result: Result<Data, Error> = .failure(FMError(message: "No response from \(u.host ?? url)"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(FMError(message: "HTTP Error \(http.statusCode) from \(u.host ?? url)"))
            } else if let data {
                result = .success(data)
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    /// Google prefixes some JSON responses with )]}' to block script inclusion.
    private func stripXSSI(_ data: Data) -> Data {
        guard data.starts(with: Data(")]}'".utf8)), let newline = data.firstIndex(of: 0x0A) else { return data }
        return data[(newline + 1)...]
    }

    private func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FMError(message: "Unexpected response from Google Fonts")
        }
        return object
    }

    // MARK: - Catalog

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func isFresh(_ url: URL) -> Bool {
        modified(url).map { Date().timeIntervalSince($0) < catalogMaxAge } ?? false
    }

    /// Downloads url into file unless a fresh copy exists; falls back to a stale copy when offline.
    private func cachedJSON(_ url: String, _ file: URL, force: Bool) throws -> [String: Any] {
        if force || !isFresh(file) {
            do {
                let data = stripXSSI(try fetch(url))
                _ = try json(data)  // only cache valid JSON
                try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw FMError(message: "Could not download \(url): \(describe(error))")
                }
                log("Refresh of \(file.lastPathComponent) failed, using cached copy: \(describe(error))")
            }
        }
        return try json(Data(contentsOf: file))
    }

    /// Trimmed family metadata from Google Fonts and Fontshare, cached on disk for a day.
    private func getCatalog(force: Bool = false) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let catalog, isFresh(catalogFile), isFresh(fontshareFile), !force { return catalog }
        let google: [String: Any]
        do { google = try cachedJSON(catalogURL, catalogFile, force: force) } catch {
            throw FMError(message: "Could not download the Google Fonts catalog: \(describe(error))")
        }
        let keep = ["family", "category", "subsets", "designers", "dateAdded", "lastModified",
                    "popularity", "trending", "isNoto", "colorCapabilities"]
        var families: [[String: Any]] = (google["familyMetadataList"] as? [[String: Any]] ?? []).map { f in
            var item: [String: Any] = [:]
            for key in keep { item[key] = f[key] ?? NSNull() }
            item["variants"] = ((f["fonts"] as? [String: Any])?.keys).map { $0.sorted(by: variantOrder) } ?? []
            item["axes"] = (f["axes"] as? [[String: Any]] ?? []).map { a in
                ["tag": a["tag"] ?? "", "min": a["min"] ?? 0, "max": a["max"] ?? 0]
            }
            item["source"] = "google"
            return item
        }
        do {  // Fontshare is optional: carry on with Google Fonts alone if it's unreachable
            let taken = Set(families.compactMap { $0["family"] as? String })
            families += fontshareFamilies(try cachedJSON(fontshareURL, fontshareFile, force: force), taken: taken)
        } catch {
            log("Fontshare unavailable: \(describe(error))")
        }
        let result: [String: Any] = ["families": families,
                                     "updated": modified(catalogFile)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970]
        catalog = result
        return result
    }

    private let fontshareCategories = ["sans": "Sans Serif", "serif": "Serif", "slab": "Serif", "display": "Display",
                                       "handwritten": "Handwriting", "script": "Handwriting", "mono": "Monospace"]
    private let fontshareLicenses = ["itf_ffl": "ITF Free Font License", "sil_ofl": "SIL Open Font License"]

    /// Maps Fontshare's font list onto the Google-style family records the page uses.
    /// Families Google Fonts already has (open-source fonts Fontshare mirrors) are skipped, so each
    /// family appears once. Popularity ranks are scaled to Google's range so mixed sorting interleaves.
    private func fontshareFamilies(_ data: [String: Any], taken: Set<String>) -> [[String: Any]] {
        let fonts = (data["fonts"] as? [[String: Any]] ?? []).filter {
            guard let name = $0["name"] as? String, $0["slug"] is String else { return false }
            return !taken.contains(name)
        }
        let scale = Double(max(taken.count, 1)) / Double(max(fonts.count, 1))
        func ranks(_ key: String) -> [String: Int] {
            let sorted = fonts.sorted { ($0[key] as? Int ?? 0) > ($1[key] as? Int ?? 0) }
            return Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1["slug"] as! String, $0 + 1) })
        }
        let popular = ranks("views"), trending = ranks("views_recent")
        var out: [[String: Any]] = []
        for f in fonts {
            let slug = f["slug"] as! String
            var faces: [String: Any] = [:]
            for style in f["styles"] as? [[String: Any]] ?? [] {
                // static styles only: these are what gets installed
                guard (style["is_variable"] as? Bool) != true, var file = style["file"] as? String,
                      let weightInfo = style["weight"] as? [String: Any], let weight = weightInfo["weight"] as? Int else { continue }
                let variant = "\(weight)" + ((style["is_italic"] as? Bool) == true ? "i" : "")
                if file.hasPrefix("//") { file = "https:" + file }
                if faces[variant] == nil { faces[variant] = ["url": file + ".woff2", "number": weightInfo["number"] as? Int ?? weight] }
            }
            if faces.isEmpty { continue }
            let first = ((f["category"] as? String ?? "").split(separator: ",").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            var designers = (f["designers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if designers.isEmpty { designers = [((f["publisher"] as? [String: Any])?["name"] as? String) ?? "Indian Type Foundry"] }
            let added = (f["inserted_at"] as? String).map { String($0.prefix(10)) }
            let license = f["license_type"] as? String ?? ""
            out.append([
                "family": f["name"] as! String, "category": fontshareCategories[first] ?? "Display",
                "subsets": [f["script"] as? String ?? "latin"], "designers": designers,
                "dateAdded": added ?? NSNull(), "lastModified": NSNull(),
                "popularity": Int((Double(popular[slug] ?? 0) * scale).rounded()),
                "trending": Int((Double(trending[slug] ?? 0) * scale).rounded()),
                "isNoto": false, "colorCapabilities": [String](),
                "variants": faces.keys.sorted(by: variantOrder), "axes": [[String: Any]](),
                "source": "fontshare", "slug": slug, "faces": faces,
                "license": fontshareLicenses[license] ?? license,
                "link": "https://www.fontshare.com/fonts/" + slug,
            ])
        }
        return out
    }

    /// Upright before italic, then by weight ("400", "700", "400i", …).
    private func variantOrder(_ a: String, _ b: String) -> Bool {
        func key(_ v: String) -> (Int, Int) {
            let italic = v.hasSuffix("i")
            let weight = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "i"))) ?? 400
            return (italic ? 1 : 0, weight)
        }
        return key(a) < key(b)
    }

    /// Refreshes the catalog and records families that weren't there on the previous launch.
    /// Each library is tracked separately, so a library seen for the first time (e.g. Fontshare
    /// after an update) is recorded silently instead of flagging everything in it as new.
    private func checkForNewFonts() {
        log("Checking for new fonts…")
        let families: [[String: Any]]
        do { families = try getCatalog(force: true)["families"] as? [[String: Any]] ?? [] } catch {
            log("Could not check for new fonts: \(describe(error))")
            return
        }
        var bySource: [String: Set<String>] = [:]
        for f in families {
            guard let name = f["family"] as? String else { continue }
            bySource[f["source"] as? String ?? "google", default: []].insert(name)
        }
        lock.lock()
        var state = loadState()
        var knownBy = state["knownBySource"] as? [String: [String]] ?? [:]
        if knownBy.isEmpty, let legacy = state["knownFamilies"] as? [String], !legacy.isEmpty {
            knownBy = ["google": legacy]  // data from before libraries were tracked
        }
        var new: [String] = []
        for (source, names) in bySource.sorted(by: { $0.key < $1.key }) {
            let known = Set(knownBy[source] ?? [])
            if !known.isEmpty { new += names.subtracting(known).sorted() }
            knownBy[source] = names.sorted()
        }
        let everything = bySource.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var found = state["newFamilies"] as? [String: Any] ?? [:]
        let now = Date().timeIntervalSince1970
        for family in new where found[family] == nil { found[family] = now }
        state["newFamilies"] = found.filter { everything.contains($0.key) }
        state["knownBySource"] = knownBy
        state["knownFamilies"] = nil
        state["lastCheck"] = ["at": now, "found": new]
        saveState(state)
        lock.unlock()
        log(new.isEmpty ? "No new fonts since last launch"
            : "\(new.count) new font famil\(new.count == 1 ? "y" : "ies") since last launch: \(new.prefix(10).joined(separator: ", "))")
    }

    private func familyNames(forceRefresh: Bool = false) throws -> Set<String> {
        Set((try getCatalog(force: forceRefresh)["families"] as? [[String: Any]] ?? []).compactMap { $0["family"] as? String })
    }

    private func findFamily(_ family: String) throws -> [String: Any]? {
        (try getCatalog()["families"] as? [[String: Any]] ?? []).first { ($0["family"] as? String) == family }
    }

    // MARK: - Install / uninstall

    private func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// (filename, loader) pairs for a Google Fonts family.
    private func googleFontFiles(_ family: String) throws -> [(String, () throws -> Data)] {
        let manifest = try json(stripXSSI(try fetch(downloadListURL + percentEncoded(family))))["manifest"] as? [String: Any] ?? [:]
        var refs = (manifest["fileRefs"] as? [[String: Any]] ?? []).filter {
            let name = ($0["filename"] as? String ?? "").lowercased()
            return name.hasSuffix(".ttf") || name.hasSuffix(".otf")
        }
        // Variable families ship both a variable file and static instances; installing both
        // creates duplicate entries in font menus, so prefer the static files when they exist.
        let statics = refs.filter { ($0["filename"] as? String ?? "").hasPrefix("static/") }
        if !statics.isEmpty { refs = statics }
        return refs.compactMap { ref in
            guard let filename = ref["filename"] as? String, let url = ref["url"] as? String else { return nil }
            return ((filename as NSString).lastPathComponent, { try self.fetch(url) })
        }
    }

    /// Chooses what to install from a Fontshare zip: static OTFs, else static TTFs (never web or variable files).
    private func pickFontshareFiles(_ paths: [String]) -> [String] {
        let fonts = paths.filter {
            let p = $0.lowercased()
            return (p.hasSuffix(".otf") || p.hasSuffix(".ttf")) && !p.contains("/web/") && !p.contains("__macosx")
        }
        let statics = fonts.filter { !(($0 as NSString).lastPathComponent.lowercased().contains("variable")) }
        let otf = statics.filter { $0.lowercased().hasSuffix(".otf") }
        return !otf.isEmpty ? otf : (!statics.isEmpty ? statics : fonts)
    }

    /// (filename, loader) pairs for a Fontshare family, unpacked from its download zip with ditto.
    private func fontshareFontFiles(_ slug: String) throws -> (files: [(String, () throws -> Data)], cleanup: () -> Void) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ligatures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let cleanup: () -> Void = { _ = try? FileManager.default.removeItem(at: work) }
        do {
            let zip = work.appendingPathComponent("font.zip")
            try fetch(fontshareDownloadURL + percentEncoded(slug), timeout: 120).write(to: zip)
            let unpacked = work.appendingPathComponent("unpacked")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw FMError(message: "Couldn't unpack the \(slug) download") }
            let base = unpacked.path + "/"
            let all = (FileManager.default.enumerator(atPath: unpacked.path)?.allObjects as? [String] ?? []).map { "/" + $0 }
            let files: [(String, () throws -> Data)] = pickFontshareFiles(all).map { rel in
                ((rel as NSString).lastPathComponent, { try Data(contentsOf: URL(fileURLWithPath: base + rel.dropFirst())) })
            }
            return (files, cleanup)
        } catch {
            cleanup()
            throw error
        }
    }

    private func install(_ family: String) throws -> [String: Any] {
        let entry = try findFamily(family) ?? [:]
        var files: [(String, () throws -> Data)]
        var cleanup: () -> Void = {}
        if entry["source"] as? String == "fontshare", let slug = entry["slug"] as? String {
            (files, cleanup) = try fontshareFontFiles(slug)
        } else {
            files = try googleFontFiles(family)
        }
        defer { cleanup() }
        if files.isEmpty { throw FMError(message: "No font files found for \(family)") }

        lock.lock()
        let owned = Set((loadState()["installed"] as? [String: [String: Any]] ?? [:]).values.flatMap { $0["files"] as? [String] ?? [] })
        lock.unlock()
        try FileManager.default.createDirectory(at: fontDir, withIntermediateDirectories: true)
        var written: [String] = [], skipped: [String] = []
        for (name, load) in files {
            let dest = fontDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path), !owned.contains(dest.path) {
                skipped.append(dest.lastPathComponent)  // installed by something else; leave it alone
                continue
            }
            try load().write(to: dest, options: .atomic)
            written.append(dest.path)
        }

        lock.lock()
        var state = loadState()
        var installed = state["installed"] as? [String: Any] ?? [:]
        installed[family] = ["files": written, "skipped": skipped, "installedAt": Date().timeIntervalSince1970]
        state["installed"] = installed
        saveState(state)
        lock.unlock()
        return ["family": family, "files": written.count, "skipped": skipped]
    }

    /// Moves files to the Trash. Returns where they went ("Trash" or a folder path).
    private func moveToTrash(_ paths: [URL]) -> String {
        var left: [URL] = []
        for path in paths {
            do { try FileManager.default.trashItem(at: path, resultingItemURL: nil) } catch {
                log("Could not move \(path.lastPathComponent) to the Trash: \(describe(error))")
                left.append(path)
            }
        }
        if left.isEmpty { return "Trash" }
        // Fallback: keep the files in a recoverable folder.
        let aside = dataDir.appendingPathComponent("Removed Fonts")
        try? FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for path in left {
            var target = aside.appendingPathComponent(path.lastPathComponent)
            var n = 1
            while FileManager.default.fileExists(atPath: target.path) {
                let stem = path.deletingPathExtension().lastPathComponent
                target = aside.appendingPathComponent("\(stem) \(n).\(path.pathExtension)")
                n += 1
            }
            try? FileManager.default.moveItem(at: path, to: target)
        }
        return aside.path
    }

    private func uninstall(_ family: String) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var state = loadState()
        var installed = state["installed"] as? [String: Any] ?? [:]
        guard let info = installed[family] as? [String: Any] else {
            throw FMError(message: "\(family) was not installed by Ligatures")
        }
        let paths = (info["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
                && $0.deletingLastPathComponent().standardizedFileURL.path == fontDir.standardizedFileURL.path
        }
        let movedTo = moveToTrash(paths)
        let stillThere = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let first = stillThere.first {
            throw FMError(message: "Could not remove \(stillThere.count) file(s), e.g. \(first.path)")
        }
        installed[family] = nil
        state["installed"] = installed
        saveState(state)
        return ["family": family, "removed": paths.count, "movedTo": movedTo]
    }

    private func installedSummary(_ state: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (family, value) in state["installed"] as? [String: Any] ?? [:] {
            let info = value as? [String: Any] ?? [:]
            let files = info["files"] as? [String] ?? []
            let present = files.filter { FileManager.default.fileExists(atPath: $0) }.count
            out[family] = ["files": present, "missing": files.count - present, "installedAt": info["installedAt"] ?? NSNull()]
        }
        return out
    }

    // MARK: - Logging

    private func describe(_ error: Error) -> String {
        (error as? FMError)?.message ?? error.localizedDescription
    }

    private lazy var logURL = home.appendingPathComponent("Library/Logs/FontManager.log")
    private let logLock = NSLock()

    func log(_ message: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let line = Data((ISO8601DateFormatter().string(from: Date()) + "  " + message + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            handle.closeFile()
        } else {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: logURL)
        }
    }
}
