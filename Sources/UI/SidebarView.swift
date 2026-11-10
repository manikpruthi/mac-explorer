import AppKit
import Darwin

@MainActor
final class SidebarNode: NSObject {
    enum Kind {
        case home
        case gallery
        case network
        case section
        case folder
        case volume
        case trash
        case placeholder
    }

    let kind: Kind
    let title: String
    let icon: String
    let path: String?
    var children: [SidebarNode] = []
    var loaded = false
    var canPin = false
    var volumeText: String?

    init(kind: Kind, title: String, icon: String, path: String? = nil) {
        self.kind = kind
        self.title = title
        self.icon = icon
        self.path = path
        super.init()
    }

    var isSection: Bool { kind == .section }
    var isSelectable: Bool { kind != .section && kind != .placeholder }
    var isExpandable: Bool {
        kind == .section || kind == .folder || kind == .volume
    }
}

@MainActor
protocol SidebarViewDelegate: AnyObject {
    func sidebarSelect(node: SidebarNode)
    func sidebarContextMenu(node: SidebarNode?, event: NSEvent)
    func sidebarToggleSection(_ title: String, expanded: Bool)
    func sidebarDrop(paths: [String], destination: String, copy: Bool)
    func sidebarNewTab(path: String)
    func sidebarTogglePin(path: String)
    func sidebarReveal(path: String)
    func sidebarProperties(path: String)
}

