import AppKit

@MainActor
final class CommandBarView: ThemedView {
    var onNewFolder: (() -> Void)?
    var onNewTextFile: (() -> Void)?
    var onCut: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSort: ((SortKey, SortDir) -> Void)?
    var onSetView: ((ViewMode) -> Void)?
    var onToggleHidden: (() -> Void)?
    var onToggleExtensions: (() -> Void)?
    var onToggleDetails: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onSetTheme: ((ThemePreference) -> Void)?
    var onOpenTerminal: (() -> Void)?
    var onShowAbout: (() -> Void)?

    private let newButton = HoverButton(title: "New ▾", image: "plus")
    private let cutButton = HoverButton(title: "Cut", image: "scissors")
    private let copyButton = HoverButton(title: "Copy", image: "doc.on.doc")
    private let pasteButton = HoverButton(title: "Paste", image: "doc.on.clipboard")
    private let renameButton = HoverButton(title: "Rename", image: "pencil")
    private let deleteButton = HoverButton(title: "Delete", image: "trash")
    private let sortButton = HoverButton(title: "Sort ▾", image: "arrow.up.arrow.down")
    private let viewButton = HoverButton(title: "View ▾", image: "square.grid.2x2")
    private let detailsButton = HoverButton(title: "Details", image: "sidebar.right")
    private let overflowButton = HoverButton(title: "", image: "ellipsis")
    private let separatorOne = ThemedView()
    private let separatorTwo = ThemedView()
    private let spacer = NSView()

    private var view: ViewMode = .details
    private var sortKey: SortKey = .name
    private var sortDir: SortDir = .asc
    private var showHidden = false
    private var showExtensions = false
    private var detailsOpen = false
    private var sidebarVisible = true
    private var theme: ThemePreference = .system
    private var pinnedSelection = false
    private var canPin = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.surface

        let buttons = [newButton, cutButton, copyButton, pasteButton, renameButton, deleteButton, sortButton, viewButton, detailsButton, overflowButton]
        for button in buttons {
            button.font = NSFont.systemFont(ofSize: 12.5)
            addSubview(button)
        }
        for separator in [separatorOne, separatorTwo] {
            separator.fillColor = Theme.hairline
            addSubview(separator)
        }
        addSubview(spacer)

