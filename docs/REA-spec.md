# REA investigation — Windows 11 File Explorer

**Target:** Windows 11 File Explorer (23H2+ tabbed shell)
**Goal:** Rebuild its interaction model and visual language as a native-feeling macOS app.
**Method:** REA loop — observe, record evidence, write behavior spec, replicate, verify.
**Constraint:** The target is a Win32/WinUI binary and cannot be executed or attached to on this macOS host, so observation is limited to publicly documented behavior, published UI captures, and the Explorer shell's exposed command surface. This mirrors REA's browser/runtime-observation lane rather than its native-binary lane.

## Evidence

| Evidence | What it establishes |
|---|---|
| REA (morluto/rea) methodology | Observe → evidence-backed spec → implement → verify |
| Microsoft keyboard-shortcuts documentation | Explorer's command-level keyboard behavior |
| Windows Latest, 2023 Explorer redesign capture | Region order: tabs → nav bar (back/forward/up/refresh, breadcrumb, search) → command bar → nav pane + content + details pane; Gallery and Home |
| 0x5BFA, "Inside the Windows 11 Explorer Command Bar" | Modern Explorer is a WinUI command bar (XAML Islands) hosted by ExplorerFrame; command routing is verb-granular, and native behavior is behind `CShellBrowser` |
| Windows 11 system UI conventions | Rounded 8px surfaces, Mica-tinted chrome, Segoe UI Variable, accent `#0067C0`, 32px command targets, 28–32px rows |

Evidence is behavioral, not binary-level. No proprietary assets (Segoe UI Variable, Fluent icon fonts, Explorer icon sprites) are copied; icons are original SVG approximations.

## Anatomy (top → bottom)

1. **Tab strip** — draggable title region, active tab reads as a page, close glyph per tab, new-tab button. Window glyphs at the far right.
2. **Navigation bar** — back, forward, up, refresh; breadcrumb address pill; search field. The newer shell places commands *below* this row.
3. **Command bar** — New (split button), Cut, Copy, Paste, Rename, Share, Delete, Sort, View, Details, overflow. Commands disable contextually.
4. **Nav pane** — Home, Gallery, collapsible Quick access (expandable tree, accent marker on selection), This PC with volumes. Context menu offers open-in-new-tab and pin/unpin.
5. **Content** — Home (Quick access + Recent), Gallery (image grid), or a folder in Details / icons / list / tiles view. Sticky sortable headers, folder-first ordering, multi-select, rubber-band selection, inline rename.
6. **Details pane** — optional right rail with preview, type/size/dates/path, quick actions; multi-selection summary.
7. **Status bar** — item count / selected count on the left, view-mode and details toggles on the right.

## Behavior contract

### Navigation
- Per-tab back/forward history; Up = parent (root disables); Refresh re-reads; address bar breadcrumb with segment jumps, collapsed middle segments, editable full path (`⌘L`); search scoped to the current folder.
- Tabs: `⌘T` new, `⌘W` close (last tab closes the window), middle-click closes, titles track the folder, each tab keeps its own path, history, view, sort, and selection. Tabs can be dragged outside the window or moved via context menu into a new window with the same location.
- Network: SMB services are discovered over Bonjour; Finder owns authentication and mounting; mounted shares are browsable in-app.
- Archives: ZIP/TAR-family archives open in a read-only extracted view with breadcrumb navigation, file opening, copying out, and Extract All.
- Drag and drop: internal drops move files onto folders (Option copies); external Finder drops copy into the target; tab drags detach windows.
- `⌘[` back, `⌘]` forward, `⌘↑` up, `⌘↓`/`Enter` open, `⌘F` focus search, `⌘⇧N` new folder, `⌘⇧T`? (omitted), `⌘A` select all, `⌘C/X/V`, `Delete`/`⌘⌫` trash, `F2` rename, `Esc` clear/cancel.

### Filesystem operations (macOS mapping)
- Recycle Bin → `~/.Trash` via `shell.trashItem`; permanent delete is explicit.
- Cut/Copy/Paste publishes file URLs to the macOS pasteboard for Finder interop, keeps Windows-style cut intent internally, and resolves conflicts with unique names (`name - Copy`, `name - Copy (2)`) rather than overwriting.
- Open uses the macOS default handler; "Show in Finder", "Open in Terminal", rename/create/trash/properties are supported. Folder properties aggregate size with a bounded walk.
- Hidden dotfiles are filtered by default (View ▸ Show hidden items) like Explorer's hidden-attribute behavior. Known extensions are hidden in names unless View ▸ Show file extensions is on.

### Selection / content
- Single click selects; `⌘`-click toggles; `⇧`-click range; rubber-band drag on empty space; arrow-key focus/selection; type-ahead focus.
- Double-click opens; right-click selects the target and opens an 11-style menu; empty-space menu exposes New ▸ Folder/Text Document, Paste, Sort, Refresh, Open in Terminal, Properties.
- Details columns: Name, Date modified, Type, Size — sortable asc/desc, folders first. View modes: Details, Large icons, Medium icons, List, Tiles.
- Home shows pinned Quick access folders and a cleared-able Recent list. Gallery recursively surfaces images from Pictures with thumbnails, newest first, capped for responsiveness.

### Visual language
- Light: chrome `#f3f3f3`, content `#ffffff`, hairline `#e5e5e5`, accent `#0067C0`. Dark: chrome `#202020`, content `#191919`, surfaces `#2d2d2d`.
- Active tab and content share a surface; selected rows use accent-tinted fill plus a focus outline; nav selection uses an accent rail; hover is a 4–6% ink overlay.
- 13px UI text, 28–32px rows, 8px corner radii, 1px hairlines, soft elevation for menus/dialogs, 120ms transitions, overlay scrollbars.
- Window chrome is custom: macOS traffic lights are hidden and replaced by Windows-style minimize/maximize/close glyphs; the title strip drags the window and double-click maximizes.

## Non-goals
Cloud/OneDrive/Microsoft 365, drag-out to Finder, shell extensions, indexed search, preview pane, bulk rename, permissions elevation. macOS security prompts and platform semantics win over Windows quirks.

## Verification
1. `./build.sh` and the app's `--self-test` / `--ui-test` suites.
2. Native snapshot capture across light/dark, Home, folder Details, icons, Gallery, selection, context menu, details pane.
3. Manual parity checklist: region order, tab lifecycle, breadcrumb collapse, sorting, selection model, copy/paste/rename/trash, search, keyboard map, theme persistence.
4. Explicitly record divergence: fonts fall back to macOS system UI; icons are approximations; no Mica (macOS vibrancy used where available); native menu bar remains.