@MainActor
final class SidebarView: ThemedView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: SidebarViewDelegate?

    private let scroll = makeScroller()
    private let outline = SidebarOutlineView()
    private var roots: [SidebarNode] = []
    private var activePath: String?
    private var activeKind: SidebarNode.Kind?
    private var syncingSelection = false
    private var pinnedPaths: Set<String> = []
    private var lastPinned: [String] = []
    private var lastVolumePaths: [String] = []
    private var dropTargetNode: SidebarNode?
    // One scan at a time; pending work is found in the existing tree, not a task queue.
    private var childLoadTask: Task<Void, Never>?
    private weak var loadingNode: SidebarNode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.sidebar

        outline.dataSource = self
        outline.delegate = self
        outline.headerView = nil
        outline.rowHeight = 32
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.floatsGroupRows = false
        outline.registerForDraggedTypes([FileListView.dragType, .fileURL])
        // Drop feedback is drawn by SidebarCellView so it matches the rest of the app.
        outline.draggingDestinationFeedbackStyle = .none
        outline.onDragLeft = { [weak self] in self?.setDropTarget(nil) }
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)
        outline.onContext = { [weak self] node, event in
            self?.delegate?.sidebarContextMenu(node: node, event: event)
        }
        if outline.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
            column.resizingMask = .autoresizingMask
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
        }
        scroll.documentView = outline
        addSubview(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        childLoadTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            childLoadTask?.cancel()
        } else {
            startNextChildLoad()
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.hairline.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
        path.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        path.lineWidth = 1
        path.stroke()
    }

    func update(
        system: SystemInfo,
        pinned: [String],
        activeLocation: Location,
        quickAccessOpen: Bool,
        thisPcOpen: Bool
    ) {
        let volumePaths = system.volumes.map(\.path)
        let structureChanged = roots.isEmpty || pinned != lastPinned || volumePaths != lastVolumePaths
        pinnedPaths = Set(pinned)

        activePath = nil
        activeKind = nil
        switch activeLocation {
        case .home: activeKind = .home
        case .gallery: activeKind = .gallery
        case .network: activeKind = .network
        case .archive: break
        case .fs(let path):
            activePath = path
            if path == system.trashPath { activeKind = .trash }
        }

        if structureChanged {
            // A reload invalidates an in-flight snapshot; keep its slot until it exits.
            childLoadTask?.cancel()
            let initial = roots.isEmpty
            let quickChanged = initial || pinned != lastPinned
            let pcChanged = initial || volumePaths != lastVolumePaths
            lastPinned = pinned
            lastVolumePaths = volumePaths

            let quickSection = roots.first { $0.title == "Quick access" && $0.isSection }
                ?? SidebarNode(kind: .section, title: "Quick access", icon: "")
            let pcSection = roots.first { $0.title == "This PC" && $0.isSection }
                ?? SidebarNode(kind: .section, title: "This PC", icon: "")

            if quickChanged {
                let previous = quickSection.children
                quickSection.children = pinned.map { path in
                    let special = system.specialFolders.first { $0.path == path }
                    let label = special?.label ?? (path == system.home ? "Home" : PathTools.basename(path))
                    let icon = special.map { iconForKey($0.key) } ?? "folder"
                    let node = previous.first { $0.path == path && $0.title == label && $0.icon == icon }
                        ?? SidebarNode(kind: .folder, title: label, icon: icon, path: path)
                    node.canPin = true
                    return node
                }
                if quickSection.children.isEmpty {
                    quickSection.children = [SidebarNode(kind: .placeholder, title: "Nothing pinned yet", icon: "")]
                }
            }

            if pcChanged {
                let previous = pcSection.children
                pcSection.children = system.volumes.map { volume in
                    previous.first { $0.kind == .volume && $0.path == volume.path && $0.title == volume.name }
                        ?? SidebarNode(kind: .volume, title: volume.name, icon: "internaldrive", path: volume.path)
                }
                if system.specialFolders.contains(where: { $0.key == "trash" }) {
                    pcSection.children.append(previous.first { $0.kind == .trash && $0.path == system.trashPath }
                        ?? SidebarNode(kind: .trash, title: "Trash", icon: "trash", path: system.trashPath))
                }
            }

            if initial {
                roots = [
                    SidebarNode(kind: .home, title: "Home", icon: "house"),
                    SidebarNode(kind: .gallery, title: "Gallery", icon: "photo.on.rectangle"),
                    SidebarNode(kind: .network, title: "Network", icon: "network"),
                    quickSection,
                    pcSection,
                ]
                outline.reloadData()
                if quickAccessOpen { outline.expandItem(quickSection) }
                if thisPcOpen { outline.expandItem(pcSection) }
            } else {
                // Stable item identities preserve expansion, including loaded descendants.
                if quickChanged { outline.reloadItem(quickSection, reloadChildren: true) }
                if pcChanged { outline.reloadItem(pcSection, reloadChildren: true) }
            }
            if let loadingNode, !containsNode(loadingNode) { childLoadTask?.cancel() }
            if let dropTargetNode, !containsNode(dropTargetNode) { setDropTarget(nil) }
            startNextChildLoad()
        }

        // Free space changes do not require replacing volume nodes or their children.
        for section in roots where section.isSection {
            for node in section.children where node.kind == .volume {
                guard let volume = system.volumes.first(where: { $0.path == node.path }) else { continue }
                node.volumeText = volume.total > 0
                    ? "\(FormatTools.bytes(volume.free)) free of \(FormatTools.bytes(volume.total))" : nil
            }
        }

        selectActive(system: system)
    }

    private func selectActive(system: SystemInfo) {
        syncingSelection = true
        defer { syncingSelection = false }
        var newRow = -1
        if let activePath, let node = node(for: activePath) {
            let row = outline.row(forItem: node)
            if row >= 0 { newRow = row }
        }
        if newRow < 0, let activeKind {
            for root in roots where root.kind == activeKind {
                let row = outline.row(forItem: root)
                if row >= 0 { newRow = row; break }
            }
        }
        if newRow >= 0 {
            outline.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            outline.scrollRowToVisible(newRow)
        } else {
            outline.deselectAll(nil)
        }
        refreshVisibleCells()
    }

    private func refreshVisibleCells() {
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView,
                  let node = outline.item(atRow: row) as? SidebarNode else { continue }
            let active = node.isSection ? false : isActive(node)
            cell.setActive(active)
            cell.toolTip = node.volumeText ?? node.path
        }
    }

    private func node(for path: String) -> SidebarNode? {
        for root in roots {
            if let found = findNode(path: path, in: root) { return found }
        }
        return nil
    }

    private func findNode(path: String, in node: SidebarNode) -> SidebarNode? {
        if node.path == path { return node }
        for child in node.children {
            if let found = findNode(path: path, in: child) { return found }
        }
        return nil
    }

    private func iconForKey(_ key: String) -> String {
        switch key {
        case "desktop": return "display"
        case "downloads": return "arrow.down.circle"
        case "documents": return "doc"
        case "pictures": return "photo"
        case "music": return "music.note"
        case "videos": return "film"
        case "applications": return "square.grid.2x2"
        case "trash": return "trash"
        default: return "folder"
        }
    }

    // MARK: - Outline data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SidebarNode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SidebarNode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarNode)?.isSection == true ? 30 : 32
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebar-cell")
        let cell: SidebarCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView {
            cell = reused
        } else {
            cell = SidebarCellView()
            cell.identifier = identifier
        }
        let active = node.isSection ? false : isActive(node)
        cell.configure(node: node, active: active, pinned: node.path.map { pinnedPaths.contains($0) } ?? false)
        cell.isDropTarget = dropTargetNode === node
        return cell
    }

    private func isActive(_ node: SidebarNode) -> Bool {
        if let path = node.path, path == activePath { return true }
        if let kind = activeKind, node.kind == kind { return true }
        return false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        guard node.kind == .folder || node.kind == .volume, !node.loaded, node.path != nil else { return }
        node.children = [SidebarNode(kind: .placeholder, title: "Loading subfolders…", icon: "")]
        outline.reloadItem(node, reloadChildren: true)
    }

    private func containsNode(_ target: SidebarNode) -> Bool {
        func contains(_ node: SidebarNode) -> Bool {
            node === target || node.children.contains(where: contains)
        }
        return roots.contains(where: contains)
    }

    private func startNextChildLoad() {
        guard childLoadTask == nil, window != nil else { return }
        func pending(_ node: SidebarNode) -> SidebarNode? {
            guard outline.isItemExpanded(node), outline.row(forItem: node) >= 0 else { return nil }
            if (node.kind == .folder || node.kind == .volume), !node.loaded { return node }
            for child in node.children {
                if let found = pending(child) { return found }
            }
            return nil
        }
        guard let node = roots.lazy.compactMap({ pending($0) }).first, let path = node.path else { return }
        loadingNode = node
        childLoadTask = Task.detached(priority: .userInitiated) { [weak self, weak node] in
            let result: ([FileEntry], String?)
            do {
                result = (try Self.readSubfolders(path), nil)
            } catch {
                result = ([], error.localizedDescription)
            }
            let cancelled = Task.isCancelled
            await MainActor.run { [weak self, weak node] in
                guard let self else { return }
                let discard = cancelled || self.childLoadTask?.isCancelled == true
                self.childLoadTask = nil
                self.loadingNode = nil
                if !discard, self.window != nil, let node,
                   self.containsNode(node), self.outline.isItemExpanded(node),
                   self.outline.row(forItem: node) >= 0, !node.loaded {
                    node.loaded = true
                    node.children = result.0.map { entry in
                        let child = SidebarNode(kind: .folder, title: entry.name, icon: "folder", path: entry.path)
                        child.canPin = true
                        return child
                    }
                    if node.children.isEmpty {
                        let placeholder = SidebarNode(kind: .placeholder,
                            title: result.1 == nil ? "No subfolders" : "Unable to read subfolders", icon: "")
                        placeholder.volumeText = result.1
                        node.children = [placeholder]
                    }
                    self.outline.reloadItem(node, reloadChildren: true)
                    self.refreshVisibleCells()
                }
                self.startNextChildLoad()
            }
        }
    }

    /// Streams directory names and keeps only the alphabetically first 60 folders.
    /// Unlike readDirectory, this does not allocate a whole listing or parallel stat tasks.
    nonisolated private static func readSubfolders(_ path: String) throws -> [FileEntry] {
        try Task.checkCancellation()
        guard let directory = opendir(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { closedir(directory) }
        var folders: [FileEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(directory) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                break
            }
            let nameCapacity = Int(item.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    String(cString: $0)
                }
            }
            guard !name.hasPrefix("."), (name as NSString).pathExtension.lowercased() != "app" else { continue }
            let fullPath = (path as NSString).appendingPathComponent(name)
            guard let entry = FileService.entry(name: name, path: fullPath), entry.isDirectory else { continue }
            let index = folders.firstIndex { name.localizedStandardCompare($0.name) == .orderedAscending }
                ?? folders.count
            guard index < 60 else { continue }
            if folders.count == 60 { folders.removeLast() }
            folders.insert(entry, at: index)
        }
        return folders
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        refreshVisibleCells()
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        // Nodes now outlive navigation, so re-read a folder's subfolders the next time it opens.
        if node.kind == .folder || node.kind == .volume {
            node.loaded = false
            node.children = []
        }
        if let loadingNode, loadingNode === node || outline.row(forItem: loadingNode) < 0 {
            childLoadTask?.cancel()
        }
        startNextChildLoad()
        guard node.isSection else { return }
        delegate?.sidebarToggleSection(node.title, expanded: false)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        refreshVisibleCells()
        startNextChildLoad()
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, node.isSection else { return }
        delegate?.sidebarToggleSection(node.title, expanded: true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.isSection || node.isSelectable
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return }
        if node.isSection {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
            outline.deselectAll(nil)
            refreshVisibleCells()
            return
        }
        guard node.isSelectable else { return }
        if let path = node.path {
            activePath = path
            activeKind = nil
        } else {
            activeKind = node.kind
            activePath = nil
        }
        refreshVisibleCells()
        delegate?.sidebarSelect(node: node)
    }

    // MARK: - Drag destination

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let node = item as? SidebarNode, let path = node.path, node.kind != .trash,
              node.kind == .folder || node.kind == .volume,
              !FileListView.draggedPaths(info).contains(path) else {
            setDropTarget(nil)
            return []
        }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        setDropTarget(node)
        let types = info.draggingPasteboard.types ?? []
        let internalDrag = types.contains(FileListView.dragType)
        _ = path
        if internalDrag && !NSEvent.modifierFlags.contains(.option) {
            return .move
        }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        setDropTarget(nil)
        guard let node = item as? SidebarNode, let destination = node.path else { return false }
        guard let paths = draggedPaths(info) else { return false }
        let internalDrag = info.draggingPasteboard.types?.contains(FileListView.dragType) ?? false
        let copy = internalDrag ? NSEvent.modifierFlags.contains(.option) : true
        delegate?.sidebarDrop(paths: paths, destination: destination, copy: copy)
        return true
    }

    private func setDropTarget(_ node: SidebarNode?) {
        guard dropTargetNode !== node else { return }
        dropTargetNode = node
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView else { continue }
            cell.isDropTarget = node != nil && outline.item(atRow: row) as? SidebarNode === node
        }
    }

    private func draggedPaths(_ info: NSDraggingInfo) -> [String]? {
        let pasteboard = info.draggingPasteboard
        if let json = pasteboard.string(forType: FileListView.dragType),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls.filter { $0.isFileURL }.map { $0.path }
        }
        return nil
    }
}

