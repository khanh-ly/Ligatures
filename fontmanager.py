#!/usr/bin/env python3
"""Local font manager: browse Google Fonts and install/uninstall them on this machine.

Run:  python3 fontmanager.py   (then open http://127.0.0.1:8765)
Only the Python standard library is used. Works on macOS and Linux.
"""

import json
import os
import platform
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("FONTMANAGER_PORT", "8765"))
HERE = Path(__file__).resolve().parent
CATALOG_URL = "https://fonts.google.com/metadata/fonts"
DOWNLOAD_LIST_URL = "https://fonts.google.com/download/list?family="
CATALOG_MAX_AGE = 24 * 3600
TOKEN = secrets.token_hex(16)  # required on every write request

SYSTEM = platform.system()
if SYSTEM == "Darwin":
    DATA_DIR = Path.home() / "Library" / "Application Support" / "FontManager"
    FONT_DIR = Path.home() / "Library" / "Fonts"
elif SYSTEM == "Linux":
    DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "fontmanager"
    FONT_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "fonts" / "google-fonts"
else:
    sys.exit("Sorry, only macOS and Linux are supported.")

CATALOG_FILE = DATA_DIR / "catalog.json"
STATE_FILE = DATA_DIR / "state.json"
lock = threading.Lock()


# ---------- storage ----------

def load_state():
    try:
        state = json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        state = {}
    state.setdefault("installed", {})   # family -> {"files": [...], "installedAt": ts}
    state.setdefault("favorites", [])
    return state


def save_state(state):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_FILE)


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "FontManager/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def strip_xssi(raw):
    text = raw.decode("utf-8")
    return text[text.index("\n") + 1:] if text.startswith(")]}'") else text


_catalog = None


def get_catalog(force=False):
    """Return a trimmed list of family metadata, cached on disk for a day."""
    global _catalog
    with lock:
        fresh = CATALOG_FILE.exists() and time.time() - CATALOG_FILE.stat().st_mtime < CATALOG_MAX_AGE
        if _catalog is not None and fresh and not force:
            return _catalog
        if force or not fresh:
            try:
                data = json.loads(strip_xssi(fetch(CATALOG_URL)))
                DATA_DIR.mkdir(parents=True, exist_ok=True)
                CATALOG_FILE.write_text(json.dumps(data))
            except Exception as exc:  # offline: fall back to the stale cache
                if not CATALOG_FILE.exists():
                    raise RuntimeError("Could not download the Google Fonts catalog: %s" % exc)
                print("Catalog refresh failed, using cached copy:", exc)
        data = json.loads(CATALOG_FILE.read_text())
        keep = ("family", "category", "subsets", "designers", "dateAdded", "lastModified",
                "popularity", "trending", "isNoto", "colorCapabilities")
        families = []
        for f in data["familyMetadataList"]:
            item = {k: f.get(k) for k in keep}
            item["variants"] = sorted(f.get("fonts", {}).keys(), key=variant_sort_key)
            item["axes"] = [{"tag": a["tag"], "min": a["min"], "max": a["max"]} for a in f.get("axes", [])]
            families.append(item)
        _catalog = {"families": families, "updated": CATALOG_FILE.stat().st_mtime}
        return _catalog


def variant_sort_key(v):
    return (v.endswith("i"), int(v.rstrip("i") or 400))


def family_names():
    return {f["family"] for f in get_catalog()["families"]}


# ---------- install / uninstall ----------

def refresh_font_cache():
    if SYSTEM == "Linux" and shutil.which("fc-cache"):
        subprocess.run(["fc-cache", "-f", str(FONT_DIR)], capture_output=True)


def install_family(family):
    manifest = json.loads(strip_xssi(fetch(DOWNLOAD_LIST_URL + urllib.parse.quote(family))))["manifest"]
    refs = [r for r in manifest.get("fileRefs", []) if r["filename"].lower().endswith((".ttf", ".otf"))]
    # Variable families ship both a variable file and static instances; installing both
    # creates duplicate entries in font menus, so prefer the static files when they exist.
    static = [r for r in refs if r["filename"].startswith("static/")]
    refs = static or refs
    if not refs:
        raise RuntimeError("No font files found for %s" % family)

    state = load_state()
    owned = {p for info in state["installed"].values() for p in info["files"]}
    FONT_DIR.mkdir(parents=True, exist_ok=True)
    written, skipped = [], []
    for ref in refs:
        dest = FONT_DIR / Path(ref["filename"]).name
        if dest.exists() and str(dest) not in owned:
            skipped.append(dest.name)  # installed by something else; leave it alone
            continue
        data = fetch(ref["url"])
        tmp = dest.with_name(dest.name + ".part")
        tmp.write_bytes(data)
        tmp.replace(dest)
        written.append(str(dest))

    with lock:
        state = load_state()
        state["installed"][family] = {"files": written, "skipped": skipped, "installedAt": time.time()}
        save_state(state)
    refresh_font_cache()
    return {"family": family, "files": len(written), "skipped": skipped}


def move_aside(paths):
    """Fallback when the Trash can't be used: keep files in a recoverable folder."""
    dest = DATA_DIR / "Removed Fonts"
    dest.mkdir(parents=True, exist_ok=True)
    for path in paths:
        target = dest / path.name
        n = 1
        while target.exists():
            target = dest / ("%s %d%s" % (path.stem, n, path.suffix))
            n += 1
        shutil.move(str(path), str(target))
    return str(dest)


