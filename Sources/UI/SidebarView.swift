import AppKit

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
    private var nodesByPath: [String: SidebarNode] = [:]
    private var activePath: String?
    private var activeKind: SidebarNode.Kind?
    private var syncingSelection = false
    private var pinnedPaths: Set<String> = []
    private var lastPinned: [String] = []
    private var lastVolumePaths: [String] = []

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
            lastPinned = pinned
            lastVolumePaths = volumePaths
            nodesByPath = [:]

            let quickSection = SidebarNode(kind: .section, title: "Quick access", icon: "")
            let specialByPath = Dictionary(uniqueKeysWithValues: system.specialFolders.map { ($0.path, $0) })
            for path in pinned {
                let label = specialByPath[path]?.label ?? (path == system.home ? "Home" : PathTools.basename(path))
                let icon = specialByPath[path].map { iconForKey($0.key) } ?? "folder"
                let node = SidebarNode(kind: .folder, title: label, icon: icon, path: path)
                node.canPin = true
                quickSection.children.append(node)
                nodesByPath[path] = node
            }
            if quickSection.children.isEmpty {
                let empty = SidebarNode(kind: .placeholder, title: "Nothing pinned yet", icon: "")
                quickSection.children.append(empty)
            }

            let pcSection = SidebarNode(kind: .section, title: "This PC", icon: "")
            let volumeNodes = system.volumes.map { volume -> SidebarNode in
                let node = SidebarNode(kind: .volume, title: volume.name, icon: "internaldrive", path: volume.path)
                if volume.total > 0 {
                    node.volumeText = "\(FormatTools.bytes(volume.free)) free of \(FormatTools.bytes(volume.total))"
                }
                return node
            }
            pcSection.children.append(contentsOf: volumeNodes)
            if system.specialFolders.contains(where: { $0.key == "trash" }) {
                pcSection.children.append(SidebarNode(kind: .trash, title: "Trash", icon: "trash", path: system.trashPath))
            }

            let roots: [SidebarNode] = [
                SidebarNode(kind: .home, title: "Home", icon: "house"),
                SidebarNode(kind: .gallery, title: "Gallery", icon: "photo.on.rectangle"),
                SidebarNode(kind: .network, title: "Network", icon: "network"),
                quickSection,
                pcSection,
            ]
            self.roots = roots

            outline.reloadData()
            if quickAccessOpen { outline.expandItem(quickSection) } else { outline.collapseItem(quickSection) }
            if thisPcOpen { outline.expandItem(pcSection) } else { outline.collapseItem(pcSection) }
        }

        selectActive(system: system)
    }

    private func selectActive(system: SystemInfo) {
        syncingSelection = true
        defer { syncingSelection = false }
        let previousRow = outline.selectedRow
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
        var toReload = IndexSet()
        if previousRow >= 0 { toReload.insert(previousRow) }
        if newRow >= 0 { toReload.insert(newRow) }
        if !toReload.isEmpty {
            outline.reloadData(forRowIndexes: toReload, columnIndexes: IndexSet(integer: 0))
        }
    }

    private func node(for path: String) -> SidebarNode? {
        if let direct = nodesByPath[path] { return direct }
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
        return cell
    }

    private func isActive(_ node: SidebarNode) -> Bool {
        if let path = node.path, path == activePath { return true }
        if let kind = activeKind, node.kind == kind { return true }
        return false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        guard node.kind == .folder || node.kind == .volume, !node.loaded, let path = node.path else { return }
        node.loaded = true
        if let listing = try? FileService.readDirectory(path) {
            let folders = listing.entries
                .filter { $0.isDirectory && $0.kind != .app && !$0.hidden }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .prefix(60)
            node.children = folders.map { entry in
                let child = SidebarNode(kind: .folder, title: entry.name, icon: "folder", path: entry.path)
                child.canPin = true
                return child
            }
        }
        if node.children.isEmpty {
            node.children = [SidebarNode(kind: .placeholder, title: "No subfolders", icon: "")]
        }
        outline.reloadItem(node, reloadChildren: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, node.isSection else { return }
        delegate?.sidebarToggleSection(node.title, expanded: false)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
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
            return
        }
        guard node.isSelectable else { return }
        if let path = node.path { activePath = path }
        delegate?.sidebarSelect(node: node)
    }

    // MARK: - Drag destination

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let node = item as? SidebarNode, let path = node.path, node.kind != .trash else { return [] }
        guard node.kind == .folder || node.kind == .volume else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
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
        guard let node = item as? SidebarNode, let destination = node.path else { return false }
        guard let paths = draggedPaths(info) else { return false }
        let internalDrag = info.draggingPasteboard.types?.contains(FileListView.dragType) ?? false
        let copy = internalDrag ? NSEvent.modifierFlags.contains(.option) : true
        delegate?.sidebarDrop(paths: paths, destination: destination, copy: copy)
        return true
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

    override var isFlipped: Bool { true }

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
        if active {
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