@MainActor
final class SidebarOutlineView: NSOutlineView {
    var onContext: ((SidebarNode?, NSEvent) -> Void)?
    var onDragLeft: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragLeft?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // draggingEnded(_:) is an optional NSDraggingDestination method that
        // NSTableView/NSOutlineView don't implement, so an unconditional
        // super call raises "unrecognized selector" and aborts the app.
        if NSOutlineView.instancesRespond(to: #selector(NSDraggingDestination.draggingEnded(_:))) {
            super.draggingEnded(sender)
        }
        onDragLeft?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let node = row >= 0 ? item(atRow: row) as? SidebarNode : nil
        onContext?(node, event)
        return nil
    }
}

@MainActor
final class SidebarCellView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = makeLabel("", size: 13)
    private let trailingLabel = makeLabel("", size: 11, color: Theme.textTertiary)
    private var active = false
    private var isSection = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    var isDropTarget = false {
        didSet { if oldValue != isDropTarget { needsDisplay = true } }
    }

    nonisolated override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(trailingLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(node: SidebarNode, active: Bool, pinned: Bool) {
        self.active = active
        isSection = node.isSection
        titleLabel.stringValue = node.title
        titleLabel.font = NSFont.systemFont(ofSize: isSection ? 12 : 13, weight: isSection ? .semibold : .regular)
        iconView.image = node.icon.isEmpty ? nil : Icons.symbol(node.icon, size: 16)
        iconView.isHidden = node.icon.isEmpty
        trailingLabel.stringValue = ""
        toolTip = node.volumeText ?? node.path
        updateColors()
        needsDisplay = true
        needsLayout = true
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        updateColors()
        needsDisplay = true
    }

    private func updateColors() {
        if active {
            titleLabel.textColor = Theme.textPrimary
            iconView.contentTintColor = Theme.accent
        } else if hovering {
            titleLabel.textColor = isSection ? Theme.textPrimary : Theme.textPrimary
            iconView.contentTintColor = Theme.textSecondary
        } else {
            titleLabel.textColor = isSection ? Theme.textSecondary : Theme.textPrimary
            iconView.contentTintColor = Theme.textSecondary
        }
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
        updateColors()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateColors()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        if isSection {
            titleLabel.frame = NSRect(x: 4, y: (height - 16) / 2, width: bounds.width - 12, height: 16)
            iconView.frame = .zero
        } else {
            iconView.frame = NSRect(x: 6, y: (height - 17) / 2, width: 17, height: 17)
            titleLabel.frame = NSRect(x: 30, y: (height - 17) / 2, width: max(0, bounds.width - 38), height: 17)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            Theme.drawDropTarget(in: bounds.insetBy(dx: 4, dy: 1), radius: 4)
        } else if active {
            Theme.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 8, width: 3, height: max(0, bounds.height - 16)), xRadius: 1.5, yRadius: 1.5).fill()
        } else if hovering {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }
}
