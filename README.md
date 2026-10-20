# Ligatures

A small local app for browsing every Google Fonts family and installing fonts on your Mac with one click. It runs entirely on your machine. A Python server (standard library only) does the installing, and the interface runs either in your browser or in a native Mac app window.

> Not affiliated with or endorsed by Google. "Google Fonts" is a trademark of Google LLC.

## Features

- **Browse all families.** The full Google Fonts catalog (about 1,950 families), with live previews in your own text and size.
- **Find fonts fast.** Search by family or designer, filter by category and language, and sort by popularity, trending, newest, name or number of styles.
- **Grid and list views.** Switch between them with a short build-up animation. Your choice is remembered.
- **Details panel.** Every weight and italic, the designer, dates, variable axes, a link to the Google Fonts page and copy-paste web embed code.
- **Install and uninstall.** Fonts go straight into `~/Library/Fonts`, so they appear in every app at once. Uninstalling moves the files to the Trash, and the app only ever removes fonts it installed itself.
- **New font alerts.** Each launch checks Google Fonts for families added since the previous launch and highlights them.
- **Favorites.** Star families to find them again later.
- **Accessible.** WCAG AA contrast in light and dark mode, visible keyboard focus, and Reduce Motion is respected.

## Requirements

- macOS 12 or later (it also runs on Linux; see below)
- Python 3.9 or later. On a Mac, the one that comes with the Xcode Command Line Tools is enough. To get them, run `xcode-select --install`.
- To build the Mac app: the Swift compiler, which also comes with the Command Line Tools

## Run it

### As a Mac app

Build the app and install it into `/Applications`:

```bash
./build_app.sh --install
```

Then open **Ligatures** from Applications, Launchpad or Spotlight. The app starts its own server in the background on port 8766 and stops it when you quit.

Run `./build_app.sh` without `--install` to only build it into `build/`.

### From the terminal

```bash
python3 fontmanager.py
```

This opens http://127.0.0.1:8765 in your browser. Press Ctrl+C to stop it.

| Option | What it does |
|---|---|
| `--no-browser` | Don't open a browser window on start |
| `FONTMANAGER_PORT=9000` | Use a different port |

### Keyboard shortcuts

| Key | Action |
|---|---|
| `/` | Open search |
| `Esc` | Clear and close search, or close the details panel |

## Where things are stored

| What | macOS | Linux |
|---|---|---|
| Installed fonts | `~/Library/Fonts` | `~/.local/share/fonts/google-fonts` |
| Favorites, install records, cached catalog | `~/Library/Application Support/FontManager` | `~/.local/share/fontmanager` |
| Mac app log | `~/Library/Logs/FontManager.log` | — |

The terminal version and the Mac app share the same data, so they show the same installed fonts and favorites.

The first time you uninstall a font, macOS asks whether the app may control Finder, which it uses to move the files to the Trash. If you decline, removed fonts are kept in a `Removed Fonts` folder inside the data folder instead.

## How it works

- `fontmanager.py` serves the page and a small JSON API on `127.0.0.1` only. Write requests need a per-session token, and requests with an unexpected `Host` header are rejected, so other websites can't trigger installs.
- The catalog comes from Google Fonts' public metadata, and font files come from Google's download manifest for each family. For variable families, the static font files are installed rather than both the static and variable versions, so font menus don't show duplicates.
- Previews load through the Google Fonts CSS API, and only for cards that are on screen.
- The Mac app (`macos/main.swift`) is a WKWebView window. It runs the bundled `fontmanager.py`, waits for the server to come up, and stops it on quit. The server also exits by itself if the app crashes.

## Project layout

```
fontmanager.py           local server: catalog, install/uninstall, favorites, new-font check
index.html               the whole interface (HTML, CSS and JavaScript in one file)
build_app.sh             builds "Ligatures.app" (--install copies it to /Applications)
macos/main.swift         native app window around the local server
macos/Info.plist         app bundle settings
macos/make_icon.swift    draws the app icon
```

## Notes

- The Mac app is ad hoc signed for use on the Mac that built it. Running it on another Mac would need a Developer ID certificate and notarization.
- After changing `fontmanager.py` or `index.html`, run `./build_app.sh --install` again, because the app bundles its own copy of both.
