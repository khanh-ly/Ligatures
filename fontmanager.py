#!/usr/bin/env python3
"""Local font manager: browse Google Fonts and install/uninstall them on this machine.

Run:  python3 fontmanager.py   (then open http://127.0.0.1:8765)
Only the Python standard library is used. Works on macOS and Linux.
"""

import io
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("FONTMANAGER_PORT", "8765"))
HERE = Path(__file__).resolve().parent
CATALOG_URL = "https://fonts.google.com/metadata/fonts"
DOWNLOAD_LIST_URL = "https://fonts.google.com/download/list?family="
FONTSHARE_URL = "https://api.fontshare.com/v2/fonts?limit=500"
FONTSHARE_DOWNLOAD_URL = "https://api.fontshare.com/v2/fonts/download/"
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
FONTSHARE_FILE = DATA_DIR / "fontshare.json"
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


def cached_json(url, path, force):
    """Download url into path unless a fresh copy exists; fall back to a stale copy when offline."""
    fresh = path.exists() and time.time() - path.stat().st_mtime < CATALOG_MAX_AGE
    if force or not fresh:
        try:
            text = strip_xssi(fetch(url))
            json.loads(text)  # only cache valid JSON
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        except Exception as exc:
            if not path.exists():
                raise RuntimeError("Could not download %s: %s" % (url, exc))
            print("Refresh of %s failed, using cached copy: %s" % (path.name, exc))
    return json.loads(path.read_text())


def get_catalog(force=False):
    """Return trimmed family metadata from Google Fonts and Fontshare, cached on disk for a day."""
    global _catalog
    with lock:
        fresh = all(p.exists() and time.time() - p.stat().st_mtime < CATALOG_MAX_AGE
                    for p in (CATALOG_FILE, FONTSHARE_FILE))
        if _catalog is not None and fresh and not force:
            return _catalog
        try:
            google = cached_json(CATALOG_URL, CATALOG_FILE, force)
        except RuntimeError as exc:
            raise RuntimeError("Could not download the Google Fonts catalog: %s" % exc)
        keep = ("family", "category", "subsets", "designers", "dateAdded", "lastModified",
                "popularity", "trending", "isNoto", "colorCapabilities")
        families = []
        for f in google["familyMetadataList"]:
            item = {k: f.get(k) for k in keep}
            item["variants"] = sorted(f.get("fonts", {}).keys(), key=variant_sort_key)
            item["axes"] = [{"tag": a["tag"], "min": a["min"], "max": a["max"]} for a in f.get("axes", [])]
            item["source"] = "google"
            families.append(item)
        try:
            families += fontshare_families(cached_json(FONTSHARE_URL, FONTSHARE_FILE, force),
                                           {f["family"] for f in families})
        except Exception as exc:  # Fontshare is optional: carry on with Google Fonts alone
            print("Fontshare unavailable:", exc)
        _catalog = {"families": families, "updated": CATALOG_FILE.stat().st_mtime}
        return _catalog


FONTSHARE_CATEGORIES = {"sans": "Sans Serif", "serif": "Serif", "slab": "Serif", "display": "Display",
                        "handwritten": "Handwriting", "script": "Handwriting", "mono": "Monospace"}
FONTSHARE_LICENSES = {"itf_ffl": "ITF Free Font License", "sil_ofl": "SIL Open Font License"}


def fontshare_families(data, taken):
    """Map Fontshare's font list onto the Google-style family records the page uses.

    Families Google Fonts already has (open-source fonts Fontshare mirrors) are skipped, so each
    family appears once. Popularity ranks are scaled to Google's range so mixed sorting interleaves.
    """
    # Slugs end up in URLs and CSS, so accept only lower-case letters, digits and hyphens.
    fonts = [f for f in data.get("fonts", []) if f.get("name") and f["name"] not in taken
             and re.fullmatch(r"[a-z0-9-]+", str(f.get("slug") or ""))]
    scale = max(len(taken), 1) / max(len(fonts), 1)
    popular = {f["slug"]: i + 1 for i, f in enumerate(sorted(fonts, key=lambda f: -(f.get("views") or 0)))}
    trending = {f["slug"]: i + 1 for i, f in enumerate(sorted(fonts, key=lambda f: -(f.get("views_recent") or 0)))}
    out = []
    for f in fonts:
        faces = {}
        for st in f.get("styles") or []:
            if st.get("is_variable") or not st.get("file"):
                continue  # static styles only: these are what gets installed
            weight = int(st["weight"]["weight"])
            variant = "%d%s" % (weight, "i" if st.get("is_italic") else "")
            url = "https:" + st["file"] if st["file"].startswith("//") else st["file"]
            faces.setdefault(variant, {"url": url + ".woff2", "number": st["weight"].get("number", weight)})
        if not faces:
            continue
        first = (f.get("category") or "").split(",")[0].strip().lower()
        designers = [d["name"] for d in f.get("designers") or [] if d.get("name")]
        out.append({
            "family": f["name"], "category": FONTSHARE_CATEGORIES.get(first, "Display"),
            "subsets": [f.get("script") or "latin"],
            "designers": designers or [((f.get("publisher") or {}).get("name") or "Indian Type Foundry")],
            "dateAdded": (f.get("inserted_at") or "")[:10] or None, "lastModified": None,
            "popularity": round(popular[f["slug"]] * scale), "trending": round(trending[f["slug"]] * scale),
            "isNoto": False, "colorCapabilities": [],
            "variants": sorted(faces, key=variant_sort_key), "axes": [],
            "source": "fontshare", "slug": f["slug"], "faces": faces,
            "license": FONTSHARE_LICENSES.get(f.get("license_type"), f.get("license_type")),
            "link": "https://www.fontshare.com/fonts/" + f["slug"],
        })
    return out


