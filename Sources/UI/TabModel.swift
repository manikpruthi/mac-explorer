import AppKit

@MainActor
final class TabModel {
    let id = UUID()
    var location: Location
    var history: [Location]
    var historyIndex: Int
    var view: ViewMode
    var sortKey: SortKey = .name
    var sortDir: SortDir = .asc
    var selected: Set<String> = []
    var focusedPath: String?
    var entries: [FileEntry] = [] { didSet { contentVersion &+= 1 } }
    var loading = false
    var pathError: String?
    var permissionError = false
    var searchQuery = ""
    var searchEntries: [FileEntry] = [] { didSet { contentVersion &+= 1 } }
    var searchLoading = false
    var searchTruncated = false
    var searchRoot = ""

    private struct VisibleKey: Equatable {
        var version: UInt64
        var searching: Bool
        var sortKey: SortKey
        var sortDir: SortDir
        var showHidden: Bool
        var showExtensions: Bool
    }

    private var contentVersion: UInt64 = 0
    private var visibleKey: VisibleKey?
    private var visibleCache: [FileEntry] = []

    /// Filtered + sorted entries, recomputed only when the inputs change.
    func visibleEntries(showHidden: Bool, showExtensions: Bool) -> [FileEntry] {
        let key = VisibleKey(
            version: contentVersion,
            searching: isSearching,
            sortKey: sortKey,
            sortDir: sortDir,
            showHidden: showHidden,
            showExtensions: showExtensions
        )
        if key == visibleKey { return visibleCache }
        let source = isSearching ? searchEntries : entries
        let filtered = showHidden ? source : source.filter { !$0.hidden }
        visibleCache = sortEntries(filtered, key: sortKey, dir: sortDir, showExtensions: showExtensions)
        visibleKey = key
        return visibleCache
    }

    init(location: Location, view: ViewMode) {
        self.location = location
        self.history = [location]
        self.historyIndex = 0
        self.view = view
    }

    var isSearching: Bool { !searchQuery.isEmpty }

    func push(_ location: Location) {
        let truncated = Array(history.prefix(historyIndex + 1))
        history = truncated + [location]
        historyIndex = history.count - 1
        self.location = location
        selected = []
        focusedPath = nil
        entries = []
        pathError = nil
        permissionError = false
        searchQuery = ""
        searchEntries = []
        searchLoading = false
        searchTruncated = false
        searchRoot = ""
    }

    func goHistory(_ delta: Int) {
        let target = historyIndex + delta
        guard target >= 0, target < history.count else { return }
        historyIndex = target
        location = history[target]
        selected = []
        focusedPath = nil
        entries = []
        pathError = nil
        permissionError = false
        searchQuery = ""
        searchEntries = []
        searchLoading = false
        searchTruncated = false
        searchRoot = ""
    }
}
