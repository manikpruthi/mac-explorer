import AppKit

enum MarqueePhase {
    case begin
    case drag
    case end
}

@MainActor
protocol FileListViewDelegate: AnyObject {
    func fileListSelectionDidChange(_ paths: [String], focused: String?)
    func fileListMarqueeSelection(_ paths: [String])
    func fileListOpen(_ entry: FileEntry)
    func fileListContextMenu(entry: FileEntry?, event: NSEvent)
    func fileListBackgroundClick()
    func fileListToggleSelection(_ path: String)
    func fileListRename(_ entry: FileEntry, to name: String)
    func fileListCancelRename()
    func fileListDrop(paths: [String], destination: String?, copy: Bool)
    func fileListSort(_ key: SortKey)
    func fileListNewFolder()
    func fileListRetry()
    func fileListOpenPrivacy()
    func fileListAddRecent(_ entry: FileEntry)
}

@MainActor
final class FileListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let dragType = NSPasteboard.PasteboardType("tools.macexplorer.paths")

    weak var delegate: FileListViewDelegate?

    private let tableScroll = MarqueeScrollView()
    private let tableView = FileTableView()
    private let collectionScroll = MarqueeScrollView()
    private let collectionView = IconCollectionView()
    private let stateContainer = FlippedView()

    private var entries: [FileEntry] = []
    private var mode: ViewMode = .details
    private var selected: Set<String> = []
    private var focusedPath: String?
    private var renamingPath: String?
    /// Forces the next update() to reload every cell (first load, appearance change).
    private var needsFullReload = true
    /// Selection/focus as of the last update(); the view mutates `selected`/`focusedPath`
    /// itself on clicks, so diffs must be against what the cells were last configured with.
    private var renderedSelected: Set<String> = []
    private var renderedFocused: String?
    private var cutPaths: Set<String> = []
    private var showExtensions = false
    private var permissionError = false
    private var errorMessage: String?
    private var loading = false
    private var isSearch = false
    private var syncingSelection = false
    private var hoveredRow = -1
    private var renameEditor: RenameTextField?
    private var renameFrameRetries = 0
    func prepareForRename(_ path: String?) {
        guard let path else { return }
        layoutSubtreeIfNeeded()
        if mode.isGrid || mode == .tiles {
            collectionView.layoutSubtreeIfNeeded()
            if let index = entries.firstIndex(where: { $0.path == path }) {
                collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
            }
        } else if let index = entries.firstIndex(where: { $0.path == path }) {
            tableView.scrollRowToVisible(index)
        }
        layoutSubtreeIfNeeded()
    }
    private var lastFocused: String?
    private var gridIconSize: CGFloat = 80
    private var marqueeStart: NSPoint?
    private var marqueeCurrent = NSPoint.zero
    private var marqueeRect = NSRect.zero
    private var marqueeBase: Set<String> = []
    private var marqueeTimer: Timer?
    private var lastMarqueeNotify = Date.distantPast
    private let marqueeView = ThemedView()
    private var lastTableContentWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.resolved(Theme.content, for: effectiveAppearance).cgColor

        marqueeView.fillColor = Theme.selectionStrong
        marqueeView.strokeColor = Theme.selectionBorder
        marqueeView.borderWidth = 1
        marqueeView.cornerRadius = 2
        marqueeView.isHidden = true

        tableView.dataSource = self
        tableView.delegate = self
        // Native header view supplies the draggable column dividers.
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.style = .plain
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.registerForDraggedTypes([Self.dragType, .fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.onContext = { [weak self] row, event in
            self?.handleTableContext(row: row, event: event)
        }
        tableView.onRowHover = { [weak self] row in
            guard let self, self.hoveredRow != row else { return }
            let previous = self.hoveredRow
            self.hoveredRow = row
            if previous >= 0 { self.updateRowHover(row: previous, isHovered: false) }
            if row >= 0 { self.updateRowHover(row: row, isHovered: true) }
        }
        tableView.onMarquee = { [weak self] phase, event in
            self?.handleMarquee(phase, event: event) ?? false
        }
        tableScroll.documentView = tableView
        addSubview(tableScroll)

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 12, left: 14, bottom: 24, right: 14)
        collectionView.collectionViewLayout = layout
        collectionView.registerForDraggedTypes([Self.dragType, .fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy], forLocal: false)
        collectionView.onContext = { [weak self] indexPath, event in
            self?.handleCollectionContext(indexPath: indexPath, event: event)
        }
        collectionView.onMarquee = { [weak self] phase, event in
            self?.handleMarquee(phase, event: event) ?? false
        }
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleCollectionDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)
        collectionScroll.documentView = collectionView
        collectionScroll.isHidden = true
        addSubview(collectionScroll)

        addSubview(stateContainer)
        configureColumns()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureColumns() {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        lastTableContentWidth = 0
        switch mode {
        case .details:
            let specs: [
                (id: String, title: String, width: CGFloat, minWidth: CGFloat,
                 alignment: NSTextAlignment, leading: CGFloat, trailing: CGFloat)
            ] = [
                ("name", "Name", 560, 240, .left, 20, 8),
                ("modified", "Date modified", 200, 140, .left, 8, 8),
                ("type", "Type", 180, 120, .left, 8, 8),
                ("size", "Size", 100, 80, .right, 8, 10),
            ]
            for (index, spec) in specs.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
                column.width = spec.width
                column.minWidth = spec.minWidth
                column.maxWidth = 2000
                column.resizingMask = index == 0
                    ? [.userResizingMask, .autoresizingMask]
                    : [.userResizingMask]
                let headerCell = FileHeaderCell()
                headerCell.stringValue = spec.title
                headerCell.font = NSFont.systemFont(ofSize: 12)
                headerCell.alignment = spec.alignment
                headerCell.leadingPadding = spec.leading
                headerCell.trailingPadding = spec.trailing
                column.headerCell = headerCell
                tableView.addTableColumn(column)
            }
            if tableView.headerView == nil {
                tableView.headerView = NSTableHeaderView()
            }
            tableView.headerView?.isHidden = false
            tableView.rowHeight = 30
        case .tiles:
            tableView.headerView = nil
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.resizingMask = [.userResizingMask, .autoresizingMask]
            column.title = "Name"
            tableView.addTableColumn(column)
            tableView.rowHeight = 64
        default:
            // Windows' List view has no column header; only Details does.
            tableView.headerView = nil
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.resizingMask = [.userResizingMask, .autoresizingMask]
            column.title = "Name"
            tableView.addTableColumn(column)
            tableView.rowHeight = 30
        }
    }

    private func sortKeyForColumn(_ column: NSTableColumn) -> SortKey? {
        switch column.identifier.rawValue {
        case "name": return .name
        case "modified": return .modified
        case "type": return .type
        case "size": return .size
        default: return nil
        }
    }

    private func syncHeader(sortKey: SortKey, sortDir: SortDir) {
        for column in tableView.tableColumns {
            guard let cell = column.headerCell as? FileHeaderCell else { continue }
            cell.isSorted = sortKeyForColumn(column) == sortKey
            cell.sortAscending = sortDir == .asc
        }
        tableView.headerView?.needsDisplay = true
    }

    func update(
        entries: [FileEntry],
        mode: ViewMode,
        selected: Set<String>,
        focused: String?,
        renamingPath: String?,
        cutPaths: Set<String>,
        showExtensions: Bool,
        sortKey: SortKey,
        sortDir: SortDir,
        loading: Bool,
        errorMessage: String?,
        permissionError: Bool,
        isSearch: Bool
    ) {
        layer?.backgroundColor = Theme.resolved(Theme.content, for: effectiveAppearance).cgColor
        cancelMarquee()
        let modeChanged = mode != self.mode
        // A selection/focus-only change refreshes just the affected cells instead of
        // reloading the whole table or grid.
        let needsReload = needsFullReload
            || modeChanged
            || isSearch != self.isSearch
            || showExtensions != self.showExtensions
            || cutPaths != self.cutPaths
            || entries != self.entries
        var changedPaths = selected.symmetricDifference(renderedSelected)
        if focused != renderedFocused {
            if let old = renderedFocused { changedPaths.insert(old) }
            if let focused { changedPaths.insert(focused) }
        }
        renderedSelected = selected
        renderedFocused = focused
        self.entries = entries
        self.selected = selected
        self.showExtensions = showExtensions
        self.cutPaths = cutPaths
        self.errorMessage = errorMessage
        self.permissionError = permissionError
        self.loading = loading
        self.mode = mode
        self.isSearch = isSearch
        if modeChanged {
            configureColumns()
        }

        let showGrid = mode.isGrid || mode == .tiles
        collectionScroll.isHidden = !showGrid
        tableScroll.isHidden = showGrid

        let showError = errorMessage != nil
        let showEmpty = errorMessage == nil && entries.isEmpty && !loading
        let showLoading = errorMessage == nil && entries.isEmpty && loading
        stateContainer.isHidden = !(showError || showEmpty || showLoading)

        if showError {
            buildErrorState()
        } else if showEmpty {
            buildEmptyState()
        } else if showLoading {
            buildLoadingState()
        }

        self.focusedPath = focused
        let changedIndexes: IndexSet = needsReload || changedPaths.isEmpty
            ? IndexSet()
            : IndexSet(entries.indices.filter { changedPaths.contains(entries[$0].path) })
        if showGrid {
            if needsReload {
                updateGridLayout()
                collectionView.reloadData()
            } else if !changedIndexes.isEmpty {
                collectionView.reloadItems(at: Set(changedIndexes.map { IndexPath(item: $0, section: 0) }))
            }
            syncCollectionSelection()
        } else {
            if needsReload {
                tableView.reloadData()
            } else if !changedIndexes.isEmpty {
                tableView.reloadData(
                    forRowIndexes: changedIndexes,
                    columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                )
            }
            syncTableSelection()
        }
        needsFullReload = false
        if let focused, focused != lastFocused {
            scrollToFocused(focused)
        }
        lastFocused = focused
        syncRenameEditor(renamingPath)
        syncHeader(sortKey: sortKey, sortDir: sortDir)
        needsLayout = true
    }

    private func updateGridLayout() {
        gridIconSize = mode == .medium ? 48 : (mode == .tiles ? 44 : 80)
        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            let size: NSSize
            switch mode {
            case .medium: size = NSSize(width: 98, height: 92)
            case .tiles: size = NSSize(width: 250, height: 64)
            default: size = NSSize(width: 124, height: 132)
            }
            layout.itemSize = size
            layout.minimumInteritemSpacing = mode == .tiles ? 4 : 2
            layout.minimumLineSpacing = mode == .tiles ? 4 : 2
            layout.invalidateLayout()
        }
    }

    private func syncTableSelection() {
        syncingSelection = true
        var indexes = IndexSet()
        for (index, entry) in entries.enumerated() where selected.contains(entry.path) {
            indexes.insert(index)
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        // The table uses selectionHighlightStyle = .none, so row views draw their own
        // tint. Refresh every visible row explicitly; relying on selectRowIndexes alone
        // can leave the first row of an upward marquee drag un-highlighted until mouse-up.
        refreshTableSelectionVisuals()
        syncingSelection = false
    }

    private func refreshTableSelectionVisuals() {
        for row in 0..<tableView.numberOfRows where row < entries.count {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? FileRowView else { continue }
            let highlighted = selected.contains(entries[row].path)
            let focused = entries[row].path == focusedPath
            if rowView.marqueeSelected != highlighted {
                rowView.marqueeSelected = highlighted
                rowView.needsDisplay = true
            }
            if rowView.isFocused != focused {
                rowView.isFocused = focused
                rowView.needsDisplay = true
            }
        }
    }

    private func syncCollectionSelection() {
        syncingSelection = true
        var paths = Set<IndexPath>()
        for (index, entry) in entries.enumerated() where selected.contains(entry.path) {
            paths.insert(IndexPath(item: index, section: 0))
        }
        collectionView.selectionIndexPaths = paths
        // NSCollectionViewItem does not automatically forward programmatic selection
        // changes to the custom tile views, so keep visible items in sync as well.
        for item in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: item), indexPath.item < entries.count else { continue }
            let highlighted = selected.contains(entries[indexPath.item].path)
            if let iconItem = item as? FileIconItemView {
                iconItem.isSelected = highlighted
            } else if let tileItem = item as? FileTileItemView {
                tileItem.isSelected = highlighted
            }
        }
        syncingSelection = false
    }

    private func scrollToFocused(_ path: String) {
        if mode.isGrid || mode == .tiles {
            if let index = entries.firstIndex(where: { $0.path == path }) {
                collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
            }
        } else if let index = entries.firstIndex(where: { $0.path == path }) {
            tableView.scrollRowToVisible(index)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Theme.resolved(Theme.content, for: effectiveAppearance).cgColor
        needsFullReload = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelMarquee()
        }
    }

    override func layout() {
        super.layout()
        stateContainer.frame = bounds
        tableScroll.frame = bounds
        collectionScroll.frame = bounds
        layoutStateContainer()
        sizeTableColumnsIfNeeded()
    }

    private func sizeTableColumnsIfNeeded() {
        guard !mode.isGrid, mode != .tiles, !tableView.tableColumns.isEmpty else { return }
        let contentWidth = tableScroll.contentSize.width
        guard contentWidth > 0 else { return }
        guard abs(contentWidth - lastTableContentWidth) > 0.5 else { return }
        lastTableContentWidth = contentWidth
        if abs(tableView.frame.width - contentWidth) > 0.5 {
            tableView.setFrameSize(NSSize(width: contentWidth, height: tableView.frame.height))
        }
        // AppKit's automatic column sizing only runs when explicitly asked. This fills
        // the flexible Name column while preserving the widths of the other columns;
        // user-dragged widths survive until the pane itself is resized.
        tableView.sizeToFit()
    }

    // MARK: - Table data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRowView()
        guard row >= 0, row < entries.count else { return view }
        view.isFocused = entries[row].path == focusedPath
        view.cut = cutPaths.contains(entries[row].path)
        view.hovered = row == hoveredRow
        view.marqueeSelected = selected.contains(entries[row].path)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let identifier = tableColumn?.identifier.rawValue ?? "name"
        if mode == .details && identifier != "name" {
            let cellIdentifier = NSUserInterfaceItemIdentifier("text-\(identifier)")
            let cell: TableTextCellView
            if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? TableTextCellView {
                cell = reused
            } else {
                cell = TableTextCellView()
                cell.identifier = cellIdentifier
            }
            let text: String
            switch identifier {
            case "modified": text = FormatTools.date(entry.modified)
            case "type": text = FileKinds.typeLabel(entry.name, entry.isDirectory)
            case "size": text = entry.isDirectory ? "" : FormatTools.bytes(entry.size)
            default: text = ""
            }
            cell.trailingPadding = identifier == "size" ? 10 : 8
            cell.configure(text: text, alignment: identifier == "size" ? .right : .left)
            return cell
        }

        let cellIdentifier = NSUserInterfaceItemIdentifier(mode == .tiles ? "tile-cell" : "name-cell")
        let cell: NameCellView
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NameCellView {
            cell = reused
        } else {
            cell = NameCellView(style: mode == .tiles ? .tile : .row)
            cell.identifier = cellIdentifier
        }
        let isSelected = selected.contains(entry.path)
        cell.configure(
            entry: entry,
            selected: isSelected,
            focused: entry.path == focusedPath,
            cut: cutPaths.contains(entry.path),
            showExtensions: showExtensions,
            showMeta: mode == .tiles,
            hovered: row == hoveredRow
        )
        cell.onToggle = { [weak self] in
            self?.delegate?.fileListToggleSelection(entry.path)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let key = sortKeyForColumn(tableColumn) else { return }
        delegate?.fileListSort(key)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let paths = tableView.selectedRowIndexes.compactMap { index in
            index < entries.count ? entries[index].path : nil
        }
        selected = Set(paths)
        let focusedRow = tableView.selectedRow
        let focused = focusedRow >= 0 && focusedRow < entries.count ? entries[focusedRow].path : nil
        self.focusedPath = focused
        refreshTableSelectionVisuals()
        delegate?.fileListSelectionDidChange(paths, focused: focused)
    }

    @objc private func handleCollectionDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let entry = entry(atCollection: indexPath) else { return }
        delegate?.fileListAddRecent(entry)
        delegate?.fileListOpen(entry)
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        delegate?.fileListAddRecent(entries[row])
        delegate?.fileListOpen(entries[row])
    }

    private func updateRowHover(row: Int, isHovered: Bool) {
        guard row >= 0, row < entries.count else { return }
        if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? FileRowView {
            rowView.hovered = isHovered
        }
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView {
            cell.setHovered(isHovered)
        }
    }

    private func handleTableContext(row: Int, event: NSEvent) {
        if row >= 0 && row < entries.count {
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            delegate?.fileListContextMenu(entry: entries[row], event: event)
        } else {
            if !tableView.selectedRowIndexes.isEmpty {
                tableView.deselectAll(nil)
            }
            delegate?.fileListContextMenu(entry: nil, event: event)
        }
    }

    // MARK: - Collection data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard indexPath.item < entries.count else {
            let empty = FileIconItemView()
            _ = empty.view
            return empty
        }
        let entry = entries[indexPath.item]
        if mode == .tiles {
            let item = FileTileItemView()
            _ = item.view
            item.configure(
                entry: entry,
                selected: selected.contains(entry.path),
                focused: entry.path == focusedPath,
                cut: cutPaths.contains(entry.path),
                showExtensions: showExtensions
            )
            item.onToggle = { [weak self] in
                self?.delegate?.fileListToggleSelection(entry.path)
            }
            return item
        }
        let item = FileIconItemView()
        _ = item.view
        item.configure(
            entry: entry,
            iconSize: gridIconSize,
            selected: selected.contains(entry.path),
            focused: entry.path == focusedPath,
            cut: cutPaths.contains(entry.path),
            showExtensions: showExtensions
        )
        item.onToggle = { [weak self] in
            self?.delegate?.fileListToggleSelection(entry.path)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !syncingSelection else { return }
        publishCollectionSelection(focus: indexPaths.first)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !syncingSelection else { return }
        publishCollectionSelection(focus: nil)
    }

    private func publishCollectionSelection(focus: IndexPath?) {
        let paths = collectionView.selectionIndexPaths.compactMap { path -> String? in
            path.item < entries.count ? entries[path.item].path : nil
        }
        var focusedPath: String?
        if let focus, focus.item < entries.count {
            focusedPath = entries[focus.item].path
        } else if let focused = self.focusedPath, paths.contains(focused) {
            focusedPath = focused
        } else {
            focusedPath = paths.last
        }
        self.focusedPath = focusedPath
        selected = Set(paths)
        delegate?.fileListSelectionDidChange(paths, focused: focusedPath)
    }

    private func entry(atCollection indexPath: IndexPath) -> FileEntry? {
        indexPath.item < entries.count ? entries[indexPath.item] : nil
    }

    private func handleCollectionContext(indexPath: IndexPath?, event: NSEvent) {
        if let indexPath, indexPath.item < entries.count {
            if !collectionView.selectionIndexPaths.contains(indexPath) {
                collectionView.selectionIndexPaths = [indexPath]
                publishCollectionSelection(focus: indexPath)
            }
            delegate?.fileListContextMenu(entry: entries[indexPath.item], event: event)
        } else {
            collectionView.selectionIndexPaths = []
            delegate?.fileListContextMenu(entry: nil, event: event)
        }
    }

    func moveGridFocus(horizontal: Int, vertical: Int, extend: Bool) {
        guard !entries.isEmpty else { return }
        let itemWidth: CGFloat = mode == .medium ? 98 : (mode == .tiles ? 250 : 124)
        let available = max(itemWidth, collectionView.bounds.width - 28)
        let columns = max(1, Int(available / (itemWidth + 2)))
        var index = focusedPath.flatMap { path in entries.firstIndex(where: { $0.path == path }) } ?? -1
        if index == -1 {
            index = (horizontal < 0 || vertical < 0) ? entries.count - 1 : 0
        } else {
            index += horizontal + vertical * columns
            index = max(0, min(entries.count - 1, index))
        }
        let target = entries[index]
        var paths = selected
        if extend {
            let anchorIndex = focusedPath.flatMap { path in entries.firstIndex(where: { $0.path == path }) } ?? index
            let start = min(anchorIndex, index)
            let end = max(anchorIndex, index)
            paths = Set(entries[start...end].map { $0.path })
        } else {
            paths = [target.path]
        }
        selected = paths
        focusedPath = target.path
        syncCollectionSelection()
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
        delegate?.fileListSelectionDidChange(Array(paths), focused: target.path)
    }

    func selectAllEntries() {
        let paths = Set(entries.map { $0.path })
        selected = paths
        if mode.isGrid || mode == .tiles {
            syncCollectionSelection()
        } else {
            syncTableSelection()
        }
        delegate?.fileListSelectionDidChange(Array(paths), focused: entries.first?.path)
    }

    func deselectAllEntries() {
        selected = []
        if mode.isGrid || mode == .tiles { collectionView.selectionIndexPaths = [] } else { tableView.deselectAll(nil) }
        delegate?.fileListSelectionDidChange([], focused: nil)
    }

    func currentEntry(forPath path: String) -> FileEntry? {
        entries.first(where: { $0.path == path })
    }

    // MARK: - Marquee selection

    @discardableResult
    func beginMarquee(at point: NSPoint, extend: Bool) -> Bool {
        guard renamingPath == nil, !entries.isEmpty, let host = marqueeHost() else { return false }
        layoutSubtreeIfNeeded()
        let anchor = host.convert(point, from: self)
        guard marqueeItemIndex(at: anchor) == nil else { return false }
        marqueeBase = extend ? selected : []
        marqueeStart = point
        marqueeCurrent = point
        marqueeRect = .zero
        if !extend {
            selected = []
            syncMarqueeVisuals()
        }
        marqueeView.frame = .zero
        marqueeView.isHidden = false
        host.addSubview(marqueeView)
        startMarqueeTimer()
        window?.makeFirstResponder(host)
        return true
    }

    func updateMarquee(to point: NSPoint) {
        guard marqueeStart != nil else { return }
        marqueeCurrent = point
        applyMarquee()
    }

    func endMarquee() {
        guard marqueeStart != nil else { return }
        marqueeStart = nil
        stopMarqueeTimer()
        marqueeView.removeFromSuperview()
        marqueeView.isHidden = true
        let moved = marqueeRect.width > 3 || marqueeRect.height > 3
        if moved {
            let focused = focusedPath.flatMap { selected.contains($0) ? $0 : nil }
            delegate?.fileListSelectionDidChange(Array(selected), focused: focused)
        } else {
            if marqueeBase.isEmpty {
                selected = []
                focusedPath = nil
                syncMarqueeVisuals()
                delegate?.fileListBackgroundClick()
            } else {
                selected = marqueeBase
                syncMarqueeVisuals()
                delegate?.fileListSelectionDidChange(Array(selected), focused: focusedPath)
            }
        }
    }

    private func cancelMarquee() {
        guard marqueeStart != nil else { return }
        marqueeStart = nil
        stopMarqueeTimer()
        marqueeView.removeFromSuperview()
        marqueeView.isHidden = true
    }

    private func applyMarquee() {
        guard let start = marqueeStart, let host = marqueeHost() else { return }
        let anchor = host.convert(start, from: self)
        let tip = host.convert(marqueeCurrent, from: self)
        let rect = NSRect(
            x: min(anchor.x, tip.x),
            y: min(anchor.y, tip.y),
            width: abs(tip.x - anchor.x),
            height: abs(tip.y - anchor.y)
        )
        marqueeRect = rect
        marqueeView.frame = rect
        let hitRect = NSRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: max(rect.height, 1))
        var next = marqueeBase
        for (index, entry) in entries.enumerated() {
            guard let frame = marqueeItemFrame(at: index), frame.intersects(hitRect) else { continue }
            next.insert(entry.path)
        }
        guard next != selected else { return }
        selected = next
        syncMarqueeVisuals()
        let now = Date()
        if now.timeIntervalSince(lastMarqueeNotify) > 0.12 {
            lastMarqueeNotify = now
            delegate?.fileListMarqueeSelection(Array(next))
        }
    }

    private func marqueeItemFrame(at index: Int) -> NSRect? {
        if mode.isGrid || mode == .tiles {
            return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        }
        guard index < tableView.numberOfRows else { return nil }
        return tableView.rect(ofRow: index)
    }

    private func marqueeItemIndex(at hostPoint: NSPoint) -> Int? {
        for (index, _) in entries.enumerated() {
            if let frame = marqueeItemFrame(at: index), frame.contains(hostPoint) {
                return index
            }
        }
        return nil
    }

    private func syncMarqueeVisuals() {
        if mode.isGrid || mode == .tiles {
            syncCollectionSelection()
        } else {
            syncTableSelection()
        }
    }

    private func marqueeHost() -> NSView? {
        if mode.isGrid || mode == .tiles { return collectionView }
        return tableView
    }

    private func marqueeScrollView() -> NSScrollView {
        if mode.isGrid || mode == .tiles { return collectionScroll }
        return tableScroll
    }

    private func startMarqueeTimer() {
        stopMarqueeTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(marqueeTimerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        marqueeTimer = timer
    }

    private func stopMarqueeTimer() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
    }

    @objc private func marqueeTimerFired() {
        guard marqueeStart != nil else { return }
        if !NSApp.isActive {
            endMarquee()
            return
        }
        guard let window, let host = marqueeHost() else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let scroll = marqueeScrollView()
        let visible = scroll.documentVisibleRect
        let hostPoint = host.convert(point, from: self)
        let edge: CGFloat = 24
        var delta: CGFloat = 0
        if hostPoint.y < visible.minY + edge {
            delta = -16
        } else if hostPoint.y > visible.maxY - edge {
            delta = 16
        }
        guard delta != 0 else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y += delta
        let maxOrigin = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
        origin.y = min(max(0, origin.y), maxOrigin)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        updateMarquee(to: point)
    }

    private func handleMarquee(_ phase: MarqueePhase, event: NSEvent) -> Bool {
        switch phase {
        case .begin:
            guard event.clickCount == 1 else { return false }
            return beginMarquee(
                at: convert(event.locationInWindow, from: nil),
                extend: event.modifierFlags.contains(.command)
            )
        case .drag:
            guard marqueeStart != nil else { return false }
            updateMarquee(to: convert(event.locationInWindow, from: nil))
            return true
        case .end:
            guard marqueeStart != nil else { return false }
            endMarquee()
            return true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if handleMarquee(.begin, event: event) { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if handleMarquee(.drag, event: event) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if handleMarquee(.end, event: event) { return }
        super.mouseUp(with: event)
    }

    func screenFrame(forPath path: String) -> NSRect {
        guard let window else { return .zero }
        let localFrame: NSRect
        if mode.isGrid || mode == .tiles {
            guard let index = entries.firstIndex(where: { $0.path == path }),
                  let item = collectionView.item(at: IndexPath(item: index, section: 0)) else { return .zero }
            localFrame = item.view.convert(item.view.bounds, to: nil)
        } else {
            guard let index = entries.firstIndex(where: { $0.path == path }) else { return .zero }
            let rowRect = tableView.rect(ofRow: index)
            let iconRect = NSRect(x: 22, y: rowRect.minY + (rowRect.height - 18) / 2, width: 18, height: 18)
            localFrame = tableView.convert(iconRect, to: nil)
        }
        return window.convertToScreen(localFrame)
    }

    func itemFrame(forPath path: String) -> NSRect? {
        guard let index = entries.firstIndex(where: { $0.path == path }), let host = marqueeHost() else { return nil }
        layoutSubtreeIfNeeded()
        if host === collectionView { collectionView.layoutSubtreeIfNeeded() }
        guard let frame = marqueeItemFrame(at: index) else { return nil }
        return host.convert(frame, to: self)
    }

    // MARK: - Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let paths = selected.contains(entry.path) ? Array(selected) : [entry.path]
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(paths), let json = String(data: data, encoding: .utf8) {
            item.setString(json, forType: Self.dragType)
        }
        item.setString(URL(fileURLWithPath: entry.path).absoluteString, forType: .fileURL)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard acceptsDrag(info) else { return [] }
        if row >= 0 && row < entries.count, entries[row].isDirectory {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return dragOperation(info)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let destination: String?
        if row >= 0 && row < entries.count, entries[row].isDirectory {
            destination = entries[row].path
        } else {
            destination = nil
        }
        return performDrop(info, destination: destination)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < entries.count else { return nil }
        let entry = entries[indexPath.item]
        let paths = selected.contains(entry.path) ? Array(selected) : [entry.path]
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(paths), let json = String(data: data, encoding: .utf8) {
            item.setString(json, forType: Self.dragType)
        }
        item.setString(URL(fileURLWithPath: entry.path).absoluteString, forType: .fileURL)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard acceptsDrag(draggingInfo) else { return [] }
        let item = proposedDropIndexPath.pointee.item
        if item >= 0 && item < entries.count && entries[item].isDirectory {
            proposedDropOperation.pointee = .on
        } else {
            proposedDropOperation.pointee = .before
            proposedDropIndexPath.pointee = NSIndexPath(forItem: -1, inSection: 0)
        }
        return dragOperation(draggingInfo)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let destination: String?
        if indexPath.item >= 0 && indexPath.item < entries.count && entries[indexPath.item].isDirectory {
            destination = entries[indexPath.item].path
        } else {
            destination = nil
        }
        return performDrop(draggingInfo, destination: destination)
    }

    private func acceptsDrag(_ info: NSDraggingInfo) -> Bool {
        let types = info.draggingPasteboard.types ?? []
        return types.contains(Self.dragType) || types.contains(.fileURL)
    }

    private func dragOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let types = info.draggingPasteboard.types ?? []
        let internalDrag = types.contains(Self.dragType)
        if internalDrag && !NSEvent.modifierFlags.contains(.option) {
            return .move
        }
        return .copy
    }

    private func performDrop(_ info: NSDraggingInfo, destination: String?) -> Bool {
        let pasteboard = info.draggingPasteboard
        var paths: [String] = []
        if let json = pasteboard.string(forType: Self.dragType),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            paths = decoded
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            paths = urls.filter { $0.isFileURL }.map { $0.path }
        }
        guard !paths.isEmpty else { return false }
        let internalDrag = pasteboard.types?.contains(Self.dragType) ?? false
        let copy = internalDrag ? NSEvent.modifierFlags.contains(.option) : true
        delegate?.fileListDrop(paths: paths, destination: destination, copy: copy)
        return true
    }

    // MARK: - Rename editor

    private func syncRenameEditor(_ path: String?) {
        if renamingPath == path, renameEditor != nil { return }
        renamingPath = path
        renameEditor?.removeFromSuperview()
        renameEditor = nil
        guard let path, let entry = entries.first(where: { $0.path == path }) else { return }
        layoutSubtreeIfNeeded()
        if mode.isGrid || mode == .tiles {
            collectionView.layoutSubtreeIfNeeded()
        }
        guard let frame = renameFrame(for: entry) else {
            guard renameFrameRetries < 3 else { return }
            renameFrameRetries += 1
            DispatchQueue.main.async { [weak self] in
                self?.syncRenameEditor(path)
            }
            return
        }
        renameFrameRetries = 0
        let editor = RenameTextField()
        editor.stringValue = entry.name
        editor.font = NSFont.systemFont(ofSize: 13)
        editor.onCommit = { [weak self] value in
            self?.renameEditor = nil
            editor.removeFromSuperview()
            self?.delegate?.fileListRename(entry, to: value)
        }
        editor.onCancel = { [weak self] in
            self?.renameEditor = nil
            editor.removeFromSuperview()
            self?.delegate?.fileListCancelRename()
        }
        if mode.isGrid || mode == .tiles {
            collectionView.addSubview(editor)
        } else {
            tableView.addSubview(editor)
        }
        editor.frame = frame
        renameEditor = editor
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(editor)
            if let textEditor = editor.currentEditor() {
                let base = FileKinds.baseName(entry.name).count
                textEditor.selectedRange = NSRange(location: 0, length: base)
            }
        }
    }

    private func renameFrame(for entry: FileEntry) -> NSRect? {
        if mode.isGrid || mode == .tiles {
            layoutSubtreeIfNeeded()
            collectionView.layoutSubtreeIfNeeded()
            guard let index = entries.firstIndex(where: { $0.path == entry.path }) else { return nil }
            let indexPath = IndexPath(item: index, section: 0)
            guard let item = collectionView.item(at: indexPath) else { return nil }
            let itemFrame = item.view.frame
            if mode == .tiles {
                return NSRect(x: itemFrame.minX + 86, y: itemFrame.minY + 10, width: max(60, itemFrame.width - 96), height: 22)
            }
            let width = max(60, itemFrame.width - 12)
            return NSRect(x: itemFrame.minX + 6, y: itemFrame.maxY - 34, width: width, height: 22)
        }
        guard let index = entries.firstIndex(where: { $0.path == entry.path }) else { return nil }
        let rowRect = tableView.rect(ofRow: index)
        let nameWidth = tableView.tableColumns.first?.width ?? 240
        return NSRect(x: 32, y: rowRect.minY + 4, width: max(60, nameWidth - 44), height: 22)
    }

    // MARK: - States

    private func buildLoadingState() {
        stateContainer.subviews.forEach { $0.removeFromSuperview() }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(spinner)
        let label = makeLabel("Working on it…", size: 12.5, color: Theme.textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: stateContainer.centerYAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            label.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
        ])
    }

    private func buildEmptyState() {
        stateContainer.subviews.forEach { $0.removeFromSuperview() }
        let icon = NSImageView()
        icon.image = isSearch ? IconService.shared.genericIcon(kind: .file, size: 64) : IconService.shared.folderIcon(size: 64)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = makeLabel(isSearch ? "No matching items" : "This folder is empty", size: 15, weight: .semibold)
        let subtitle = makeLabel(
            isSearch ? "No results for this search." : "Drop files here or create something new.",
            size: 12.5,
            color: Theme.textSecondary
        )
        let button = HoverButton(title: "New folder", image: nil, target: self, action: #selector(newFolderPressed))
        button.isBordered = true
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.hoverColor = nil
        button.isHidden = isSearch
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(icon)
        stateContainer.addSubview(title)
        stateContainer.addSubview(subtitle)
        stateContainer.addSubview(button)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: stateContainer.centerYAnchor, constant: -60),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
            title.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            subtitle.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            button.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            button.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
        ])
    }

    private func buildErrorState() {
        stateContainer.subviews.forEach { $0.removeFromSuperview() }
        let icon = NSImageView()
        icon.image = Icons.symbol("exclamationmark.triangle", size: 42)
        icon.image?.isTemplate = true
        icon.contentTintColor = Theme.textTertiary
        let title = makeLabel("Can’t access this folder", size: 15, weight: .semibold)
        let message = makeLabel(errorMessage ?? "", size: 12.5, color: Theme.textSecondary, lines: 4)
        message.alignment = .center
        message.maximumNumberOfLines = 4
        message.lineBreakMode = .byWordWrapping
        message.preferredMaxLayoutWidth = 520
        let retry = HoverButton(title: "Try again", image: nil, target: self, action: #selector(retryPressed))
        retry.isBordered = true
        retry.bezelStyle = .rounded
        retry.controlSize = .small
        retry.hoverColor = nil
        let privacy = HoverButton(title: "Privacy settings", image: nil, target: self, action: #selector(privacyPressed))
        privacy.isBordered = true
        privacy.bezelStyle = .rounded
        privacy.controlSize = .small
        privacy.hoverColor = nil
        let row = NSStackView(views: [retry, privacy])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [icon, title, message, row])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(stack)
        privacy.isHidden = !permissionError
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: stateContainer.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    private func layoutStateContainer() {
        stateContainer.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height
        )
    }

    @objc private func newFolderPressed() { delegate?.fileListNewFolder() }
    @objc private func retryPressed() { delegate?.fileListRetry() }
    @objc private func privacyPressed() { delegate?.fileListOpenPrivacy() }
}