def find_family(family):
    return next((f for f in get_catalog()["families"] if f["family"] == family), None)


def variant_sort_key(v):
    return (v.endswith("i"), int(v.rstrip("i") or 400))


def family_names():
    return {f["family"] for f in get_catalog()["families"]}


# ---------- install / uninstall ----------

def refresh_font_cache():
    if SYSTEM == "Linux" and shutil.which("fc-cache"):
        subprocess.run(["fc-cache", "-f", str(FONT_DIR)], capture_output=True)


def google_font_files(family):
    """[(filename, loader)] for a Google Fonts family."""
    manifest = json.loads(strip_xssi(fetch(DOWNLOAD_LIST_URL + urllib.parse.quote(family))))["manifest"]
    refs = [r for r in manifest.get("fileRefs", []) if r["filename"].lower().endswith((".ttf", ".otf"))]
    # Variable families ship both a variable file and static instances; installing both
    # creates duplicate entries in font menus, so prefer the static files when they exist.
    static = [r for r in refs if r["filename"].startswith("static/")]
    return [(Path(r["filename"]).name, lambda url=r["url"]: fetch(url)) for r in static or refs]


def pick_fontshare_files(names):
    """Choose what to install from a Fontshare zip: static OTFs, else static TTFs (never web or variable files)."""
    fonts = [n for n in names if n.lower().endswith((".otf", ".ttf"))
             and "/web/" not in n.lower() and "__macosx" not in n.lower()]
    static = [n for n in fonts if "variable" not in Path(n).name.lower()]
    return [n for n in static if n.lower().endswith(".otf")] or static or fonts


def fontshare_font_files(slug):
    """[(filename, loader)] for a Fontshare family, read from its download zip."""
    archive = zipfile.ZipFile(io.BytesIO(fetch(FONTSHARE_DOWNLOAD_URL + urllib.parse.quote(slug), timeout=120)))
    return [(Path(n).name, lambda n=n: archive.read(n)) for n in pick_fontshare_files(archive.namelist())]


def install_family(family):
    entry = find_family(family) or {}
    files = fontshare_font_files(entry["slug"]) if entry.get("source") == "fontshare" else google_font_files(family)
    if not files:
        raise RuntimeError("No font files found for %s" % family)

    state = load_state()
    owned = {p for info in state["installed"].values() for p in info["files"]}
    FONT_DIR.mkdir(parents=True, exist_ok=True)
    written, skipped = [], []
    for name, load in files:
        dest = FONT_DIR / name
        if dest.exists() and str(dest) not in owned:
            skipped.append(dest.name)  # installed by something else; leave it alone
            continue
        tmp = dest.with_name(dest.name + ".part")
        tmp.write_bytes(load())
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
        # macOS asks once for permission to let Terminal control Finder).
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
    """Refresh the catalog and record families that weren't there on the previous launch.

    Each library is tracked separately, so a library seen for the first time (e.g. Fontshare
    after an update) is recorded silently instead of flagging everything in it as new.
    """
    try:
        families = get_catalog(force=True)["families"]
    except Exception as exc:
        print("Could not check for new fonts:", exc)
        return
    by_source = {}
    for f in families:
        by_source.setdefault(f.get("source", "google"), set()).add(f["family"])
    with lock:
        state = load_state()
        known_by = state.get("knownBySource") or {}
        if not known_by and state.get("knownFamilies"):  # data from before libraries were tracked
            known_by = {"google": state["knownFamilies"]}
        new = []
        for source, names in sorted(by_source.items()):
            known = set(known_by.get(source, []))
            if known:
                new += sorted(names - known)
            known_by[source] = sorted(names)
        everything = set().union(*by_source.values())
        found = state.get("newFamilies", {})
        now = time.time()
        for fam in new:
            found.setdefault(fam, now)
        state["newFamilies"] = {f: t for f, t in found.items() if f in everything}
        state["knownBySource"] = known_by
        state.pop("knownFamilies", None)
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

    def end_headers(self):
        # On every response: forbid other sites from framing the app (clickjacking) and MIME sniffing.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

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
        if not self.host_ok() or not secrets.compare_digest(self.headers.get("X-FM-Token", "").encode(), TOKEN.encode()):
            return self.send_error(403)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if not 0 <= length <= 1_000_000:  # never trust Content-Length: a negative read blocks forever
            return self.send_error(400)
        try:
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
    print("Checking for new fonts…")
    check_for_new_fonts()  # requests queue on the open socket until this finishes
    if "--no-browser" not in sys.argv:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nBye")


if __name__ == "__main__":
    main()
