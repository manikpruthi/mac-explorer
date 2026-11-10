import AppKit
import Foundation

// Bug-reproduction unit tests for the MacExplorer code review (2026-11).
// Each B-test asserts the CORRECT behavior and therefore FAILS on the current
// code, proving the reported bug is real. S-tests are sanity checks that must
// PASS to validate the harness itself.
//
// Run: scripts/run-bug-tests.sh   (compiles Sources + this file, runs headless)

// MARK: - Harness

setvbuf(stdout, nil, _IONBF, 0)
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

struct TestFailure: Error { let message: String }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}

var passCount = 0
var failCount = 0
var resultLines: [String] = []

// Each test runs in its own process (runner passes --only <id>) so AppKit /
// AppStore / Swift-concurrency state cannot leak between tests.
let onlyFilter: String? = {
    if let index = CommandLine.arguments.firstIndex(of: "--only"), index + 1 < CommandLine.arguments.count {
        return CommandLine.arguments[index + 1]
    }
    return nil
}()

@MainActor
func runTest(_ id: String, _ body: () async throws -> Void) async {
    if let onlyFilter, !id.hasPrefix(onlyFilter) { return }
    do {
        try await body()
        passCount += 1
        resultLines.append("PASS  \(id)")
        print("PASS  \(id)")
    } catch {
        failCount += 1
        let detail = (error as? TestFailure)?.message ?? String(describing: error)
        resultLines.append("FAIL  \(id) — \(detail)")
        print("FAIL  \(id) — \(detail)")
    }
}

@MainActor
func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-explorer-bugtests-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func writeText(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

@MainActor
func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        pump(0.05)
    }
    return condition()
}

@MainActor
func descendants(of view: NSView) -> [NSView] {
    var out: [NSView] = []
    var stack: [NSView] = Array(view.subviews)
    while let next = stack.popLast() {
        out.append(next)
        for child in next.subviews { stack.append(child) }
    }
    return out
}

@MainActor
func firstView<T: NSView>(_ type: T.Type, in view: NSView, where predicate: (T) -> Bool = { _ in true }) -> T? {
    descendants(of: view).compactMap { $0 as? T }.first(where: predicate)
}

@MainActor
func allLabelTexts(in view: NSView) -> [String] {
    descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
}

