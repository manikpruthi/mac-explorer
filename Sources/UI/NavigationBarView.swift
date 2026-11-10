import AppKit

@MainActor
final class NavigationBarView: ThemedView, NSTextFieldDelegate {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onUp: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onNavigatePath: ((String) -> Void)?
    var onNavigateArchiveInner: ((String) -> Void)?
    var onEditAddress: ((String) -> Void)?
    var onSearchChange: ((String) -> Void)?
    var onDropPaths: (([String], String, Bool) -> Void)?

    private let sidebarButton = IconButton(image: "sidebar.left", accessibility: "Navigation pane")
    private let backButton = IconButton(image: "chevron.left", accessibility: "Back (⌘[)")
    private let forwardButton = IconButton(image: "chevron.right", accessibility: "Forward (⌘])")
    private let upButton = IconButton(image: "chevron.up", accessibility: "Up (⌘↑)")
    private let refreshButton = IconButton(image: "arrow.clockwise", accessibility: "Refresh (⌘R)")
    private let separator = ThemedView()
    private let addressContainer = AddressContainerView()
    private let crumbsView = ClickView()
    private let addressField = FlatTextField()
    private let searchContainer = ThemedView()
    private let searchIcon = NSImageView()
    private let searchField = SearchField()
    private let searchClear = HoverButton()

    private var currentLocation: Location = .home
    private var currentSystem: SystemInfo?
    private var crumbs: [CrumbModel] = []
    private var addressEditing = false
    private let searchWidth: CGFloat = 220

    private struct CrumbModel: Equatable {
        let label: String
        let path: String
        let icon: String?
        let isCurrent: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.surface
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        for button in [sidebarButton, backButton, forwardButton, upButton, refreshButton] {
            addSubview(button)
            button.cornerRadius = 4
            button.imagePosition = .imageOnly
        }
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarPressed)
        backButton.target = self
        backButton.action = #selector(backPressed)
        forwardButton.target = self
        forwardButton.action = #selector(forwardPressed)
        upButton.target = self
        upButton.action = #selector(upPressed)
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        for button in [backButton, forwardButton, upButton] {
            button.imagePosition = .imageOnly
        }

        separator.fillColor = Theme.hairline
        addSubview(separator)

