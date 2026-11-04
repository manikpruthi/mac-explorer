import AppKit

@MainActor
final class DuplicatesOverlay: OverlayView, NSTableViewDataSource, NSTableViewDelegate {
    var onReveal: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    var onTrash: (([String]) -> Void)?

    private enum Row {
        case header(Int)
        case file(Int, String)
    }

    private let root: String
    private let head = makeLabel("Find duplicates", size: 15, weight: .semibold)
    private let close = HoverButton(title: "", image: "xmark")
    private let rootLabel = makeLabel("", size: 12, color: Theme.textSecondary)
    private let statusLabel = makeLabel("", size: 12.5)
    private let spinner = NSProgressIndicator()
    private let scroll = makeScroller()
    private let table = NSTableView()
    private let selectButton = HoverButton(title: "Select extra copies")
    private let clearButton = HoverButton(title: "Clear")
    private let revealButton = HoverButton(title: "Show in folder")
    private let trashButton = HoverButton(title: "Move to Trash")
    private let doneButton = HoverButton(title: "Close")
    private var groups: [DuplicateGroup] = []
    private var rows: [Row] = []
    private var marked = Set<String>()
    private var scanTask: Task<Void, Never>?
    private var result: DuplicateScanResult?

    init(root: String, showHidden: Bool) {
        self.root = root
        super.init(cardSize: NSSize(width: 720, height: 540))
        dismissOnOutsideClick = false
        close.imagePosition = .imageOnly
        close.cornerRadius = 3
        close.target = self
        close.action = #selector(closePressed)
        rootLabel.stringValue = root
        rootLabel.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        for button in [selectButton, clearButton, revealButton, trashButton, doneButton] {
            button.isBordered = true
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12.5)
        }
        trashButton.bezelColor = Theme.danger
        trashButton.contentTintColor = .white
        selectButton.target = self
        selectButton.action = #selector(selectExtras)
        clearButton.target = self
        clearButton.action = #selector(clearMarks)
        revealButton.target = self
        revealButton.action = #selector(revealPressed)
        trashButton.target = self
        trashButton.action = #selector(trashPressed)
        doneButton.target = self
        doneButton.action = #selector(closePressed)
        doneButton.keyEquivalent = "\u{1b}"

        [head, close, rootLabel, statusLabel, spinner, scroll, selectButton, clearButton, revealButton, trashButton, doneButton]
            .forEach { card.addSubview($0) }

        let width = cardSize.width
        let height = cardSize.height
        head.frame = NSRect(x: 18, y: 16, width: 300, height: 20)
        close.frame = NSRect(x: width - 36, y: 10, width: 24, height: 24)
        rootLabel.frame = NSRect(x: 18, y: 40, width: width - 36, height: 16)
        spinner.frame = NSRect(x: 18, y: 66, width: 16, height: 16)
        statusLabel.frame = NSRect(x: 42, y: 65, width: width - 60, height: 18)
        scroll.frame = NSRect(x: 12, y: 92, width: width - 24, height: height - 92 - 60)
        layoutButtons()