func makeEntry(_ name: String, path: String, isDirectory: Bool = false) -> FileEntry {
    FileEntry(
        name: name, path: path, isDirectory: isDirectory, isSymlink: false,
        size: isDirectory ? 0 : 10, modified: Date(), created: Date(),
        kind: isDirectory ? .folder : .text, hidden: false
    )
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@MainActor
final class RecordingDelegate: FileListViewDelegate {
    var lastPaths: [String] = []
    var lastFocused: String?
    var selectionCallCount = 0
    func fileListSelectionDidChange(_ paths: [String], focused: String?) {
        lastPaths = paths
        lastFocused = focused
        selectionCallCount += 1
    }
    func fileListMarqueeSelection(_ paths: [String]) {}
    func fileListOpen(_ entry: FileEntry) {}
    func fileListContextMenu(entry: FileEntry?, event: NSEvent) {}
    func fileListBackgroundClick() {}
    func fileListToggleSelection(_ path: String) {}
    func fileListRename(_ entry: FileEntry, to name: String) {}
    func fileListCancelRename() {}
    func fileListDrop(paths: [String], destination: String?, copy: Bool) {}
    func fileListSort(_ key: SortKey) {}
    func fileListNewFolder() {}
    func fileListRetry() {}
    func fileListOpenPrivacy() {}
    func fileListAddRecent(_ entry: FileEntry) {}
}

@MainActor
func updateList(
    _ view: FileListView,
    entries: [FileEntry],
    mode: ViewMode,
    selected: Set<String> = [],
    focused: String? = nil,
    renamingPath: String? = nil
) {
    view.update(
        entries: entries, mode: mode, selected: selected, focused: focused,
        renamingPath: renamingPath, cutPaths: [], showExtensions: true,
        sortKey: .name, sortDir: .asc, loading: false, errorMessage: nil,
        permissionError: false, isSearch: false
    )
    view.layoutSubtreeIfNeeded()
}

// MARK: - Sanity checks (must PASS)

await runTest("S01 harness: readDirectory lists a temp folder") {
    let dir = try makeTempDir("s01")
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeText("hello", to: dir.appendingPathComponent("a.txt"))
    let listing = try FileService.readDirectory(dir.path)
    try require(listing.entries.map(\.name) == ["a.txt"], "unexpected listing \(listing.entries.map(\.name))")
}

await runTest("S02 harness: compress of normal filenames succeeds") {
    let dir = try makeTempDir("s02")
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.txt")
    let b = dir.appendingPathComponent("b.txt")
    try writeText("a", to: a)
    try writeText("b", to: b)
    let result = FileService.compressToArchive([a.path, b.path])
    try require(result.ok, "compress failed: \(result.error ?? "?")")
    try require(result.path.map { FileManager.default.fileExists(atPath: $0) } == true, "archive missing")
}

await runTest("S03 harness: ASCII wildcard search works") {
    let dir = try makeTempDir("s03")
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeText("x", to: dir.appendingPathComponent("a.txt"))
    let response = FileService.search(root: dir.path, query: "?.txt", showHidden: false)
    try require(response.entries.contains { $0.name == "a.txt" }, "ASCII ? wildcard did not match a.txt")
}

// MARK: - B01: Compress fails when a filename starts with "-"

await runTest("B01 compress: multi-file Compress with a dash-leading filename") {
    let dir = try makeTempDir("b01")
    defer { try? FileManager.default.removeItem(at: dir) }
    let dash = dir.appendingPathComponent("-notes.txt")
    let normal = dir.appendingPathComponent("normal.txt")
    try writeText("dash", to: dash)
    try writeText("normal", to: normal)
    let result = FileService.compressToArchive([dash.path, normal.path])
    try require(
        result.ok,
        "Compress failed for a file named '-notes.txt': \(result.error ?? "unknown"). "
        + "zip parses the relative name as command-line options (FileService.swift:927)."
    )
    if let archive = result.path {
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-l", archive]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        try require(
            text.contains("-notes.txt") && text.contains("normal.txt"),
            "Compress reported success but '-notes.txt' is silently MISSING from the archive: "
            + "zip parses the dash-leading relative name as an option (-n = skip-compression suffixes), "
            + "so the file is dropped without any error (FileService.swift:922-927)."
        )
    }
}

// MARK: - B02: DuplicateFinder compare phase ignores cancellation

