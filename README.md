# Orca Find

A native macOS file finder in SwiftUI. Files show as big thumbnail cards, and search understands plain English or your voice. Everything runs on the Mac: text recognition, duplicate detection and voice all happen locally.

Requires macOS 14 Sonoma or later. Release build is about 6 MB.

## Build & run

```sh
./build.sh release --open      # builds "build/Orca Find.app" and launches it
./build.sh debug               # faster compile while developing
```

The script uses only the Command Line Tools (no Xcode needed). It compiles with SwiftPM, draws the icon (`tools/make_icon.swift`), assembles the bundle and signs it ad-hoc. The first launch asks for Desktop, Documents and Downloads access.

Developer hooks, run from the terminal:

```sh
.build/debug/OrcaFind --parse "pdfs from last week over 5 mb"         # how a query is understood
.build/debug/OrcaFind --search --root ~/SomeFolder --ocr --dupes "invoices"  # end-to-end search
.build/debug/OrcaFind --snapshot ./shots --root ~/FakeHome           # render screens to PNG
```

## Feature map

| Feature | Where |
|---|---|
| Natural-language search, filter chips, "Understood as" (⌘F) | `Search/QueryParser.swift`, `UI/TopBar.swift` |
| Text inside files and images (⇧⌘C, hover Copy Text, Select Text) | `Index/TextExtractor.swift`, `UI/PreviewView.swift` |
| Downloaded From (⇧⌘J) + From filter + Inspector | `Model/DownloadSource.swift` |
| Duplicates (⇧⌘D): SHA-256 + Vision look-alikes, iCloud skipped | `Tidy/Duplicates.swift` |
| Clean Up (⇧⌘K): six cards, Trash All / Trash Selected | `Tidy/Cleanup.swift`, `UI/CleanUpView.swift` |
| Two looks, ⌃⌘T, light/dark | `UI/Theme.swift` |
| Quick Search ⇧⌘Space (↩ / ⌘↩ / ⌥↩), customizable | `UI/QuickSearchPanel.swift`, `Services/HotKey.swift` |
| Menu bar: 10 newest downloads, draggable, can be turned off | `UI/MenuBarView.swift` |
| Quick Look (Space) with arrow keys | `Services/QuickLook.swift` |
| Saved searches that update live | `App/AppState.swift` |
| Automatic clean up (off by default) | `Tidy/AutoCleanup.swift` |
| Shortcuts & Siri: Find Files, Get Latest Download, Search in Orca Find | `Services/Intents.swift` |
| Multi-file drag (macOS 26+) | `UI/FileCard.swift` |
| Cards resize when tiled; ⌘+ / ⌘− | `UI/BrowserView.swift` |
| Home dashboard, sidebar library, smart folders, pinned folders | `UI/HomeView.swift`, `UI/SidebarView.swift` |
| Grid/List (⌘1/⌘2), sorting | `UI/BrowserView.swift` |
| Music player (⌘Space, ⌘←/⌘→) | `Services/MusicPlayer.swift` |
| Inspector (⌘I) | `UI/InspectorView.swift` |
| Context menu, drag & drop into other apps | `UI/FileCard.swift` |

**Extras:** voice search (⌥⌘F or the mic; on-device recognition when available), live folder watching (FSEvents), Undo after trashing, launch at login, more download sources.

## URL scheme

`orcafind://search?q=pdfs%20from%20gmail`, `orcafind://quick-search`, `orcafind://voice`, `orcafind://duplicates`, `orcafind://clean-up`, `orcafind://downloaded-from`, `orcafind://latest-download`. Shortcuts can call these with its "Open URL" action.

## Known gaps

- **Shortcuts/Siri actions:** the App Intents code is written, but the system registers intents only when the app is built with Xcode. Open the package in Xcode and build there, and they appear. Until then, use the URL scheme.
- **Licensing, payments and auto-updates** are not built. Sparkle is the usual choice for updates.
- **Signing:** builds are ad-hoc signed, so macOS may ask for folder permissions again after each rebuild. For distribution, sign with a Developer ID and notarize.
- **Intel:** the build script makes a native build only. A universal binary needs an x86_64 build plus `lipo`.