// MARK: - Supporting views

@MainActor
final class MarqueeScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self || hit === contentView {
            return documentView
        }
        return hit
    }
}

@MainActor
final class FileTableView: NSTableView {
    var onContext: ((Int, NSEvent) -> Void)?
    var onRowHover: ((Int) -> Void)?
    var onMarquee: ((MarqueePhase, NSEvent) -> Bool)?
    private var tracking: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if onMarquee?(.begin, event) == true { return }
        guard bounds.contains(point) else { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if onMarquee?(.drag, event) == true { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if onMarquee?(.end, event) == true { return }
        super.mouseUp(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: visibleRect,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        onRowHover?(row)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onRowHover?(-1)
        super.mouseExited(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContext?(row(at: convert(event.locationInWindow, from: nil)), event)
        return nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class IconCollectionView: NSCollectionView {
    var onContext: ((IndexPath?, NSEvent) -> Void)?
    var onMarquee: ((MarqueePhase, NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: point) == nil, onMarquee?(.begin, event) == true { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if onMarquee?(.drag, event) == true { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if onMarquee?(.end, event) == true { return }
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContext?(indexPathForItem(at: convert(event.locationInWindow, from: nil)), event)
        return nil
    }
}

@MainActor
final class FileRowView: NSTableRowView {
    var isFocused = false
    var cut = false
    var hovered = false {
        didSet { if oldValue != hovered { needsDisplay = true } }
    }
    var marqueeSelected = false {
        didSet { if oldValue != marqueeSelected { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    private var showsSelection: Bool { isSelected || marqueeSelected }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.content.setFill()
        dirtyRect.fill()
        if showsSelection {
            Theme.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 3, yRadius: 3).fill()
        } else if hovered {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
        if showsSelection && isFocused {
            Theme.selectionBorder.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4.5, dy: 1.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

@MainActor
final class NameCellView: NSView {
    enum Style {
        case row
        case tile
    }

    private let checkbox = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = makeLabel("", size: 13)
    private let metaLabel = makeLabel("", size: 11.5, color: Theme.textSecondary)
    private let style: Style
    var onToggle: (() -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var selected = false

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.controlSize = .mini
        checkbox.target = self
        checkbox.action = #selector(togglePressed)
        checkbox.isHidden = true
        addSubview(checkbox)

        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .left
        addSubview(nameLabel)
        metaLabel.isHidden = style != .tile
        addSubview(metaLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func configure(
        entry: FileEntry,
        selected: Bool,
        focused: Bool,
        cut: Bool,
        showExtensions: Bool,
        showMeta: Bool,
        hovered: Bool
    ) {
        self.selected = selected
        hovering = hovered
        iconView.image = IconService.shared.fileIcon(for: entry, size: style == .tile ? 44 : 18)
        iconView.alphaValue = cut ? 0.45 : 1
        nameLabel.stringValue = displayName(entry.name, showExtensions)
        nameLabel.textColor = cut ? Theme.textTertiary : Theme.textPrimary
        nameLabel.toolTip = entry.name
        if showMeta {
            let label = FileKinds.typeLabel(entry.name, entry.isDirectory)
            metaLabel.stringValue = entry.isDirectory ? label : "\(label) · \(FormatTools.bytes(entry.size))"
        }
        checkbox.state = selected ? .on : .off
        checkbox.isHidden = !(selected || hovering)
        needsLayout = true
    }

    func setHovered(_ hovered: Bool) {
        guard hovering != hovered else { return }
        hovering = hovered
        checkbox.isHidden = !(selected || hovering)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        checkbox.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        checkbox.isHidden = !selected
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let iconSize: CGFloat = style == .tile ? 44 : 18
        checkbox.frame = NSRect(x: 2, y: (height - 16) / 2, width: 16, height: 16)
        iconView.frame = NSRect(x: 22, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        if style == .tile {
            nameLabel.frame = NSRect(x: 76, y: height / 2 - 24, width: max(0, bounds.width - 84), height: 18)
            metaLabel.frame = NSRect(x: 76, y: height / 2 + 1, width: max(0, bounds.width - 84), height: 16)
            metaLabel.isHidden = false
        } else {
            nameLabel.frame = NSRect(x: 46, y: (height - 18) / 2, width: max(0, bounds.width - 54), height: 18)
        }
    }

    @objc private func togglePressed() {
        onToggle?()
    }
}

@MainActor
final class FileIconItemView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")

    private let tile = IconTileView()
    var onToggle: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    override func loadView() {
        view = tile
        tile.onToggle = { [weak self] in self?.onToggle?() }
    }

    override var isSelected: Bool {
        didSet { tile.isSelected = isSelected }
    }

    func configure(
        entry: FileEntry,
        iconSize: CGFloat,
        selected: Bool,
        focused: Bool,
        cut: Bool,
        showExtensions: Bool
    ) {
        tile.configure(
            entry: entry,
            iconSize: iconSize,
            selected: selected,
            focused: focused,
            cut: cut,
            showExtensions: showExtensions
        )
    }
}

@MainActor
final class IconTileView: NSView {
    private let iconView = NSImageView()
    private let label = makeLabel("", size: 12.5)
    private let checkbox = NSButton()
    private var entry: FileEntry?
    private var iconSize: CGFloat = 80
    private var hovering = false
    private var tracking: NSTrackingArea?
    var onToggle: (() -> Void)?
    var isSelected = false {
        didSet {
            needsDisplay = true
            checkbox.state = isSelected ? .on : .off
            checkbox.isHidden = !(isSelected || hovering)
        }
    }
    private var focused = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.controlSize = .mini
        checkbox.target = self
        checkbox.action = #selector(togglePressed)
        checkbox.isHidden = true
        addSubview(checkbox)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        // Windows centres captions beneath icons in Large/Medium icon views.
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: FileEntry, iconSize: CGFloat, selected: Bool, focused: Bool, cut: Bool, showExtensions: Bool) {
        self.entry = entry
        self.iconSize = iconSize
        self.focused = focused
        self.isSelected = selected
        label.stringValue = displayName(entry.name, showExtensions)
        label.textColor = cut ? Theme.textTertiary : Theme.textPrimary
        label.toolTip = entry.name
        iconView.alphaValue = cut ? 0.45 : 1
        checkbox.state = selected ? .on : .off
        let placeholder = IconService.shared.fileIcon(for: entry, size: iconSize)
        iconView.image = placeholder
        if entry.kind == .image {
            let path = entry.path
            IconService.shared.thumbnail(for: entry, size: iconSize * 2) { [weak self] image in
                guard let self, let image, self.entry?.path == path else { return }
                self.iconView.image = image
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        checkbox.isHidden = !(isSelected || hovering)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        checkbox.isHidden = !isSelected
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 4, y: 4, width: 16, height: 16)
        let y = max(8, (bounds.height - iconSize) / 2 - 10)
        iconView.frame = NSRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
        label.frame = NSRect(x: 5, y: y + iconSize + 6, width: bounds.width - 10, height: max(30, bounds.height - (y + iconSize + 6) - 6))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            if focused {
                Theme.selectionBorder.setStroke()
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
                path.lineWidth = 1
                path.stroke()
            }
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }

    @objc private func togglePressed() {
        onToggle?()
    }
}

@MainActor
final class FileTileItemView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileTileItem")

    private let tile = TileGridItemView()
    var onToggle: (() -> Void)?

    override func loadView() {
        view = tile
        tile.onToggle = { [weak self] in self?.onToggle?() }
    }

    override var isSelected: Bool {
        didSet { tile.isSelected = isSelected }
    }

    func configure(entry: FileEntry, selected: Bool, focused: Bool, cut: Bool, showExtensions: Bool) {
        tile.configure(entry: entry, selected: selected, focused: focused, cut: cut, showExtensions: showExtensions)
    }
}

@MainActor
final class TileGridItemView: NSView {
    private let checkbox = NSButton()
    private let iconView = NSImageView()
    private let nameLabel = makeLabel("", size: 13)
    private let metaLabel = makeLabel("", size: 11.5, color: Theme.textSecondary)
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var focused = false
    var onToggle: (() -> Void)?
    var isSelected = false {
        didSet {
            needsDisplay = true
            checkbox.state = isSelected ? .on : .off
            checkbox.isHidden = !(isSelected || hovering)
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.controlSize = .mini
        checkbox.target = self
        checkbox.action = #selector(togglePressed)
        checkbox.isHidden = true
        addSubview(checkbox)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .left
        addSubview(nameLabel)
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: FileEntry, selected: Bool, focused: Bool, cut: Bool, showExtensions: Bool) {
        self.focused = focused
        iconView.image = IconService.shared.fileIcon(for: entry, size: 44)
        iconView.alphaValue = cut ? 0.45 : 1
        nameLabel.stringValue = displayName(entry.name, showExtensions)
        nameLabel.textColor = cut ? Theme.textTertiary : Theme.textPrimary
        nameLabel.toolTip = entry.name
        let type = FileKinds.typeLabel(entry.name, entry.isDirectory)
        metaLabel.stringValue = entry.isDirectory ? type : "\(type) · \(FormatTools.bytes(entry.size))"
        checkbox.state = selected ? .on : .off
        isSelected = selected
        needsLayout = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        checkbox.isHidden = !(isSelected || hovering)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        checkbox.isHidden = !isSelected
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        iconView.frame = NSRect(x: 30, y: (bounds.height - 44) / 2, width: 44, height: 44)
        nameLabel.frame = NSRect(x: 86, y: 10, width: max(0, bounds.width - 96), height: 18)
        metaLabel.frame = NSRect(x: 86, y: 31, width: max(0, bounds.width - 96), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            if focused {
                Theme.selectionBorder.setStroke()
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
                path.lineWidth = 1
                path.stroke()
            }
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }

    @objc private func togglePressed() {
        onToggle?()
    }
}

@MainActor
final class FileHeaderCell: NSTableHeaderCell {
    var leadingPadding: CGFloat = 8
    var trailingPadding: CGFloat = 8
    var isSorted = false
    var sortAscending = true

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isSorted ? Theme.textPrimary : Theme.textSecondary,
        ]
        let text = stringValue as NSString
        let textSize = text.size(withAttributes: attributes)
        let indicatorSpace: CGFloat = isSorted ? 13 : 0
        let textX: CGFloat
        if alignment == .right {
            textX = cellFrame.maxX - trailingPadding - indicatorSpace - textSize.width
        } else {
            textX = cellFrame.minX + leadingPadding
        }
        let textY = cellFrame.midY - textSize.height / 2
        text.draw(at: NSPoint(x: textX, y: textY), withAttributes: attributes)
        if isSorted, let symbol = Icons.symbol(sortAscending ? "chevron.up" : "chevron.down", size: 9) {
            // Keep the chevron beside the label, like the rest of the Windows-style chrome.
            let tint = Theme.resolved(Theme.textSecondary, for: controlView)
            let tinted = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
                symbol.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let indicatorX = min(
                textX + textSize.width + 4,
                cellFrame.maxX - trailingPadding - 9
            )
            tinted.draw(in: NSRect(x: indicatorX, y: cellFrame.midY - 4.5, width: 9, height: 9))
        }
    }
}

@MainActor
final class TableTextCellView: NSView {
    private let label = makeLabel("", size: 12.5, color: Theme.textSecondary)
    var leadingPadding: CGFloat = 8
    var trailingPadding: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, alignment: NSTextAlignment) {
        label.stringValue = text
        label.alignment = alignment
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: leadingPadding,
            y: (bounds.height - 18) / 2,
            width: max(0, bounds.width - leadingPadding - trailingPadding),
            height: 18
        )
    }
}

@MainActor
final class RenameTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    init() {
        super.init(frame: .zero)
        isBordered = true
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = Theme.field
        textColor = Theme.textPrimary
        font = NSFont.systemFont(ofSize: 13)
        focusRingType = .none
        delegate = self
        target = self
        action = #selector(commit)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSReturnTextMovement {
            commit()
        } else if movement == NSCancelTextMovement {
            cancel()
        } else {
            commit()
        }
    }

    @objc private func commit() {
        guard !finished else { return }
        finished = true
        onCommit?(stringValue)
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel?()
    }
}