        addressContainer.fillColor = Theme.field
        addressContainer.strokeColor = Theme.controlBorder
        addressContainer.borderWidth = 1
        addressContainer.cornerRadius = 4
        addSubview(addressContainer)
        addressContainer.onClick = { [weak self] in self?.beginAddressEdit() }
        crumbsView.onClick = { [weak self] in self?.beginAddressEdit() }
        addressContainer.addSubview(crumbsView)
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.isHidden = true
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.addSubview(addressField)
        let fieldLeading = addressField.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 7)
        let fieldTrailing = addressField.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -7)
        fieldLeading.priority = .defaultHigh
        fieldTrailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            fieldLeading,
            fieldTrailing,
            addressField.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 18),
        ])

        searchContainer.fillColor = Theme.field
        searchContainer.strokeColor = Theme.controlBorder
        searchContainer.borderWidth = 1
        searchContainer.cornerRadius = 4
        addSubview(searchContainer)

        searchIcon.image = Icons.symbol("magnifyingglass", size: 13)
        searchIcon.image?.isTemplate = true
        searchIcon.contentTintColor = Theme.textSecondary
        searchContainer.addSubview(searchIcon)

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.font = NSFont.systemFont(ofSize: 12.5)
        searchField.textColor = Theme.textPrimary
        searchField.placeholderString = "Search"
        searchField.toolTip = """
            Search names in this folder and its subfolders (uses the Spotlight index when available).
            Wildcards: *.pdf   Exact: "annual report"
            Filters: kind:image  ext:swift  size:>10MB  size:large
                     modified:today  modified:>2025-01-01  content:invoice
            """
        searchField.focusRingType = .none
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.delegate = self
        searchField.onEscape = { [weak self] in
            guard let self else { return }
            if !self.searchField.stringValue.isEmpty {
                self.searchField.stringValue = ""
                self.onSearchChange?("")
                self.updateSearchClear()
            } else {
                self.window?.makeFirstResponder(nil)
            }
        }
        searchContainer.addSubview(searchField)

        searchClear.image = Icons.symbol("xmark", size: 10, weight: .medium)
        searchClear.image?.isTemplate = true
        searchClear.cornerRadius = 3
        searchClear.isHidden = true
        searchClear.target = self
        searchClear.action = #selector(clearSearch)
        searchClear.toolTip = "Clear search"
        searchContainer.addSubview(searchClear)

        searchField.onTextChange = { [weak self] value in
            self?.onSearchChange?(value)
            self?.updateSearchClear()
        }
    }

    func update(
        location: Location,
        system: SystemInfo?,
        canBack: Bool,
        canForward: Bool,
        canUp: Bool,
        searchEnabled: Bool,
        searchValue: String,
        sidebarVisible: Bool
    ) {
        let locationChanged = currentLocation != location
        if locationChanged { endSearchEditing() }
        currentLocation = location
        currentSystem = system
        backButton.isEnabled = canBack
        forwardButton.isEnabled = canForward
        upButton.isEnabled = canUp
        sidebarButton.isActive = sidebarVisible
        sidebarButton.updateBackground()
        if searchField.stringValue != searchValue && (locationChanged || searchField.currentEditor() == nil) {
            searchField.stringValue = searchValue
        }
        searchField.isEnabled = searchEnabled
        searchContainer.alphaValue = searchEnabled ? 1 : 0.55
        updateSearchClear()
        if !addressEditing {
            rebuildCrumbs()
        }
        needsLayout = true
    }

    private func rebuildCrumbs() {
        let updatedCrumbs = makeCrumbs()
        guard updatedCrumbs != crumbs else { return }
        currentOverflowButton = nil
        hiddenCrumbs = []
        crumbsView.subviews.forEach { $0.removeFromSuperview() }
        crumbs = updatedCrumbs
        guard !crumbs.isEmpty else { return }

        let collapsed = crumbs.count > 5
        let first = crumbs[0]
        let hidden = collapsed ? Array(crumbs[1..<max(1, crumbs.count - 3)]) : []
        var visible = collapsed ? Array(crumbs[(crumbs.count - 3)...]) : crumbs

        var buttons: [NSView] = []
        if collapsed {
            buttons.append(makeCrumbButton(first, current: false))
            let overflow = HoverButton(title: "", image: "ellipsis", target: self, action: #selector(showHiddenCrumbs))
            overflow.cornerRadius = 3
            overflow.toolTip = "Show hidden path segments"
            overflow.tag = hidden.count
            buttons.append(overflow)
            self.hiddenCrumbs = hidden
        } else {
            buttons.append(makeCrumbButton(first, current: crumbs.count == 1))
            visible = Array(crumbs.dropFirst())
        }
        for (index, crumb) in visible.enumerated() {
            let isLast = index == visible.count - 1
            buttons.append(makeChevron())
            buttons.append(makeCrumbButton(crumb, current: isLast))
        }

        var x: CGFloat = 0
        for view in buttons {
            let width: CGFloat
            if let button = view as? HoverButton, button.imagePosition == .imageOnly {
                width = 24
            } else if let button = view as? BreadcrumbButton {
                width = button.desiredWidth
            } else {
                width = 14
            }
            view.frame = NSRect(x: x, y: 1, width: width, height: 24)
            crumbsView.addSubview(view)
            x += width
        }
    }

    private var hiddenCrumbs: [CrumbModel] = []

    private func makeCrumbButton(_ crumb: CrumbModel, current: Bool) -> BreadcrumbButton {
        let button = BreadcrumbButton(title: crumb.label, icon: crumb.icon, isCurrent: current) { [weak self] in
            guard let self else { return }
            if current {
                self.beginAddressEdit()
            } else {
                self.navigateCrumb(crumb)
            }
        }
        if !currentLocation.isArchive, !crumb.path.isEmpty {
            button.dropPath = crumb.path
            button.onDrop = { [weak self] paths, destination, copy in
                self?.onDropPaths?(paths, destination, copy)
            }
        }
        return button
    }

    private func makeChevron() -> NSImageView {
        let view = NSImageView()
        view.image = Icons.symbol("chevron.right", size: 9)
        view.image?.isTemplate = true
        view.contentTintColor = Theme.textTertiary
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    private func makeCrumbs() -> [CrumbModel] {
        guard let system = currentSystem else { return [] }
        switch currentLocation {
        case .home:
            return [CrumbModel(label: "Home", path: system.home, icon: "house", isCurrent: true)]
        case .gallery:
            return [CrumbModel(label: "Gallery", path: system.picturesPath, icon: "photo.on.rectangle", isCurrent: true)]
        case .network:
            return [CrumbModel(label: "Network", path: "", icon: "network", isCurrent: true)]
        case .archive(let archivePath, let extractRoot, let path):
            var result = [CrumbModel(label: PathTools.basename(archivePath), path: extractRoot, icon: "archivebox", isCurrent: path == extractRoot)]
            let inner = PathTools.relative(extractRoot, path)
            var accumulated = extractRoot
            let segments = inner.split(separator: "/").map(String.init)
            for (index, segment) in segments.enumerated() {
                accumulated = (accumulated as NSString).appendingPathComponent(segment)
                result.append(CrumbModel(label: segment, path: accumulated, icon: nil, isCurrent: index == segments.count - 1))
            }
            return result
        case .fs(let path):
            if path == system.trashPath {
                return [CrumbModel(label: "Trash", path: system.trashPath, icon: "trash", isCurrent: true)]
            }
            let volume = system.volumes
                .filter { path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }
                .sorted { $0.path.count > $1.path.count }
                .first
            let volumePath = volume?.path ?? "/"
            let volumeLabel = volume?.name ?? system.volumes.first?.name ?? "Macintosh HD"
            let rest = path == volumePath ? "" : String(path.dropFirst(volumePath == "/" ? 1 : volumePath.count + 1))
            var result = [CrumbModel(label: volumeLabel, path: volumePath, icon: "internaldrive", isCurrent: rest.isEmpty)]
            let segments = rest.split(separator: "/").map(String.init)
            for (index, segment) in segments.enumerated() {
                let crumbPath = volumePath == "/"
                    ? "/" + segments.prefix(index + 1).joined(separator: "/")
                    : volumePath + "/" + segments.prefix(index + 1).joined(separator: "/")
                result.append(CrumbModel(label: segment, path: crumbPath, icon: nil, isCurrent: index == segments.count - 1))
            }
            return result
        }
    }

    private func navigateCrumb(_ crumb: CrumbModel) {
        guard !crumb.path.isEmpty else { return }
        if currentLocation.isArchive {
            onNavigateArchiveInner?(crumb.path)
        } else {
            onNavigatePath?(crumb.path)
        }
    }

    @objc private func showHiddenCrumbs() {
        let menu = NSMenu()
        for crumb in hiddenCrumbs {
            menu.addItem(makeMenuItem(crumb.label, icon: crumb.icon ?? "folder") { [weak self] in
                self?.navigateCrumb(crumb)
            })
        }
        if let view = currentOverflowButton {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 3), in: view)
        }
    }

    private var currentOverflowButton: NSView?

    func beginAddressEdit() {
        guard !currentLocation.isArchive, !currentLocation.isNetwork else { return }
        guard let system = currentSystem else { return }
        addressEditing = true
        crumbsView.isHidden = true
        addressField.isHidden = false
        addressField.stringValue = LocationTools.displayPath(currentLocation, system: system)
        addressContainer.strokeColor = Theme.accent
        needsLayout = true
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    var isEditingAddress: Bool { addressEditing }

    func triggerAddressBarClick() {
        crumbsView.onClick?()
    }

    func cancelAddressEditing() {
        endAddressEdit()
    }

    private func endAddressEdit() {
        addressEditing = false
        addressField.isHidden = true
        crumbsView.isHidden = false
        addressContainer.strokeColor = Theme.controlBorder
        rebuildCrumbs()
        needsLayout = true
    }

    func endSearchEditing() {
        guard let editor = searchField.currentEditor(), window?.firstResponder === editor else { return }
        window?.makeFirstResponder(nil)
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    @objc private func addressSubmitted() {
        let value = addressField.stringValue
        endAddressEdit()
        guard let system = currentSystem else { return }
        let expanded = PathTools.expand(value, home: system.home)
        if !expanded.isEmpty {
            onEditAddress?(expanded)
        }
    }

    @objc private func sidebarPressed() { onToggleSidebar?() }
    @objc private func backPressed() { onBack?() }
    @objc private func forwardPressed() { onForward?() }
    @objc private func upPressed() { onUp?() }
    @objc private func refreshPressed() { onRefresh?() }

    @objc private func clearSearch() {
        searchField.stringValue = ""
        onSearchChange?("")
        updateSearchClear()
        window?.makeFirstResponder(searchField)
    }

    private func updateSearchClear() {
        searchClear.isHidden = searchField.stringValue.isEmpty
        searchContainer.strokeColor = searchField.currentEditor() != nil ? Theme.accent : Theme.controlBorder
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === searchField {
            searchContainer.strokeColor = Theme.accent
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === searchField {
            searchContainer.strokeColor = Theme.controlBorder
        }
        if obj.object as? NSTextField === addressField {
            endAddressEdit()
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let y = (height - 32) / 2
        var x: CGFloat = 8
        for button in [sidebarButton, backButton, forwardButton, upButton] {
            button.frame = NSRect(x: x, y: y, width: 32, height: 32)
            x += 32
        }
        separator.frame = NSRect(x: x + 4, y: (height - 20) / 2, width: 1, height: 20)
        x += 10
        refreshButton.frame = NSRect(x: x, y: y, width: 32, height: 32)
        x += 36

        let searchX = bounds.width - searchWidth - 8
        addressContainer.frame = NSRect(x: x, y: y + (32 - 32) / 2, width: max(120, searchX - 8 - x), height: 32)
        searchContainer.frame = NSRect(x: searchX, y: y, width: searchWidth, height: 32)
        searchIcon.frame = NSRect(x: 9, y: 9, width: 14, height: 14)
        searchClear.frame = NSRect(x: searchWidth - 27, y: 5, width: 22, height: 22)
        searchField.frame = NSRect(x: 30, y: 7, width: searchWidth - 30 - 30, height: 18)

        if !addressEditing {
            layoutCrumbs()
        }
        crumbsView.frame = NSRect(x: 4, y: 3, width: addressContainer.bounds.width - 8, height: 26)
    }

    private func layoutCrumbs() {
        var x: CGFloat = 0
        for view in crumbsView.subviews {
            let width: CGFloat
            if let button = view as? BreadcrumbButton {
                width = button.desiredWidth
            } else if view is NSImageView {
                width = 14
            } else {
                width = 24
            }
            view.frame = NSRect(x: x, y: 1, width: width, height: 24)
            x += width
            if buttonOverflow(view) { currentOverflowButton = view }
        }
    }

    private func buttonOverflow(_ view: NSView) -> Bool {
        (view as? HoverButton)?.toolTip == "Show hidden path segments"
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
}

@MainActor
final class ClickView: NSView {
    var onClick: (() -> Void)?

    nonisolated override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
final class AddressContainerView: ThemedView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
final class SearchField: NSTextField {
    var onEscape: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textChanged(_:)),
            name: NSControl.textDidChangeNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    @objc private func textChanged(_ notification: Notification) {
        onTextChange?(stringValue)
    }
}
