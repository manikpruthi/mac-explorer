# Mac Explorer

A native macOS file manager with a Windows 11 File Explorer-style UI. This is a Swift/AppKit
rewrite of Explorer Neo 1.3.0, built against the same behavioral contract
([docs/REA-spec.md](docs/REA-spec.md)) with no web views and no third-party dependencies.

![Home, dark theme](docs/screenshots/home-dark.png)
![Applications, light theme](docs/screenshots/apps-light.png)
![Tiles view, light theme](docs/screenshots/tiles-light.png)
![Details pane](docs/screenshots/details-light.png)
![Gallery](docs/screenshots/gallery.png)
![Network](docs/screenshots/network.png)
![Archive browsing](docs/screenshots/archive.png)
![Search](docs/screenshots/search.png)

## Features

- **Tabbed browsing** with per-tab path, history, sort, view, and selection. `⌘T`, `⌘W`,
  middle-click close, drag-out detach, tab context menu with “Move tab to new window”, `⌘N` windows.
- **Navigation bar** with back/forward/up/refresh, clickable breadcrumbs, collapsed long paths, and
  an address bar that switches to edit mode with a single click (`⌘L`, `~` expansion).
- **Windows 11 command bar** — New, Cut, Copy, Paste, Rename, Delete, Undo Delete, Sort, View,
  Details, and an overflow menu with pin-to-Quick-access, theme, terminal, and About.
- **File-aware Cut** from the toolbar, context menu, `⌘X`, and the macOS Edit menu; cut items stay
  dimmed until pasted.
- **Quick access pinning** from any folder’s context menu or the overflow menu. Pins persist and
  expand the navigation pane.
- **Navigation pane** — Home, Gallery, Network, collapsible Quick access with expandable folder
  trees, This PC volumes, and Trash.
- **Home** — pinned Quick access cards, a persisted recent-files list, and a storage overview for
  Macintosh HD and mounted volumes with used/free capacity bars.
- **Gallery** — recursive Pictures scan grouped by year with Quick Look thumbnails.
- **Network** — Bonjour SMB discovery, Finder-owned authentication/mounting, mounted-share browsing.
- **Archive browsing** — ZIP/TAR/GZ/BZ2/XZ and other `bsdtar` formats open in a read-only extracted
  view with breadcrumbs, Up/Back, copy-out, file opening, and Extract All.
- **Drag and drop** — internal drops move onto folders, breadcrumb folders in the address bar, or the
  navigation pane (Option copies); Finder drops copy in.
- **Five views** — Details, Large icons, Medium icons, List, and Tiles. Details has sortable,
  user-resizable columns with Windows-style header/body alignment; the Name column flexes to fill
  the pane while dragged widths survive refreshes. Large/medium icon captions are centred under
  their icons.
- **Explorer selection model** — click, ⌘-toggle, Shift range, arrows, type-ahead, rubber-band
  (marquee) drag selection with live row/icon highlighting and edge auto-scroll, checkbox hit
  targets, and `⌘A`.
- **Live updates** — the active folder refreshes automatically when files are added, removed,
  renamed, or changed by other apps, and the navigation pane and Home update when volumes mount,
  unmount, or eject.
- **Volume ejection** — eject mounted disk images, removable media, and network volumes from the
  navigation pane or the Home volume cards.
- **Details pane** with previews, metadata, quick actions, and a multi-selection summary.
- **Quick Look** — press `Space` on a selected file to preview it in the system Quick Look panel,
  like Finder. `Space` or `Esc` closes it, arrow keys browse the folder, and `Enter` opens the
  previewed file. The context menu also offers Quick Look, though the `Space` shortcut is faster.