        start(showHidden: showHidden)
        updateButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { scanTask?.cancel() }
    }

    private func start(showHidden: Bool) {
        statusLabel.stringValue = "Scanning files…"
        let root = self.root
        let report: @Sendable (DuplicateFinder.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.show(phase) }
        }
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = DuplicateFinder.scan(root: root, showHidden: showHidden, progress: report)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.finish(result) }
        }
    }

    private func show(_ phase: DuplicateFinder.Phase) {
        guard result == nil else { return }
        switch phase {
        case .scanning(let files):
            statusLabel.stringValue = "Scanning… \(files.formatted()) files"
        case .comparing(let done, let total):
            statusLabel.stringValue = "Comparing contents… \(done.formatted()) of \(total.formatted()) candidates"
        }
    }

    private func finish(_ result: DuplicateScanResult) {
        self.result = result
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.frame.origin.x = 18
        groups = result.groups
        rebuildRows()
    }

    private func rebuildRows() {
        rows = []
        for (index, group) in groups.enumerated() {
            rows.append(.header(index))
            for path in group.paths { rows.append(.file(index, path)) }
        }
        marked = marked.filter { path in groups.contains { $0.paths.contains(path) } }
        table.reloadData()
        updateStatus()
        updateButtons()
    }

    private func updateStatus() {
        guard let result else { return }
        let wasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
        let scanned = "Scanned \(result.scannedFiles.formatted()) file\(result.scannedFiles == 1 ? "" : "s")"
        let partial = result.truncated ? " (stopped early — results are partial)" : ""
        if groups.isEmpty {
            statusLabel.stringValue = "No duplicate files found. \(scanned)\(partial)."
        } else {
            let sets = "\(groups.count.formatted()) set\(groups.count == 1 ? "" : "s") of duplicates"
            statusLabel.stringValue = "\(sets) · \(FormatTools.bytes(wasted)) reclaimable · \(scanned)\(partial)"
        }
    }

    private func updateButtons() {
        selectButton.isEnabled = !groups.isEmpty
        clearButton.isEnabled = !marked.isEmpty
        trashButton.isEnabled = !marked.isEmpty
        trashButton.title = marked.isEmpty ? "Move to Trash" : "Move \(marked.count.formatted()) to Trash"
        revealButton.isEnabled = clickedPath() != nil
        layoutButtons()
    }

    /// Sized to the titles, so a long count ("Move 12,345 to Trash") never truncates.
    private func layoutButtons() {
        let buttonY = cardSize.height - 46
        layoutButtonRow([selectButton, clearButton, revealButton], leading: 18, y: buttonY, spacing: 4, minimumWidth: 70)
        layoutButtonRow([trashButton, doneButton], trailing: cardSize.width - 18, y: buttonY, spacing: 6, minimumWidth: 78)
    }

    private func clickedPath() -> String? {
        let index = table.selectedRow
        guard index >= 0, index < rows.count, case .file(_, let path) = rows[index] else { return nil }
        return path
    }

    // MARK: - Actions

    @objc private func selectExtras() {
        // Keep the first (shortest-path) copy of every set; mark the rest.
        marked = Set(groups.flatMap { $0.paths.dropFirst() })
        table.reloadData()
        updateButtons()
    }

    @objc private func clearMarks() {
        marked = []
        table.reloadData()
        updateButtons()
    }

    @objc private func revealPressed() {
        guard let path = clickedPath() else { return }
        onReveal?(path)
    }

    @objc private func rowDoubleClicked() {
        guard let path = clickedPath() else { return }
        onOpen?(path)
    }

    @objc private func trashPressed() {
        guard !marked.isEmpty else { return }
        // Never trash every copy of a set from this dialog.
        let doomed = marked
        for group in groups where group.paths.allSatisfy({ doomed.contains($0) }) {
            statusLabel.stringValue = "Leave at least one copy of “\(PathTools.basename(group.paths[0]))” unselected."
            statusLabel.textColor = Theme.danger
            return
        }
        statusLabel.textColor = Theme.textPrimary
        onTrash?(Array(doomed))
        groups = groups.compactMap { group in
            let remaining = group.paths.filter { !doomed.contains($0) }
            return remaining.count > 1 ? DuplicateGroup(size: group.size, paths: remaining) : nil
        }
        marked = []
        rebuildRows()
    }

    @objc private func toggleMark(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < rows.count, case .file(_, let path) = rows[sender.tag] else { return }
        if sender.state == .on { marked.insert(path) } else { marked.remove(path) }
        updateButtons()
    }

    @objc private func closePressed() {
        scanTask?.cancel()
        onDismiss?()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = rows[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let index):
            let group = groups[index]
            let cell = reuse(tableView, "header") { HeaderCell() }
            cell.label.stringValue = "\(group.paths.count) copies · \(FormatTools.bytes(group.size)) each · \(FormatTools.bytes(group.wastedBytes)) reclaimable"
            return cell
        case .file(_, let path):
            let cell = reuse(tableView, "file") { FileCell() }
            cell.box.target = self
            cell.box.action = #selector(toggleMark(_:))
            cell.box.tag = row
            cell.box.state = marked.contains(path) ? .on : .off
            let name = PathTools.basename(path)
            cell.icon.image = IconService.shared.genericIcon(kind: FileKinds.kind(name, isDirectory: false), size: 16)
            cell.name.stringValue = name
            cell.folder.stringValue = PathTools.dirname(path)
            cell.toolTip = path
            return cell
        }
    }

    private func reuse<T: NSView>(_ tableView: NSTableView, _ id: String, make: () -> T) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? T { return view }
        let view = make()
        view.identifier = identifier
        return view
    }

    private final class HeaderCell: NSTableCellView {
        let label = makeLabel("", size: 12, weight: .semibold, color: Theme.textSecondary)
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            label.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: bounds.width - 16, height: 16)
        }
    }

    private final class FileCell: NSTableCellView {
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let icon = NSImageView()
        let name = makeLabel("", size: 12.5)
        let folder = makeLabel("", size: 12, color: Theme.textSecondary)
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            folder.lineBreakMode = .byTruncatingMiddle
            [box, icon, name, folder].forEach { addSubview($0) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            let midY = bounds.height / 2
            box.frame = NSRect(x: 20, y: midY - 9, width: 20, height: 18)
            icon.frame = NSRect(x: 46, y: midY - 8, width: 16, height: 16)
            let nameWidth = min(260, bounds.width * 0.38)
            name.frame = NSRect(x: 68, y: midY - 8, width: nameWidth, height: 16)
            folder.frame = NSRect(x: 76 + nameWidth, y: midY - 8, width: max(0, bounds.width - nameWidth - 84), height: 16)
        }
    }
}