await runTest("B02 duplicates: cancelling during compare stops the head-hash loop") {
    let dir = try makeTempDir("b02")
    defer { try? FileManager.default.removeItem(at: dir) }
    // 512 same-size files with distinct contents: one size bucket, head-hash loop
    // iterates all of them. Progress fires every 64 files, so cancel at done=64.
    for i in 0..<512 {
        var data = Data(repeating: UInt8(i & 0xFF), count: 32 * 1024)
        data[0] = UInt8(i & 0xFF)
        data[1] = UInt8((i >> 8) & 0xFF)
        try data.write(to: dir.appendingPathComponent(String(format: "f%04d.bin", i)))
    }
    let maxDone = LockedBox(0)
    let cancelled = LockedBox(false)
    let progress: @Sendable (DuplicateFinder.Phase) -> Void = { phase in
        if case .comparing(let done, _) = phase {
            maxDone.withLock { $0 = max($0, done) }
            if done >= 64, !cancelled.withLock({ v -> Bool in let was = v; v = true; return was }) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    let task = Task.detached(priority: .userInitiated) {
        DuplicateFinder.scan(root: dir.path, showHidden: false, progress: progress)
    }
    let result = await task.value
    let observed = maxDone.withLock { $0 }
    try require(
        observed <= 128,
        "cancel requested at done=64 but compare kept hashing to done=\(observed) "
        + "(truncated=\(result.truncated)). The head-hash loop never checks Task.isCancelled "
        + "or the deadline (DuplicateFinder.swift:94-100)."
    )
}

// MARK: - B03: Gallery truncation is not "most recent"

await runTest("B03 gallery: bounded partial scan does not claim globally newest images") {
    let dir = try makeTempDir("b03")
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = Date(timeIntervalSince1970: 1_500_000_000) // 2017
    for i in 0..<6 {
        let url = dir.appendingPathComponent("old\(i).jpg")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let recentDir = dir.appendingPathComponent("Recent")
    try FileManager.default.createDirectory(at: recentDir, withIntermediateDirectories: true)
    let recent = recentDir.appendingPathComponent("newest.jpg")
    try Data("new".utf8).write(to: recent)
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: recent.path)

    let response = FileService.gallery(root: dir.path, limit: 5)
    try require(response.truncated, "setup: expected a truncated scan")
    try require(response.entries.count <= 5, "gallery exceeded its bounded result limit")
    let gallery = GalleryView()
    gallery.update(root: dir.path, entries: response.entries, truncated: response.truncated, loading: false, errorMessage: nil)
    try require(
        !allLabelTexts(in: gallery).contains(where: { $0.contains("most recent") }),
        "partial gallery results falsely claim to be the globally most recent images"
    )
}

// MARK: - B04: '?' wildcard matches UTF-8 bytes, not characters

await runTest("B04 search: '???.txt' matches a 3-character Unicode filename") {
    let dir = try makeTempDir("b04")
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeText("x", to: dir.appendingPathComponent("abc.txt"))
    try writeText("x", to: dir.appendingPathComponent("日本語.txt"))
    let response = FileService.search(root: dir.path, query: "???.txt", showHidden: false)
    try require(response.entries.contains { $0.name == "abc.txt" }, "setup: ASCII control did not match")
    try require(
        response.entries.contains { $0.name == "日本語.txt" },
        "'???.txt' did not match '日本語.txt' (3 characters, 9 UTF-8 bytes): fnmatch counts "
        + "bytes, so each ? eats one byte (SearchService.swift:275)."
    )
}

// MARK: - B05: Opening a new tab mid-search strands the old tab on "Searching…"

await runTest("B05 tabs: old tab does not stay stuck on Searching after Open in New Tab") {
    let dirA = try makeTempDir("b05a")
    let dirB = try makeTempDir("b05b")
    defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
    try writeText("a", to: dirA.appendingPathComponent("a.txt"))
    try writeText("b", to: dirB.appendingPathComponent("b.txt"))

    let controller = BrowserWindowController(location: .fs(path: dirA.path))
    defer { controller.window?.close() }
    _ = waitFor(5) { controller.window != nil }
    pump(0.3)
    guard let window = controller.window, let content = window.contentView else {
        throw TestFailure(message: "no window")
    }
    guard let searchField = firstView(SearchField.self, in: content) else {
        throw TestFailure(message: "search field not found")
    }
    // Typing starts a search: searchLoading is set synchronously (BWC:1165).
    searchField.onTextChange?("report")
    // "Open in New Tab" while the search is in flight.
    controller.sidebarNewTab(path: dirB.path)
    // Return to the original tab.
    controller.titleBarActivateTab(0)
    pump(0.2)
    let searching = allLabelTexts(in: content).contains { $0.contains("Searching for") }
    try require(
        !searching,
        "tab 1 is stuck showing 'Searching for report…' forever: navigate(to:newTab:true) "
        + "cancels the search but skips leaveActiveTab(), so searchLoading stays true "
        + "(BrowserWindowController.swift:950-965 vs 1056-1069)."
    )
}

// MARK: - B06: Async trash completion clears the WRONG tab's selection

await runTest("B06 tabs: trash completion must not clear the new active tab's selection") {
    let dirA = try makeTempDir("b06a")
    let dirB = try makeTempDir("b06b")
    defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
    var pathsA: [String] = []
    for i in 0..<500 {
        let url = dirA.appendingPathComponent(String(format: "f%04d.txt", i))
        try writeText("x", to: url)
        pathsA.append(url.path)
    }
    let fileB = dirB.appendingPathComponent("keep-me-selected.txt")
    try writeText("b", to: fileB)

    let controller = BrowserWindowController(location: .fs(path: dirA.path))
    defer { controller.window?.close() }
    pump(0.3)
    guard let window = controller.window, let content = window.contentView else {
        throw TestFailure(message: "no window")
    }
    controller.fileListSelectionDidChange(pathsA, focused: nil)
    controller.deleteAction(nil) // trash starts on a detached task
    controller.sidebarNewTab(path: dirB.path) // user switches tabs immediately
    _ = waitFor(5) {
        guard let c = controller.window?.contentView,
              let list = firstView(FileListView.self, in: c),
              let table = firstView(FileTableView.self, in: list) else { return false }
        return table.numberOfRows > 0
    }
    controller.fileListSelectionDidChange([fileB.path], focused: fileB.path)
    _ = waitFor(15) { AppStore.shared.lastDeleted != nil }
    pump(0.5) // let finishTrash run on the main actor

    guard let list = firstView(FileListView.self, in: content),
          let table = firstView(FileTableView.self, in: list) else {
        throw TestFailure(message: "file table not found in tab 2")
    }
    // Clean the real Trash entries this test created.
    for item in AppStore.shared.lastDeleted ?? [] {
        try? FileManager.default.removeItem(atPath: item.trashPath)
    }
    try require(
        table.selectedRowIndexes.count == 1,
        "tab 2's selection was cleared by tab 1's trash completion: finishTrash writes "
        + "activeTab.selected/focusedPath and reloads whichever tab is active at completion, "
        + "not the tab that started the operation (BrowserWindowController.swift:1544-1546)."
    )
}

// MARK: - B07: Shift+arrow grid selection loses its anchor

await runTest("B07 grid: repeated shift+down keeps the original anchor selected") {
    let list = FileListView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let recorder = RecordingDelegate()
    list.delegate = recorder
    let entries = (0..<20).map { makeEntry(String(format: "f%02d.txt", $0), path: "/tmp/b07/f\($0)") }
    updateList(list, entries: entries, mode: .large, selected: [entries[0].path], focused: entries[0].path)

    list.moveGridFocus(horizontal: 0, vertical: 1, extend: true)
    try require(recorder.lastPaths.contains(entries[0].path), "setup: first extend lost the anchor")
    list.moveGridFocus(horizontal: 0, vertical: 1, extend: true)
    try require(
        recorder.lastPaths.contains(entries[0].path),
        "second shift+down deselected the anchor row: the anchor is recomputed from "
        + "focusedPath (the previous target) instead of the original press point "
        + "(FileListView.swift:763-767). Selection now: \(recorder.lastPaths.sorted())"
    )
}

// MARK: - B08: Grid arrow navigation uses the wrong column count

await runTest("B08 grid: down-arrow lands on the tile directly below (tiles mode)") {
    let list = FileListView(frame: NSRect(x: 0, y: 0, width: 1038, height: 600))
    let recorder = RecordingDelegate()
    list.delegate = recorder
    let entries = (0..<12).map { makeEntry(String(format: "f%02d.txt", $0), path: "/tmp/b08/f\($0)") }
    updateList(list, entries: entries, mode: .tiles, selected: [entries[0].path], focused: entries[0].path)
    guard let collection = firstView(NSCollectionView.self, in: list),
          let layout = collection.collectionViewLayout else {
        throw TestFailure(message: "collection view not found")
    }
    collection.layoutSubtreeIfNeeded()
    let width = collection.bounds.width
    guard let firstFrame = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame else {
        throw TestFailure(message: "no layout attributes")
    }
    var layoutColumns = 0
    for i in 1..<entries.count {
        if let frame = layout.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame,
           frame.minY > firstFrame.minY + 1 {
            layoutColumns = i
            break
        }
    }
    let keyboardColumns = max(1, Int(max(250, width - 28) / (250 + 2)))
    try require(layoutColumns > 0, "setup: single-row layout")
    try require(
        layoutColumns != keyboardColumns,
        "setup: width \(width) does not trigger the mismatch (layout \(layoutColumns), keyboard \(keyboardColumns))"
    )
    list.moveGridFocus(horizontal: 0, vertical: 1, extend: false)
    try require(
        recorder.lastFocused == entries[layoutColumns].path,
        "down-arrow moved \(keyboardColumns) items but the layout shows \(layoutColumns) columns "
        + "(width \(width)): keyboard math uses spacing 2 while tiles layout uses 4 and omits "
        + "the +spacing numerator (FileListView.swift:751-753 vs 367-373)."
    )
}

// MARK: - B09: Select All resets focus to the first row (scrolls to top)

await runTest("B09 select-all: Cmd-A preserves the current focus/scroll position") {
    let list = FileListView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let recorder = RecordingDelegate()
    list.delegate = recorder
    let entries = (0..<50).map { makeEntry(String(format: "f%02d.txt", $0), path: "/tmp/b09/f\($0)") }
    updateList(list, entries: entries, mode: .details, selected: [entries[49].path], focused: entries[49].path)
    recorder.lastFocused = nil
    list.selectAllEntries()
    try require(
        recorder.lastFocused == entries[49].path || recorder.lastFocused == nil,
        "selectAllEntries reports the FIRST entry as focused, and update() scrolls to it: "
        + "Cmd-A at the bottom of a folder snaps the viewport to the top "
        + "(FileListView.swift:786 → 352-354). Got focus: \(recorder.lastFocused ?? "nil")"
    )
}

// MARK: - B10: Rename editor leaks via a closure retain cycle

await runTest("B10 rename: editor deallocates after commit") {
    weak var weakEditor: RenameTextField?
    try autoreleasepool {
        let list = FileListView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let recorder = RecordingDelegate()
        list.delegate = recorder
        let entry = makeEntry("old.txt", path: "/tmp/b10/old.txt")
        updateList(list, entries: [entry], mode: .details)
        updateList(list, entries: [entry], mode: .details, renamingPath: entry.path)
        pump(0.2)
        guard let editor = firstView(RenameTextField.self, in: list) else {
            throw TestFailure(message: "rename editor was not created")
        }
        weakEditor = editor
        editor.onCommit?("new.txt")
        updateList(list, entries: [entry], mode: .details)
        pump(0.2)
    }
    try require(
        weakEditor == nil,
        "the rename editor is still alive after commit: onCommit/onCancel capture `editor` "
        + "strongly while the editor retains the closures — a retain cycle that leaks one "
        + "NSTextField per rename (FileListView.swift:1234-1243)."
    )
}

// MARK: - B11: Duplicates dialog drops rows even when the trash fails

await runTest("B11 duplicates: rows stay visible when the trash operation fails") {
    let dir = try makeTempDir("b11")
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeText("same content", to: dir.appendingPathComponent("dup-a.txt"))
    try writeText("same content", to: dir.appendingPathComponent("dup-b.txt"))

    let overlay = DuplicatesOverlay(root: dir.path, showHidden: false)
    var trashedPaths: [String] = []
    overlay.onTrash = { _, completion in
        trashedPaths = []
        completion([])
    }
    guard let table = firstView(NSTableView.self, in: overlay) else {
        throw TestFailure(message: "table not found")
    }
    let scanned = waitFor(10) { table.numberOfRows > 0 }
    if !scanned {
        let direct = DuplicateFinder.scan(root: dir.path, showHidden: false)
        throw TestFailure(message: "setup: duplicate scan produced no rows; labels=\(allLabelTexts(in: overlay)); direct scan groups=\(direct.groups.count) scanned=\(direct.scannedFiles)")
    }
    let rowsBefore = table.numberOfRows
    guard let selectButton = firstView(NSButton.self, in: overlay, where: { $0.title == "Select extra copies" }),
          let trashButton = firstView(NSButton.self, in: overlay, where: { $0.title.contains("Trash") }) else {
        throw TestFailure(message: "buttons not found")
    }
    selectButton.performClick(nil)
    trashButton.performClick(nil)
    pump(0.2)
    try require(trashedPaths.isEmpty, "setup: nothing should have been trashed")
    try require(
        table.numberOfRows == rowsBefore,
        "the dialog removed the group from the results even though nothing was trashed "
        + "(\(rowsBefore) rows → \(table.numberOfRows)): trashPressed prunes groups before the "
        + "async trash reports success, so failed files silently vanish "
        + "(DuplicatesOverlay.swift:224-230)."
    )
}

// MARK: - B12: Search box keeps the previous tab's query

await runTest("B12 search field: switching tabs clears the focused search box") {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 44),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    defer { window.close() }
    let navBar = NavigationBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 44))
    window.contentView = navBar
    guard let field = firstView(SearchField.self, in: navBar) else {
        throw TestFailure(message: "search field not found")
    }
    window.makeFirstResponder(field)
    if field.currentEditor() == nil { field.selectText(nil) }
    try require(field.currentEditor() != nil, "setup: could not start editing the search field")
    field.stringValue = "report" // user typed this in tab 1
    // User clicks tab 2 (location changes, searchQuery is ""), field still focused.
    navBar.update(
        location: .fs(path: "/tmp/tab2"), system: nil,
        canBack: false, canForward: false, canUp: false,
        searchEnabled: true, searchValue: "", sidebarVisible: true
    )
    try require(
        field.stringValue.isEmpty,
        "the box still shows tab 1's query 'report' while tab 2 is active: the sync guard "
        + "skips any update while the field is first responder, even when the location changed "
        + "(NavigationBarView.swift:172-174). Next keystroke searches tab 2 for 'reportX'."
    )
}