def move_to_trash(paths):
    """Move files to the Trash. Returns where they went ("Trash" or a folder path)."""
    if not paths:
        return "Trash"
    if SYSTEM == "Darwin":
        # macOS blocks direct writes to ~/.Trash, so ask Finder to do it (the first time,
        # macOS asks once for permission to let Ligatures control Finder).
        items = ", ".join('POSIX file "%s"' % str(p).replace("\\", "\\\\").replace('"', '\\"') for p in paths)
        result = subprocess.run(["osascript", "-e", 'tell application "Finder" to delete {%s}' % items],
                                capture_output=True, text=True)
        if result.returncode == 0:
            return "Trash"
        print("Finder could not trash files, moving them aside instead:", result.stderr.strip())
    elif shutil.which("gio"):
        if subprocess.run(["gio", "trash"] + [str(p) for p in paths]).returncode == 0:
            return "Trash"
    return move_aside(paths)


def uninstall_family(family):
    with lock:
        state = load_state()
        info = state["installed"].get(family)
        if info is None:
            raise RuntimeError("%s was not installed by Ligatures" % family)
        paths = [Path(p) for p in info["files"]]
        paths = [p for p in paths if p.exists() and p.parent == FONT_DIR]
        where = move_to_trash(paths)
        still_there = [str(p) for p in paths if p.exists()]
        if still_there:
            raise RuntimeError("Could not remove %d file(s), e.g. %s" % (len(still_there), still_there[0]))
        del state["installed"][family]
        save_state(state)
    refresh_font_cache()
    return {"family": family, "removed": len(paths), "movedTo": where}


def check_for_new_fonts():
    """Refresh the catalog and record families that weren't there on the previous launch."""
    try:
        families = {f["family"] for f in get_catalog(force=True)["families"]}
    except Exception as exc:
        print("Could not check for new fonts:", exc)
        return
    with lock:
        state = load_state()
        known = set(state.get("knownFamilies", []))
        new = sorted(families - known) if known else []  # first launch: nothing counts as new
        found = state.get("newFamilies", {})
        now = time.time()
        for fam in new:
            found.setdefault(fam, now)
        state["newFamilies"] = {f: t for f, t in found.items() if f in families}
        state["knownFamilies"] = sorted(families)
        state["lastCheck"] = {"at": now, "found": new}
        save_state(state)
    if new:
        print("%d new font famil%s since last launch: %s" % (len(new), "y" if len(new) == 1 else "ies", ", ".join(new[:10])))
    else:
        print("No new fonts since last launch")


def installed_summary(state):
    out = {}
    for fam, info in state["installed"].items():
        present = [p for p in info["files"] if Path(p).exists()]
        out[fam] = {"files": len(present), "missing": len(info["files"]) - len(present),
                    "installedAt": info.get("installedAt")}
    return out


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    server_version = "FontManager/1.0"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def host_ok(self):
        # Blocks DNS-rebinding attacks from web pages pretending to be localhost.
        return self.headers.get("Host", "") in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT)

    def do_GET(self):
        if not self.host_ok():
            return self.send_error(403)
        path = urllib.parse.urlparse(self.path).path
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        try:
            if path in ("/", "/index.html"):
                html = (HERE / "index.html").read_text().replace("__FM_TOKEN__", TOKEN)
                body = html.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
            elif path == "/api/catalog":
                self.send_json(get_catalog(force="refresh" in query))
            elif path == "/api/state":
                state = load_state()
                self.send_json({"installed": installed_summary(state), "favorites": state["favorites"],
                                "newFamilies": state.get("newFamilies", {}), "lastCheck": state.get("lastCheck"),
                                "fontDir": str(FONT_DIR), "system": SYSTEM})
            else:
                self.send_error(404)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 500)

    def do_POST(self):
        if not self.host_ok() or self.headers.get("X-FM-Token") != TOKEN:
            return self.send_error(403)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            family = payload.get("family", "")
            path = urllib.parse.urlparse(self.path).path
            if path in ("/api/install", "/api/uninstall", "/api/favorite") and family not in family_names():
                return self.send_json({"error": "Unknown family"}, 400)
            if path == "/api/install":
                self.send_json(install_family(family))
            elif path == "/api/uninstall":
                self.send_json(uninstall_family(family))
            elif path == "/api/favorite":
                with lock:
                    state = load_state()
                    favs = [f for f in state["favorites"] if f != family]
                    if payload.get("on"):
                        favs.append(family)
                    state["favorites"] = favs
                    save_state(state)
                self.send_json({"favorites": favs})
            elif path == "/api/new/clear":
                with lock:
                    state = load_state()
                    state["newFamilies"] = {}
                    save_state(state)
                self.send_json({"newFamilies": {}})
            else:
                self.send_error(404)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 500)


def main():
    sys.stdout.reconfigure(line_buffering=True)  # show messages promptly when not in a terminal
    url = "http://%s:%d/" % (HOST, PORT)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("Ligatures running at %s" % url)
    print("Fonts install to %s  (Ctrl+C to quit)" % FONT_DIR)
    print("Checking Google Fonts for new families…")
    check_for_new_fonts()  # requests queue on the open socket until this finishes
    if "--exit-with-parent" in sys.argv:  # used by the Mac app: never outlive it, even after a crash
        parent = os.getppid()

        def watch_parent():
            while os.getppid() == parent:
                time.sleep(2)
            os._exit(0)
        threading.Thread(target=watch_parent, daemon=True).start()
    if "--no-browser" not in sys.argv:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nBye")


if __name__ == "__main__":
    main()