- **Real file operations** — create folder/text file, inline rename, copy/cut/paste with Windows-style
  unique names, move to Trash, restore and empty Trash, compress to ZIP, permanent delete (confirmed),
  recursive properties, Show in Finder,
  and Open in Terminal. **Undo Delete** restores the last Trash operation (single level) from the
  command bar, the file context menu, or `⌘Z`; it stays available across launches while the trashed
  files still exist, and disables after a permanent delete or when the Trash copies are gone. The
  context menu also offers **Open with**, including a compatible-app submenu and an “Other…”
  application chooser, plus a **Share** submenu with all installed share extensions (AirDrop, Mail,
  Messages, Notes, Reminders, and more) and, as its first item, **Quick Share**, which sends files
  to nearby Android phones via [QuickShare-Mac](https://github.com/manikpruthi/quickshare-mac)
  using a `quickshare://send` handoff (no document-open handoff; HTML and every other file type work).
- **Shared file clipboard** — file URLs are published to `NSPasteboard` for Finder interop; internal
  cut intent never leaves the app.
- **Scoped, debounced search** with hidden-item support and a 250-result cap. App/package bundles
  are treated as opaque.
- **Light, dark, and system themes**, accent `#0067C0` selection, Windows-style window buttons with
  hidden traffic lights, a Dock icon with balanced transparent margins, draggable title strip,
  double-click zoom, and persistent window bounds.
- **Complete keyboard map** (below) plus a native File/Edit/View/Window menu bar.

## Requirements

- macOS 14 or later (Apple Silicon or Intel — the DMG is a universal binary)
- Nothing else to install if you use the prebuilt DMG
- To build from source: Xcode 16+ to open/build the Xcode project, or just the Command Line
  Tools for `build.sh`
- No third-party dependencies or services

## Install

### Easy mode — use the prebuilt DMG (no Xcode needed)

1. Download **[`release/Mac-Explorer-1.3.0.dmg`](release/Mac-Explorer-1.3.0.dmg)**
   (universal: Apple Silicon and Intel).
2. Double-click the DMG to mount it.
3. Drag **Mac Explorer.app** onto the **Applications** shortcut in the window.
4. Open **Applications**, then **right-click Mac Explorer.app → Open** and confirm
   **Open** on the warning. (The app is ad-hoc signed, not notarized, so macOS blocks a plain
   double-click on first launch.)
   - If the prompt only offers **Done** / no **Open** button, use
     **System Settings → Privacy & Security → Open Anyway** instead.
5. Grant **Full Disk Access** when asked — see [Full Disk Access](#full-disk-access).

To eject the installer afterward, click the eject icon beside *Mac Explorer* in Finder’s sidebar.

### Build from source

```bash
./build.sh                  # Debug build -> "$HOME/Library/Caches/MacExplorerBuild/Mac Explorer.app"
./build.sh release          # Optimized Release build
open "$HOME/Library/Caches/MacExplorerBuild/Mac Explorer.app"
./package.sh                # Release build + DMG and ZIP under release/
```

CLI builds go to `~/Library/Caches/MacExplorerBuild` so Spotlight and the macOS Apps view don't
list a second copy alongside the installed app. Set `MAC_EXPLORER_BUILD_DIR` to override it.
`package.sh` writes `release/Mac-Explorer-1.3.0.dmg` and `release/Mac-Explorer-1.3.0.zip`; both
are committed to the repo so the DMG route above works without building anything. The app is
unsigned. On first launch, right-click **Mac Explorer.app → Open**, or allow it under
**System Settings → Privacy & Security → Open Anyway**.

The Xcode project is `MacExplorer.xcodeproj` with the shared scheme `MacExplorer`
(macOS 14 deployment target, bundle id `tools.macexplorer`). `build.sh` is the canonical
build for machines with only the Command Line Tools.

### Full Disk Access

macOS protects `~/.Trash` and other locations from third-party apps. Grant **Full Disk Access** in
**System Settings → Privacy & Security → Full Disk Access**. The app links directly to that pane
from permission errors and from failed file operations. The native app uses a new bundle id
(`tools.macexplorer`), so it needs its own TCC grant separate from the Electron app.

Local network access uses `NSLocalNetworkUsageDescription` and the `_smb._tcp` Bonjour service in
`Resources/Info.plist`, matching the Electron package’s `extendInfo`.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘T` / `⌘W` | New tab / close tab |
| `⌘N` | New window |
| `⌘[` / `⌘]` | Back / forward |
| `⌘↑` / `⌘↓` | Up one folder / open focused item |
| `⌘F` / `⌘L` | Focus search / edit address |
| `⌘C` / `⌘X` / `⌘V` | Copy / cut / paste files (or text in fields) |
| `⌘A` | Select all |
| `⌘⇧N` | New folder |
| `F2` | Rename |
| `⌘⌫` or `Delete` | Move to Trash |
| `⌘Z` | Undo Delete (restore the last Trash operation) |
| `Backspace` (nothing selected) | Go back / up one folder |
| `⇧Delete` | Delete permanently (with confirmation) |
| `⌘I` | Properties |
| `⌘R` | Refresh |
| `Enter` | Open focused item |
| `Space` | Quick Look selected file (Space/Esc closes) |
| `↑ ↓ ← →` | Move selection |
| `Esc` | Clear search/selection, cancel address edit |

Drag a tab outside the window (or right-click it) to move it into a new window. Drag files onto
folders to move them; hold Option to copy. Dropping files from Finder copies them into the target.

## Architecture

- `Sources/App/` — `main.swift`, `AppDelegate` (window registry, menus, activation), screenshot and
  UI-test harnesses.
- `Sources/Models/` — verbatim Swift port of `shared/types.ts` and `shared/filekinds.ts`, sorting and
  formatting helpers.
- `Sources/Services/FileService.swift` — batched directory listings, bounded search/gallery scans,
  unique-name copy/paste, EXDEV moves, trash/delete guards, recursive properties, system info,
  and volume ejection.
- `Sources/Services/DirectoryWatcher.swift` — FSEvents-based live refresh for the active folder.
- `Sources/Services/ArchiveService.swift` — `bsdtar`-via-`Process` extraction with traversal,
  entry-count, and uncompressed-size checks; temp cache with 7-day cleanup.
- `Sources/Services/NetworkService.swift` — `NetServiceBrowser` SMB discovery plus `/sbin/mount`
  parsing; Finder owns SMB auth and mounting.
- `Sources/Services/PasteboardService.swift` — `NSPasteboard` file-URL publishing and change-count
  ownership tracking for internal cut intent.
- `Sources/Services/IconService.swift` — `NSWorkspace` icons, Quick Look thumbnails, bounded
  `NSCache` storage, and inset Dock icon rendering.
- `Sources/Services/AppStore.swift` — persisted preferences, pins, recents, window state, and the
  last Trash receipt (`lastDeleted`) used by Undo Delete, under
  `~/Library/Application Support/Mac Explorer`.
- `Sources/UI/` — programmatic AppKit: window chrome, tabs, navigation/command/status bars, sidebar,
  file views, Home, Gallery, Network, details pane, Quick Look preview, dialogs, menus, and theme.

There are no storyboards or XIBs. The only subprocesses are `/usr/bin/bsdtar`, `/sbin/mount`, and
`NSWorkspace` handoffs to Finder/Terminal.

## Performance

Measured Release build, one process (macOS `footprint`, the metric behind Activity Monitor's
memory column; `ps` RSS is higher only because it counts shared framework pages):

```bash
footprint "$(pgrep -x MacExplorer | head -1)" | grep phys_footprint
# 50 MB idle Home · 56 MB details view · 59 MB large-icons view of 200 images
# For reference, Finder measured 78 MB on the same machine
```

The real memory cost is below Finder's even with 16 MB of thumbnails cached. (`ps` RSS reports
~113 MB idle — that includes reclaimable shared-cache pages and double-counts framework code
mapped into every AppKit app.) Electron Explorer Neo measured ~346 MB RSS on the same machine.
Techniques used:

- Directory metadata is statted in fixed 48-item batches with a bounded worker pool.
- Quick Look thumbnails and workspace icons live in bounded `NSCache` instances (8 MB icons,
  16 MB thumbnails); large folders do not inflate memory.
- The file list, details pane, Gallery, and Network views are created lazily and released when you
  leave them. Inactive tab contents are released too.
- Icon grid and tiles are `NSCollectionView`s that create items on demand; details/list use reusable
  `NSTableView` cells.
- Search and Gallery scans have result caps (`250`/`160`), depth limits, and a 6-second deadline.
- There are no web views or Chromium helpers anywhere in the app.

## Verification

```bash
APP="$HOME/Library/Caches/MacExplorerBuild/Mac Explorer.app/Contents/MacOS/MacExplorer"

# 32 filesystem, archive, sorting, volume, and safety assertions
"$APP" --self-test

# 50 live-controller assertions: navigation, all five views, sorting, toggles,
# create/rename/copy/cut/paste, Undo Delete, marquee selection, Open with, address editing,
# search, dialogs, tabs, keyboard map, Quick Look (keyboard + menu), theme,
# and menu-bar routing
"$APP" --ui-test

# In-app snapshot capture (works without Screen Recording permission)
"$APP" --screenshot /tmp/mac-explorer.png --screenshot-exit
```

Screenshots in `docs/screenshots/` were generated with the same harness at 2× scale. The capture
flags used for documentation include `--location`, `--archive`, `--gallery`, `--network`,
`--gallery-root`, `--view`, `--theme`, `--details`, `--select-first`, `--search`, and
`--properties`.

Manual end-to-end checks performed: launch to Home, address-bar navigation, breadcrumbs,
create/rename/copy/cut/paste, Trash and permanent-delete guards, search, tabs and tab close,
archive browsing and Extract All, Network discovery view, Gallery thumbnails, Properties, About,
theme switching (light/dark/system), and the full keyboard/menu map.

## Known limitations

- The packaged app is unsigned; use right-click **Open** on first launch.
- Trash and protected locations depend on Full Disk Access.
- Archive views are read-only extracted copies. Encrypted archives and formats unsupported by
  macOS `bsdtar` will not open.
- Network shares are discovered over Bonjour and mounted through Finder; credentials never enter
  the app.
- No drag-out to Finder (drops from Finder copy in, internal drags move). Finder receives copied
  files but not Windows-style cut intent.
- Copies made from inside an archive publish the extracted cache path to the clipboard. Paste into
  a real folder promptly, or use **Extract All** for a permanent copy.
- No cloud/OneDrive integration, indexed search, preview pane, bulk rename, or permission elevation.
- macOS platform semantics (TCC prompts, Finder auth) take precedence over Windows quirks.

Not affiliated with Microsoft. Windows and File Explorer are trademarks of Microsoft Corporation.

## Provenance

Mac Explorer is a native Swift/AppKit **rewrite, not a code fork**, of **Explorer Neo 1.3.0** — the
Electron implementation in the author's `manikpruthi` monorepo under `explorer-neo/`. The behavioral
contract was captured in [docs/REA-spec.md](docs/REA-spec.md) from public Windows 11 File Explorer
behavior; the Electron sources were used as the reference for data models, filesystem semantics, and
interaction details. No Electron/Chromium code, web views, or bundled assets carry over: every view
and operation here is implemented in AppKit/Swift. Explorer Neo itself was an independent
implementation, not a fork of another public file manager.

## License

MIT — see [LICENSE](./LICENSE).