// MARK: - B13: Sidebar toggle button never shows its active state

await runTest("B13 nav bar: sidebar button reflects sidebarVisible") {
    let navBar = NavigationBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 44))
    navBar.update(
        location: .fs(path: "/tmp"), system: nil,
        canBack: false, canForward: false, canUp: false,
        searchEnabled: true, searchValue: "", sidebarVisible: true
    )
    guard let button = firstView(IconButton.self, in: navBar, where: { $0.accessibilityLabel() == "Navigation pane" }) else {
        throw TestFailure(message: "sidebar button not found")
    }
    try require(
        button.isActive,
        "update() receives sidebarVisible but hard-codes isActive = false, so the Navigation "
        + "pane button never looks active (NavigationBarView.swift:163,170-171)."
    )
}

// MARK: - B14: Search results from Home cannot be deleted

await runTest("B14 home search: Delete works on real files found from Home") {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MacExplorerBugTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("delete-me-\(UUID().uuidString).txt")
    try writeText("x", to: file)

    let controller = BrowserWindowController(location: .home)
    defer { controller.window?.close() }
    pump(0.3)
    guard let content = controller.window?.contentView,
          let searchField = firstView(SearchField.self, in: content) else {
        throw TestFailure(message: "Home search field not found")
    }
    searchField.onTextChange?(file.lastPathComponent)
    try require(waitFor(20) {
        guard let list = firstView(FileListView.self, in: content) else { return false }
        return list.currentEntry(forPath: file.path) != nil
    }, "real Home search did not return the test file")
    controller.fileListSelectionDidChange([file.path], focused: file.path)
    guard let rename = firstView(NSButton.self, in: content, where: { $0.title == "Rename" }) else {
        throw TestFailure(message: "Rename button missing")
    }
    rename.performClick(nil)
    pump(0.2)
    guard let editor = firstView(RenameTextField.self, in: content) else {
        throw TestFailure(message: "Rename on a Home search result did not open an editor")
    }
    editor.onCancel?()
    controller.deleteAction(nil)
    controller.sidebarNewTab(path: dir.path)
    _ = waitFor(3) { !FileManager.default.fileExists(atPath: file.path) }
    pump(0.3)
    controller.titleBarCloseTab(1)
    try require(searchField.stringValue == file.lastPathComponent, "activation did not immediately restore the search field")
    pump(0.5)
    try require(
        firstView(FileListView.self, in: content)?.currentEntry(forPath: file.path) == nil,
        "closing the active tab exposed deleted Home search results"
    )
    for item in AppStore.shared.lastDeleted ?? [] {
        try? FileManager.default.removeItem(atPath: item.trashPath)
    }
    try require(
        !FileManager.default.fileExists(atPath: file.path),
        "Delete silently no-ops on Home search results: trashSelection guards on "
        + "activeTab.location.writePath, which is nil for .home even though the selected "
        + "results are real files (BrowserWindowController.swift:1511-1513, Models.swift:183-186)."
    )
}