        newButton.target = self
        newButton.action = #selector(newPressed)
        cutButton.target = self
        cutButton.action = #selector(cutPressed)
        copyButton.target = self
        copyButton.action = #selector(copyPressed)
        pasteButton.target = self
        pasteButton.action = #selector(pastePressed)
        renameButton.target = self
        renameButton.action = #selector(renamePressed)
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)
        sortButton.target = self
        sortButton.action = #selector(sortPressed)
        viewButton.target = self
        viewButton.action = #selector(viewPressed)
        detailsButton.target = self
        detailsButton.action = #selector(detailsPressed)
        overflowButton.target = self
        overflowButton.action = #selector(overflowPressed)

        newButton.toolTip = "New"
        cutButton.toolTip = "Cut (⌘X)"
        copyButton.toolTip = "Copy (⌘C)"
        pasteButton.toolTip = "Paste (⌘V)"
        renameButton.toolTip = "Rename (F2)"
        deleteButton.toolTip = "Delete (⌘⌫)"
        sortButton.toolTip = "Sort"
        viewButton.toolTip = "View"
        detailsButton.toolTip = "Details pane"
        overflowButton.toolTip = "More"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        canCreate: Bool,
        canModify: Bool,
        canPaste: Bool,
        canPin: Bool,
        pinnedSelection: Bool,
        selectionCount: Int,
        view: ViewMode,
        sortKey: SortKey,
        sortDir: SortDir,
        showHidden: Bool,
        showExtensions: Bool,
        detailsOpen: Bool,
        sidebarVisible: Bool,
        theme: ThemePreference
    ) {
        self.view = view
        self.sortKey = sortKey
        self.sortDir = sortDir
        self.showHidden = showHidden
        self.showExtensions = showExtensions
        self.detailsOpen = detailsOpen
        self.sidebarVisible = sidebarVisible
        self.theme = theme
        self.canPin = canPin
        self.pinnedSelection = pinnedSelection

        newButton.isEnabled = canCreate
        cutButton.isEnabled = canModify && selectionCount > 0
        copyButton.isEnabled = selectionCount > 0
        pasteButton.isEnabled = canPaste
        renameButton.isEnabled = canModify && selectionCount == 1
        deleteButton.isEnabled = canModify && selectionCount > 0
        detailsButton.isActive = detailsOpen
        detailsButton.updateBackground()
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let compact = bounds.width < 780
        let labels: [(HoverButton, String)] = [
            (newButton, "New ▾"),
            (cutButton, "Cut"),
            (copyButton, "Copy"),
            (pasteButton, "Paste"),
            (renameButton, "Rename"),
            (deleteButton, "Delete"),
            (sortButton, "Sort ▾"),
            (viewButton, "View ▾"),
            (detailsButton, "Details"),
        ]
        for (button, title) in labels {
            button.title = compact ? "" : title
            button.imagePosition = compact ? .imageOnly : .imageLeading
        }

        let y: CGFloat = (height - 32) / 2
        var x: CGFloat = 10
        let widths: [CGFloat] = compact ? [34, 34, 34, 34, 34, 34] : [76, 62, 70, 70, 82, 76]
        for (index, button) in [newButton, cutButton, copyButton, pasteButton, renameButton, deleteButton].enumerated() {
            button.frame = NSRect(x: x, y: y, width: widths[index], height: 32)
            x += widths[index] + 2
        }
        x += 4
        separatorOne.frame = NSRect(x: x, y: (height - 20) / 2, width: 1, height: 20)
        x += 10
        sortButton.frame = NSRect(x: x, y: y, width: compact ? 34 : 72, height: 32)
        x += (compact ? 36 : 74)
        viewButton.frame = NSRect(x: x, y: y, width: compact ? 34 : 74, height: 32)

        let right: CGFloat = bounds.width - 10
        let detailsWidth: CGFloat = compact ? 32 : 84
        overflowButton.frame = NSRect(x: right - 32, y: y, width: 32, height: 32)
        detailsButton.frame = NSRect(x: right - 32 - 6 - detailsWidth, y: y, width: detailsWidth, height: 32)
        spacer.frame = NSRect(x: x + 36, y: y, width: max(0, right - 32 - 6 - detailsWidth - (x + 36)), height: 32)
        separatorTwo.frame = NSRect(x: 0, y: height - 1, width: bounds.width, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.hairline.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        path.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func newPressed() {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Folder", icon: "folder.badge.plus", key: "n", modifiers: [.command, .shift]) { [weak self] in
            self?.onNewFolder?()
        })
        menu.addItem(makeMenuItem("Text document", icon: "doc.badge.plus") { [weak self] in
            self?.onNewTextFile?()
        })
        pop(menu, from: newButton)
    }

    @objc private func cutPressed() { onCut?() }
    @objc private func copyPressed() { onCopy?() }
    @objc private func pastePressed() { onPaste?() }
    @objc private func renamePressed() { onRename?() }
    @objc private func deletePressed() { onDelete?() }

    @objc private func sortPressed() {
        let menu = NSMenu()
        for key in SortKey.allCases {
            menu.addItem(makeMenuItem(key.label, checked: sortKey == key) { [weak self] in
                guard let self else { return }
                if key == self.sortKey {
                    self.onSort?(key, self.sortDir == .asc ? .desc : .asc)
                } else {
                    self.onSort?(key, key == .modified ? .desc : .asc)
                }
            })
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Ascending", checked: sortDir == .asc) { [weak self] in
            self?.onSort?(self?.sortKey ?? .name, .asc)
        })
        menu.addItem(makeMenuItem("Descending", checked: sortDir == .desc) { [weak self] in
            self?.onSort?(self?.sortKey ?? .name, .desc)
        })
        pop(menu, from: sortButton)
    }

    @objc private func viewPressed() {
        let menu = NSMenu()
        for mode in ViewMode.allCases {
            let icon = mode == .details ? "list.bullet.rectangle" : mode == .list ? "list.bullet" : mode == .tiles ? "rectangle.grid.1x2" : "square.grid.2x2"
            menu.addItem(makeMenuItem(mode.label, icon: icon, checked: view == mode) { [weak self] in
                self?.onSetView?(mode)
            })
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Show hidden items", checked: showHidden) { [weak self] in
            self?.onToggleHidden?()
        })
        menu.addItem(makeMenuItem("Show file extensions", checked: showExtensions) { [weak self] in
            self?.onToggleExtensions?()
        })
        pop(menu, from: viewButton)
    }

    @objc private func detailsPressed() {
        onToggleDetails?()
    }

    @objc private func overflowPressed() {
        let menu = NSMenu()
        menu.addItem(makeMenuItem("Details pane", icon: "sidebar.right", checked: detailsOpen) { [weak self] in
            self?.onToggleDetails?()
        })
        menu.addItem(makeMenuItem("Navigation pane", icon: "sidebar.left", checked: sidebarVisible) { [weak self] in
            self?.onToggleSidebar?()
        })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(
            pinnedSelection ? "Unpin from Quick access" : "Pin to Quick access",
            icon: pinnedSelection ? "pin.slash" : "pin",
            enabled: canPin
        ) { [weak self] in
            self?.onTogglePin?()
        })
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("Open in Terminal", icon: "terminal") { [weak self] in
            self?.onOpenTerminal?()
        })
        menu.addItem(.separator())
        let themeMenu = NSMenu()
        themeMenu.addItem(makeMenuItem("Use system setting", icon: "desktopcomputer", checked: theme == .system) { [weak self] in
            self?.onSetTheme?(.system)
        })
        themeMenu.addItem(makeMenuItem("Light", icon: "sun.max", checked: theme == .light) { [weak self] in
            self?.onSetTheme?(.light)
        })
        themeMenu.addItem(makeMenuItem("Dark", icon: "moon", checked: theme == .dark) { [weak self] in
            self?.onSetTheme?(.dark)
        })
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.image = Icons.symbol("circle.lefthalf.filled", size: 13)
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem("About Mac Explorer", icon: "info.circle") { [weak self] in
            self?.onShowAbout?()
        })
        pop(menu, from: overflowButton)
    }

    private func pop(_ menu: NSMenu, from button: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}

