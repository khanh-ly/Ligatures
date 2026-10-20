# Ligatures

*The free fonts manager.* A small local app for browsing every free family on [Google Fonts](https://fonts.google.com) and [Fontshare](https://www.fontshare.com), and installing them on your Mac with one click. It runs entirely on your machine, either as a self-contained Mac app or as a small Python server (standard library only) that you open in your browser.

> Not affiliated with or endorsed by Google or Indian Type Foundry. "Google Fonts" is a trademark of Google LLC; Fontshare is a service of Indian Type Foundry.

## Download

**[Download Ligatures for Mac](https://github.com/khanh-ly/Ligatures/releases/latest/download/Ligatures.zip)** (macOS 12 or later, Apple silicon or Intel), or see all [releases](https://github.com/khanh-ly/Ligatures/releases).

Unzip it and drag **Ligatures** into your Applications folder. The app isn't notarized by Apple, so the first time you open it, macOS asks you to approve it in System Settings; see [On another Mac](#on-another-mac) for the steps.

## Features

- **Browse two libraries.** The full Google Fonts catalog (about 1,950 families) plus Fontshare's free families (about 65 more), with live previews in your own text and size. Families that both libraries offer are shown once, from Google Fonts.
- **Filter by library.** Show everything, or only Google Fonts or Fontshare. Fontshare families carry a badge and list their license in the details panel.
- **Find fonts fast.** Search by family or designer, filter by category and language, and sort by popularity, trending, newest, name or number of styles.
- **Grid and list views.** Switch between them with a short build-up animation. Your choice is remembered.
- **Details panel.** Every weight and italic, the designer, dates, variable axes, a link to the Google Fonts page and copy-paste web embed code.
- **Install and uninstall.** Fonts go straight into `~/Library/Fonts`, so they appear in every app at once. Uninstalling moves the files to the Trash, and the app only ever removes fonts it installed itself.
- **New font alerts.** Each launch checks both libraries for families added since the previous launch and highlights them.
- **Favorites.** Star families to find them again later.
- **Accessible.** WCAG AA contrast in light and dark mode, visible keyboard focus, and Reduce Motion is respected.

## Requirements

- **Mac app:** macOS 12 or later, on Apple silicon or Intel. Nothing else needs to be installed.
- **Terminal version:** Python 3.9 or later, on macOS or Linux. On a Mac, the Python that comes with the Xcode Command Line Tools is enough (`xcode-select --install`).
- **Building the Mac app:** the Xcode Command Line Tools, which include the Swift compiler.

## Run it

### As a Mac app

Build the app and install it into `/Applications`:

```bash
./build_app.sh --install
```

Then open **Ligatures** from Applications, Launchpad or Spotlight. The app serves itself on port 8766 while it's open.

Run `./build_app.sh` without `--install` to only build it into `build/`.

### On another Mac

Each build also makes `build/Ligatures.zip`. Copy the zip to the other Mac (AirDrop, a USB drive, a file share), double-click it, and drag **Ligatures** into Applications.

Because the app isn't notarized by Apple, macOS blocks it the first time:

1. Open the app. macOS says it can't verify it. Click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Ligatures.
3. Confirm with your password. From then on it opens normally.

To skip these steps entirely, the app would need to be signed with a paid Apple Developer ID and notarized.

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
| Favorites, install records, cached catalogs | `~/Library/Application Support/FontManager` | `~/.local/share/fontmanager` |
| Mac app log | `~/Library/Logs/FontManager.log` | — |

The terminal version and the Mac app share the same data, so they show the same installed fonts and favorites.

Uninstalled fonts go to the Trash. If the Trash can't be used, they're kept in a `Removed Fonts` folder inside the data folder instead. The terminal version moves files to the Trash through Finder, so the first time, macOS asks whether Terminal may control Finder.

## How it works

- The interface (`index.html`) talks to a small JSON API on `127.0.0.1` only. There are two implementations of that server: `fontmanager.py` for the terminal, and `macos/FontServer.swift` built into the Mac app, so the app needs no Python. Both behave the same and share the same data files.
- Write requests need a per-session token, and requests with an unexpected `Host` header are rejected, so other websites can't trigger installs.
- **Google Fonts:** the catalog comes from Google Fonts' public metadata, and font files come from Google's download manifest for each family.
- **Fontshare:** the catalog comes from Fontshare's public API, and each family's download zip provides the font files. The static OTF files are installed; web and variable files are skipped.
- For variable families, the static font files are installed rather than both the static and variable versions, so font menus don't show duplicates.
- Sorting by popularity or trending interleaves the libraries: each Fontshare family's rank within Fontshare is scaled to Google's range.
- Previews load through the Google Fonts CSS API, or from Fontshare's web fonts, and only for cards that are on screen.
- The Mac app (`macos/main.swift`) is a WKWebView window around its built-in server. It's built as a universal binary (Apple silicon and Intel) targeting macOS 12.

## Project layout

```
fontmanager.py           terminal server: catalog, install/uninstall, favorites, new-font check
index.html               the whole interface (HTML, CSS and JavaScript in one file)
build_app.sh             builds the app and a zip for other Macs (--install copies it to /Applications)
macos/main.swift         native app window
macos/FontServer.swift   the app's built-in server (Swift port of fontmanager.py)
macos/Info.plist         app bundle settings
macos/make_icon.swift    draws the app icon (a monoline "fi" ligature)
```

## Licenses

Ligatures itself is released under the [MIT License](LICENSE).

The fonts it installs are not part of Ligatures and keep their own licenses. Google Fonts families are open source, mostly under the SIL Open Font License. Fontshare families use either the SIL Open Font License or the ITF Free Font License, which allows free personal and commercial use. Each family's license is shown in its details panel. Check it before redistributing font files.

## Notes

- The Mac app is ad hoc signed, not notarized. See [On another Mac](#on-another-mac) for opening it elsewhere.
- After changing `index.html`, run `./build_app.sh --install` again, because the app bundles its own copy.
- Server changes need making in both `fontmanager.py` and `macos/FontServer.swift` to keep the two versions in step.