// MARK: - B15: An active archive tab blocks unrelated external drops

await runTest("B15 archive: external drop onto a sidebar folder works while browsing a zip") {
    let dir = try makeTempDir("b15")
    defer { try? FileManager.default.removeItem(at: dir) }
    let payload = dir.appendingPathComponent("payload.txt")
    try writeText("payload", to: payload)
    let zip = FileService.compressToArchive([payload.path])
    guard zip.ok, let zipPath = zip.path else { throw TestFailure(message: "setup: zip failed") }
    let external = dir.appendingPathComponent("external.txt")
    try writeText("external", to: external)
    let destination = dir.appendingPathComponent("Destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let controller = BrowserWindowController(location: .fs(path: dir.path))
    defer { controller.window?.close() }
    pump(0.3)
    guard let zipEntry = FileService.entry(name: PathTools.basename(zipPath), path: zipPath) else {
        throw TestFailure(message: "setup: no zip entry")
    }
    let probe = ArchiveService.openArchive(zipPath)
    try require(probe.ok, "setup: direct archive open failed: \(probe.error ?? "?")")
    controller.fileListOpen(zipEntry)
    guard let window = controller.window, let content = window.contentView else {
        throw TestFailure(message: "no window")
    }
    let opened = waitFor(15) {
        firstView(NSButton.self, in: content, where: { $0.title == "Extract all" }) != nil
    }
    if !opened {
        throw TestFailure(message: "setup: archive tab did not open; labels=\(allLabelTexts(in: content).prefix(20))")
    }
    // Drag an unrelated file from the Desktop onto a real sidebar folder.
    controller.sidebarDrop(paths: [external.path], destination: destination.path, copy: true)
    let copied = waitFor(5) {
        FileManager.default.fileExists(atPath: destination.appendingPathComponent("external.txt").path)
    }
    try require(
        copied,
        "the drop was silently discarded: transfer() guards on activeTab.location.isArchive "
        + "even though neither the dragged file nor the destination is inside the archive "
        + "(BrowserWindowController.swift:1433-1434)."
    )
}

// MARK: - B16: Pinning a folder collapses the expanded sidebar tree

await runTest("B16 sidebar: pinning a folder keeps the tree expanded") {
    let parent = try makeTempDir("b16parent")
    let other = try makeTempDir("b16other")
    defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: other) }
    let child = parent.appendingPathComponent("Child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

    let controller = BrowserWindowController(location: .fs(path: parent.path))
    defer { controller.window?.close() }
    pump(0.3)
    controller.sidebarTogglePin(path: parent.path) // pin + render
    pump(0.2)
    guard let content = controller.window?.contentView,
          let outline = firstView(NSOutlineView.self, in: content) else {
        throw TestFailure(message: "outline not found")
    }
    @MainActor func node(forPath path: String) -> SidebarNode? {
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarNode, node.path == path { return node }
        }
        return nil
    }
    guard let pinnedNode = node(forPath: parent.path) else {
        throw TestFailure(message: "setup: pinned folder not visible in sidebar")
    }
    outline.expandItem(pinnedNode)
    pump(0.2)
    try require(outline.isItemExpanded(pinnedNode), "setup: folder did not expand")
    let widthBefore = outline.view(atColumn: 0, row: outline.row(forItem: pinnedNode), makeIfNecessary: true)?.frame.width ?? 0
    controller.sidebarTogglePin(path: other.path) // pin something else → render
    pump(0.2)
    guard let sameNode = node(forPath: parent.path) else {
        throw TestFailure(message: "pinned folder disappeared after second pin")
    }
    if let cell = outline.view(atColumn: 0, row: outline.row(forItem: sameNode), makeIfNecessary: true) {
        try require(cell.frame.width >= widthBefore, "sidebar reload narrowed the folder cell from \(widthBefore) to \(cell.frame.width)")
    }
    try require(
        outline.isItemExpanded(sameNode),
        "the whole sidebar tree collapsed after pinning another folder: render() recreates "
        + "every SidebarNode and reloadData() only preserves expansion by identity "
        + "(SidebarView.swift:129,144-188). Same happens on every volume mount/unmount."
    )
}

