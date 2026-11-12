import AppKit

/// Shows every metadata source for one item, edits single values in place, and clears a whole
/// section or everything removable. Created on demand and released when closed; values are read
/// off the main thread and only the visible rows have views.
@MainActor
final class MetadataOverlay: OverlayView, NSTableViewDataSource, NSTableViewDelegate {
    /// Called after a change was written, so the browser can refresh.
    var onChanged: (() -> Void)?

    private enum Row {
        case header(Int)
        case item(Int, Int)
        case note(Int)
    }

    private let path: String
    private let head = makeLabel("Metadata", size: 15, weight: .semibold)
    private let close = HoverButton(title: "", image: "xmark")
    private let nameLabel = makeLabel("", size: 13, weight: .semibold)
    private let pathLabel = makeLabel("", size: 12, color: Theme.textSecondary)
    private let scroll = makeScroller()
    private let table = EditableTableView()
    private let statusLabel = makeLabel("", size: 12, color: Theme.textSecondary, lines: 2)
    private let clearAllButton = HoverButton(title: "Clear all metadata…", image: "eraser")
    private let confirmButton = HoverButton(title: "Remove")
    private let cancelConfirmButton = HoverButton(title: "Cancel")
    private let doneButton = HoverButton(title: "Close")
    private var groups: [MetadataGroup] = []
    private var rows: [Row] = []
    private var busy = false
    /// Label column width, sized to the longest label so names like
    /// "Photos Scene Classification Type" aren't cut off.
    private var labelWidth: CGFloat = 150
    /// Keys waiting for the user to confirm a section or Clear all.
    private var pendingClear: [MetadataKey]?