@MainActor
final class StatusBarView: ThemedView {
    var onViewChange: ((ViewMode) -> Void)?
    var onToggleDetails: (() -> Void)?

    private let label = makeLabel("", size: 12, color: Theme.textSecondary)
    private let detailsButton = HoverButton(title: "", image: "list.bullet.rectangle")
    private let listButton = HoverButton(title: "", image: "list.bullet")
    private let gridButton = HoverButton(title: "", image: "square.grid.2x2")
    private let tilesButton = HoverButton(title: "", image: "rectangle.grid.1x2")
    private let paneButton = HoverButton(title: "", image: "sidebar.right")
    private var view: ViewMode = .details
    private var detailsOpen = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.content
        addSubview(label)
        for (button, mode, tip) in [
            (detailsButton, ViewMode.details, "Details"),
            (listButton, ViewMode.list, "List"),
            (gridButton, ViewMode.large, "Icons"),
            (tilesButton, ViewMode.tiles, "Tiles"),
        ] {
            button.imagePosition = .imageOnly
            button.cornerRadius = 3
            button.target = self
            button.action = #selector(viewPressed(_:))
            button.tag = ViewMode.allCases.firstIndex(of: mode) ?? 0
            button.toolTip = tip
            addSubview(button)
        }
        paneButton.imagePosition = .imageOnly
        paneButton.cornerRadius = 3
        paneButton.target = self
        paneButton.action = #selector(panePressed)
        paneButton.toolTip = "Details pane"
        addSubview(paneButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(label text: String, view: ViewMode, detailsOpen: Bool) {
        self.view = view
        self.detailsOpen = detailsOpen
        label.stringValue = text
        for button in [detailsButton, listButton, gridButton, tilesButton] {
            let mode = ViewMode.allCases[button.tag]
            let active = mode == view || (mode == .large && view == .medium)
            button.isActive = active
            button.contentTintColor = active ? Theme.accent : Theme.textSecondary
            button.updateBackground()
        }
        paneButton.isActive = detailsOpen
        paneButton.contentTintColor = detailsOpen ? Theme.accent : Theme.textSecondary
        paneButton.updateBackground()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 240), height: 16)
        var x = bounds.width - 12
        let buttons = [paneButton, tilesButton, gridButton, listButton, detailsButton]
        for button in buttons {
            x -= 28
            button.frame = NSRect(x: x, y: (bounds.height - 22) / 2, width: 26, height: 22)
            x -= 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.hairline.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0.5))
        path.line(to: NSPoint(x: bounds.width, y: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func viewPressed(_ sender: NSButton) {
        guard sender.tag < ViewMode.allCases.count else { return }
        onViewChange?(ViewMode.allCases[sender.tag])
    }

    @objc private func panePressed() {
        onToggleDetails?()
    }
}