await runTest("R01 wildcard: Unicode graphemes, escapes and brackets retain glob behavior") {
    for (pattern, name, expected) in [
        ("?.txt", "👩‍💻.txt", true), ("??.txt", "👩‍💻.txt", false),
        ("*語?.txt", "日本語文.txt", true), ("[日中]*.txt", "日本.txt", true),
        ("[!日]*.txt", "日本.txt", false), ("\\?.txt", "?.txt", true),
        ("a[0-9]?.txt", "a1語.txt", true), ("*.txt", "a.csv", false)
    ] {
        let query = SearchQuery(terms: [pattern])
        try require(query.matchesName(name) == expected, "glob \(pattern) against \(name)")
    }
}

await runTest("R02 properties: cancellation prevents folder traversal") {
    let dir = try makeTempDir("r02")
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeText("x", to: dir.appendingPathComponent("child.txt"))
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return FileService.properties([dir.path])
    }
    let result = await task.value
    try require(!result.ok, "cancelled properties task still completed the scan")
}

await runTest("R03 properties: regular files and symlinks retain their sizes and flags") {
    let dir = try makeTempDir("r03")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("file.txt")
    let link = dir.appendingPathComponent("link.txt")
    try writeText("hello", to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let regular = FileService.properties([file.path])
    let symbolic = FileService.properties([link.path])
    try require(regular.ok && regular.size == 5 && !regular.isSymlink, "regular file properties changed")
    try require(symbolic.ok && symbolic.size == 5 && symbolic.isSymlink, "symlink properties changed")
}

await runTest("R04 tabs: clearing an invalidated background search reloads its folder") {
    let dir = try makeTempDir("r04")
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("target.txt")
    let survivor = dir.appendingPathComponent("survivor.txt")
    try writeText("x", to: file)
    try writeText("x", to: survivor)
    let controller = BrowserWindowController(location: .fs(path: dir.path))
    defer { controller.window?.close() }
    pump(0.3)
    guard let content = controller.window?.contentView,
          let search = firstView(SearchField.self, in: content) else {
        throw TestFailure(message: "search field missing")
    }
    search.onTextChange?("target")
    try require(waitFor(5) {
        firstView(FileListView.self, in: content)?.currentEntry(forPath: file.path) != nil
    }, "search did not find target")
    pump(0.3)
    controller.fileListSelectionDidChange([file.path], focused: file.path)
    controller.deleteAction(nil)
    controller.sidebarNewTab(path: dir.path)
    try require(waitFor(5) { !FileManager.default.fileExists(atPath: file.path) }, "delete failed")
    pump(0.3)
    controller.titleBarActivateTab(0)
    pump(0.5)
    search.onTextChange?("")
    try require(waitFor(5) {
        firstView(FileListView.self, in: content)?.currentEntry(forPath: survivor.path) != nil
    }, "clearing search left the underlying folder empty")
    for item in AppStore.shared.lastDeleted ?? [] {
        try? FileManager.default.removeItem(atPath: item.trashPath)
    }
}

// MARK: - Summary

if onlyFilter == nil {
    print("")
    print("——————————————————————————————")
    print("Sanity + bug-reproduction results: \(passCount) passed, \(failCount) failed")
    print("All tests assert corrected behavior and must pass.")
    for line in resultLines { print(line) }
}
exit(failCount == 0 ? 0 : 1)