    init(path: String) {
        self.path = path
        super.init(cardSize: NSSize(width: 760, height: 600))
        dismissOnOutsideClick = false
        close.imagePosition = .imageOnly
        close.cornerRadius = 3
        close.target = self
        close.action = #selector(closePressed)
        nameLabel.stringValue = PathTools.basename(path)
        pathLabel.stringValue = PathTools.dirname(path)
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table

        for button in [clearAllButton, confirmButton, cancelConfirmButton, doneButton] {
            button.isBordered = true
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 12.5)
        }
        clearAllButton.imagePosition = .imageLeading
        clearAllButton.target = self
        clearAllButton.action = #selector(clearAllPressed)
        confirmButton.bezelColor = Theme.danger
        confirmButton.contentTintColor = .white
        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed)
        cancelConfirmButton.target = self
        cancelConfirmButton.action = #selector(cancelConfirm)
        doneButton.target = self
        doneButton.action = #selector(closePressed)

        [head, close, nameLabel, pathLabel, scroll, statusLabel, clearAllButton, confirmButton, cancelConfirmButton, doneButton]
            .forEach { card.addSubview($0) }

        layoutCard()

        statusLabel.stringValue = "Reading metadata…"
        reload(status: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The card fits small windows: up to 760×600, never closer than 16 pt to the window edge.
    override func layout() {
        let fitted = NSSize(
            width: max(520, min(760, bounds.width - 32)),
            height: max(360, min(600, bounds.height - 32))
        )
        if bounds.width > 0, fitted != cardSize {
            cardSize = fitted
            layoutCard()
        }
        super.layout()
    }

    private func layoutCard() {
        let width = cardSize.width
        let height = cardSize.height
        head.frame = NSRect(x: 18, y: 16, width: 300, height: 20)
        close.frame = NSRect(x: width - 36, y: 10, width: 24, height: 24)
        nameLabel.frame = NSRect(x: 18, y: 44, width: width - 36, height: 18)
        pathLabel.frame = NSRect(x: 18, y: 64, width: width - 36, height: 16)
        scroll.frame = NSRect(x: 8, y: 90, width: width - 16, height: height - 90 - 96)
        statusLabel.frame = NSRect(x: 18, y: height - 88, width: width - 36, height: 32)
        updateFooter()
    }

    // MARK: - Data

    private func reload(status: String?, isError: Bool = false) {
        let path = self.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = MetadataService.read(path)
            await MainActor.run { [weak self] in self?.show(report, status: status, isError: isError) }
        }
    }

    private func show(_ report: MetadataReport?, status: String?, isError: Bool) {
        busy = false
        guard let report else {
            groups = []
            rows = []
            table.reloadData()
            setStatus("This item no longer exists.", isError: true)
            updateFooter()
            return
        }
        groups = report.groups
        let font = NSFont.systemFont(ofSize: 12)
        let longest = groups.flatMap(\.items).reduce(CGFloat(0)) {
            max($0, ($1.label as NSString).size(withAttributes: [.font: font]).width)
        }
        labelWidth = min(max(120, ceil(longest) + 20), (cardSize.width - 16) * 0.42)
        rows = []
        for (groupIndex, group) in groups.enumerated() {
            rows.append(.header(groupIndex))
            if let note = group.note, !note.isEmpty { rows.append(.note(groupIndex)) }
            for itemIndex in group.items.indices { rows.append(.item(groupIndex, itemIndex)) }
        }
        let visible = table.visibleRect
        table.reloadData()
        table.scrollToVisible(visible)
        if let status {
            setStatus(status, isError: isError)
        } else {
            let editable = groups.reduce(0) { $0 + $1.items.filter(\.editable).count }
            let total = groups.reduce(0) { $0 + $1.items.count }
            setStatus("\(total.formatted()) values · \(editable.formatted()) editable. Click a value to edit it and press Return to save.", isError: false)
        }
        updateFooter()
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? Theme.danger : Theme.textSecondary
    }

    private func updateFooter() {
        let confirming = pendingClear != nil
        clearAllButton.isHidden = confirming
        clearAllButton.isEnabled = !busy && groups.contains { !$0.clearableItems.isEmpty }
        confirmButton.isHidden = !confirming
        cancelConfirmButton.isHidden = !confirming
        confirmButton.isEnabled = !busy
        let y = cardSize.height - 48
        layoutButtonRow([clearAllButton], leading: 18, y: y, spacing: 6, minimumWidth: 84)
        layoutButtonRow([cancelConfirmButton, confirmButton, doneButton], trailing: cardSize.width - 18, y: y, spacing: 6, minimumWidth: 78)
    }

    // MARK: - Actions

    private func run(_ status: String, _ work: @escaping @Sendable (String) -> String?) {
        guard !busy else { return }
        busy = true
        pendingClear = nil
        updateFooter()
        setStatus("Saving…", isError: false)
        let path = self.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let error = work(path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if error == nil { self.onChanged?() }
                self.reload(status: error ?? status, isError: error != nil)
            }
        }
    }

    @objc private func valueCommitted(_ sender: NSTextField) {
        guard case .item(let groupIndex, let itemIndex)? = row(sender.tag) else { return }
        let item = groups[groupIndex].items[itemIndex]
        let value = sender.stringValue
        guard item.editable, value != item.value else { return }
        let key = item.key
        run("Saved \(item.label).") { MetadataService.set(key, value: value, path: $0) }
    }

    @objc private func removePressed(_ sender: NSButton) {
        guard case .item(let groupIndex, let itemIndex)? = row(sender.tag) else { return }
        let item = groups[groupIndex].items[itemIndex]
        let key = item.key
        run("Removed \(item.label).") { MetadataService.remove([key], path: $0) }
    }

    @objc private func clearSectionPressed(_ sender: NSButton) {
        guard case .header(let groupIndex)? = row(sender.tag) else { return }
        let group = groups[groupIndex]
        askToClear(group.clearableItems.map(\.key), message: "Remove \(FormatTools.plural(group.clearableItems.count, "value")) from \(group.title)? This can’t be undone.")
    }

    @objc private func clearAllPressed() {
        let keys = groups.flatMap { $0.clearableItems.map(\.key) }
        let kept = groups.contains { $0.items.contains { $0.key == .embedded("tiff:Orientation") } } ? " Image orientation is kept." : ""
        askToClear(keys, message: "Remove all \(FormatTools.plural(keys.count, "removable value")) (tags, comment, download info, embedded EXIF/GPS/IPTC/XMP, and extended attributes)? Dates are kept.\(kept) This can’t be undone.")
    }

    private func askToClear(_ keys: [MetadataKey], message: String) {
        guard !busy, !keys.isEmpty else { return }
        pendingClear = keys
        setStatus(message, isError: true)
        updateFooter()
    }

    @objc private func confirmPressed() {
        guard let keys = pendingClear else { return }
        run("Removed \(FormatTools.plural(keys.count, "value")).") { MetadataService.remove(keys, path: $0) }
    }

    @objc private func cancelConfirm() {
        pendingClear = nil
        reload(status: nil)
        updateFooter()
    }

    @objc private func closePressed() {
        window?.makeFirstResponder(nil)
        onDismiss?()
    }

    private func row(_ index: Int) -> Row? {
        index >= 0 && index < rows.count ? rows[index] : nil
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header(let index): index == 0 ? 30 : 42
        case .note: 20
        case .item: 28
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let index):
            let group = groups[index]
            let cell = reuse(tableView, "header") { HeaderCell() }
            cell.title.stringValue = group.title
            cell.count.stringValue = group.items.isEmpty ? "" : "\(group.items.count)"
            let clearable = group.clearableItems.count
            cell.clear.isHidden = clearable == 0
            cell.clear.isEnabled = !busy
            cell.clear.target = self
            cell.clear.action = #selector(clearSectionPressed(_:))
            cell.clear.tag = row
            cell.clear.setAccessibilityLabel("Clear \(group.title)")
            cell.needsLayout = true
            return cell
        case .note(let index):
            let cell = reuse(tableView, "note") { NoteCell() }
            cell.label.stringValue = groups[index].note ?? ""
            return cell
        case .item(let groupIndex, let itemIndex):
            let item = groups[groupIndex].items[itemIndex]
            let cell = reuse(tableView, "item") { ItemCell() }
            cell.label.stringValue = item.label
            cell.label.toolTip = item.detail ?? item.label
            cell.labelWidth = labelWidth
            cell.configure(value: item.value, editable: item.editable && !busy, hint: item.hint)
            cell.value.tag = row
            cell.value.target = self
            cell.value.action = #selector(valueCommitted(_:))
            cell.value.toolTip = item.value.count > 60 ? item.value : nil
            cell.remove.isHidden = !item.removable
            cell.remove.isEnabled = !busy
            cell.remove.tag = row
            cell.remove.target = self
            cell.remove.action = #selector(removePressed(_:))
            cell.remove.toolTip = "Remove \(item.label)"
            cell.remove.setAccessibilityLabel("Remove \(item.label)")
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

    /// Lets a single click start editing a value field (tables normally want a second click).
    private final class EditableTableView: NSTableView {
        override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
    }

    private final class HeaderCell: NSTableCellView {
        let title = makeLabel("", size: 12.5, weight: .semibold)
        let count = makeLabel("", size: 11.5, color: Theme.textTertiary)
        let clear = HoverButton(title: "Clear")
        let rule = ThemedView()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            clear.font = NSFont.systemFont(ofSize: 12)
            clear.contentTintColor = Theme.accent
            rule.fillColor = Theme.hairline
            [rule, title, count, clear].forEach { addSubview($0) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            let baseline = bounds.height - 24
            rule.frame = NSRect(x: 10, y: baseline - 4, width: bounds.width - 20, height: 1)
            rule.isHidden = bounds.height < 40
            let measured = (title.stringValue as NSString).size(withAttributes: [.font: title.font ?? NSFont.systemFont(ofSize: 12.5)]).width
            let titleWidth = min(bounds.width - 140, ceil(measured) + 4)
            title.frame = NSRect(x: 10, y: baseline + 2, width: titleWidth, height: 18)
            count.frame = NSRect(x: 16 + titleWidth, y: baseline + 3, width: 60, height: 16)
            let clearWidth = clear.widthToFitTitle(minimum: 44)
            clear.frame = NSRect(x: bounds.width - clearWidth - 8, y: baseline, width: clearWidth, height: 22)
        }
    }

    private final class NoteCell: NSTableCellView {
        let label = makeLabel("", size: 11.5, color: Theme.textTertiary)
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            label.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: bounds.width - 20, height: 16)
        }
    }

    private final class ItemCell: NSTableCellView {
        let label = makeLabel("", size: 12, color: Theme.textSecondary)
        let value = NSTextField(string: "")
        let remove = HoverButton(title: "", image: "xmark.circle")
        var labelWidth: CGFloat = 150 {
            didSet { if labelWidth != oldValue { needsLayout = true } }
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            value.font = NSFont.systemFont(ofSize: 12.5)
            value.lineBreakMode = .byTruncatingTail
            value.usesSingleLineMode = true
            value.cell?.sendsActionOnEndEditing = true
            value.cell?.isScrollable = true
            value.focusRingType = .exterior
            remove.imagePosition = .imageOnly
            remove.cornerRadius = 3
            remove.contentTintColor = Theme.textTertiary
            [label, value, remove].forEach { addSubview($0) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(value text: String, editable: Bool, hint: String?) {
            value.stringValue = text
            value.isEditable = editable
            value.isSelectable = true
            value.isBordered = editable
            value.isBezeled = editable
            value.bezelStyle = .squareBezel
            value.drawsBackground = editable
            value.backgroundColor = Theme.field
            value.textColor = Theme.textPrimary
            value.placeholderString = editable ? hint : nil
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let midY = bounds.height / 2
            label.frame = NSRect(x: 18, y: midY - 8, width: labelWidth - 8, height: 16)
            let removeSize: CGFloat = 22
            remove.frame = NSRect(x: bounds.width - removeSize - 8, y: midY - removeSize / 2, width: removeSize, height: removeSize)
            let fieldX = 18 + labelWidth
            let fieldHeight: CGFloat = value.isBezeled ? 22 : 17
            value.frame = NSRect(x: fieldX, y: midY - fieldHeight / 2, width: max(0, remove.frame.minX - fieldX - 6), height: fieldHeight)
        }
    }
}
