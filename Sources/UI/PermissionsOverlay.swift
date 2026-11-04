import AppKit

/// Overlays with a primary action that Return should trigger.
@MainActor
protocol DefaultActionOverlay: AnyObject {
    func triggerDefault()
}

@MainActor
final class PermissionsOverlay: OverlayView, DefaultActionOverlay, NSTextFieldDelegate {
    /// Called after a successful apply with the number of changed items.
    var onApplied: ((Int) -> Void)?

    private let paths: [String]
    private let head = makeLabel("Permissions", size: 15, weight: .semibold)
    private let close = HoverButton(title: "", image: "xmark")
    private let nameLabel = makeLabel("", size: 13, weight: .semibold, lines: 2)
    private let ownerLabel = makeLabel("", size: 12, color: Theme.textSecondary, lines: 2)
    private let symbolicLabel = makeLabel("", size: 12)
    private let octalField = NSTextField(string: "")
    private let lockBox = NSButton(checkboxWithTitle: "Locked (prevents changes, renaming, and deletion)", target: nil, action: nil)
    private let recursiveBox = NSButton(checkboxWithTitle: "Apply to enclosed items", target: nil, action: nil)
    private let messageLabel = makeLabel("", size: 12, color: Theme.danger, lines: 3)
    private let applyButton = HoverButton(title: "Apply")
    private let cancelButton = HoverButton(title: "Cancel")
    /// [owner, group, everyone][read, write, execute]
    private var boxes: [[NSButton]] = []
    private var mode: UInt16 = 0
    private var original: PermissionInfo?
    private var busy = false

    init(paths: [String]) {
        self.paths = paths
        super.init(cardSize: NSSize(width: 460, height: 440))
        dismissOnOutsideClick = false
        close.imagePosition = .imageOnly
        close.cornerRadius = 3
        close.target = self
        close.action = #selector(cancelPressed)
        [head, close, nameLabel, ownerLabel, symbolicLabel, octalField, lockBox, recursiveBox, messageLabel, applyButton, cancelButton]
            .forEach { card.addSubview($0) }

        let padding: CGFloat = 24
        let width = cardSize.width
        head.frame = NSRect(x: 18, y: 16, width: 200, height: 20)
        close.frame = NSRect(x: width - 36, y: 10, width: 24, height: 24)
        nameLabel.frame = NSRect(x: padding, y: 50, width: width - padding * 2, height: 34)
        ownerLabel.frame = NSRect(x: padding, y: 86, width: width - padding * 2, height: 32)

        let columns = ["Read", "Write", "Execute"]
        let rows = ["Owner", "Group", "Everyone"]
        let gridTop: CGFloat = 128
        let firstColumn: CGFloat = 150
        let columnWidth: CGFloat = 86
        for (index, title) in columns.enumerated() {
            let label = makeLabel(title, size: 12, weight: .semibold, color: Theme.textSecondary)
            label.alignment = .center
            label.frame = NSRect(x: firstColumn + CGFloat(index) * columnWidth, y: gridTop, width: columnWidth, height: 16)
            card.addSubview(label)
        }
        for (row, title) in rows.enumerated() {
            let y = gridTop + 26 + CGFloat(row) * 30
            let label = makeLabel(title, size: 12.5)
            label.frame = NSRect(x: padding, y: y + 2, width: 120, height: 18)
            card.addSubview(label)
            var rowBoxes: [NSButton] = []
            for column in 0..<3 {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxChanged(_:)))
                box.tag = row * 3 + column
                box.frame = NSRect(x: firstColumn + CGFloat(column) * columnWidth + columnWidth / 2 - 9, y: y, width: 20, height: 20)
                box.setAccessibilityLabel("\(title) \(columns[column])")
                card.addSubview(box)
                rowBoxes.append(box)
            }
            boxes.append(rowBoxes)
        }

        let octalTitle = makeLabel("Numeric", size: 12.5)
        octalTitle.frame = NSRect(x: padding, y: gridTop + 122, width: 120, height: 18)
        card.addSubview(octalTitle)
        octalField.frame = NSRect(x: firstColumn + 8, y: gridTop + 119, width: 70, height: 22)
        octalField.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        octalField.delegate = self
        octalField.placeholderString = "755"
        symbolicLabel.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        symbolicLabel.textColor = Theme.textSecondary
        symbolicLabel.frame = NSRect(x: firstColumn + 92, y: gridTop + 122, width: 160, height: 18)

        lockBox.frame = NSRect(x: padding - 2, y: gridTop + 158, width: width - padding * 2, height: 20)
        recursiveBox.frame = NSRect(x: padding - 2, y: gridTop + 184, width: width - padding * 2, height: 20)
        messageLabel.frame = NSRect(x: padding, y: gridTop + 212, width: width - padding * 2, height: 46)

        for button in [applyButton, cancelButton] {
            button.isBordered = true
            button.bezelStyle = .rounded
        }
        applyButton.bezelColor = Theme.accent
        applyButton.contentTintColor = .white
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        layoutButtonRow([cancelButton, applyButton], trailing: width - 18, y: cardSize.height - 48, spacing: 6)

        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func load() {
        guard let first = paths.first, let info = PermissionsService.read(first) else {
            nameLabel.stringValue = "Permissions unavailable"
            messageLabel.stringValue = "This item no longer exists."
            applyButton.isEnabled = false
            return
        }
        original = info
        mode = info.mode
        nameLabel.stringValue = paths.count == 1 ? PathTools.basename(first) : "\(paths.count) items (showing the first)"
        ownerLabel.stringValue = "Owner: \(info.owner) · Group: \(info.group)"
        lockBox.state = info.locked ? .on : .off
        let hasFolder = paths.contains { PermissionsService.read($0)?.isDirectory == true }
        recursiveBox.isHidden = !hasFolder
        if info.isSymlink {
            messageLabel.stringValue = "This is a symbolic link; macOS uses the permissions of the item it points to."
        } else if !info.ownedByCurrentUser {
            messageLabel.textColor = Theme.textSecondary
            messageLabel.stringValue = "You are not the owner of this item, so changes will probably be refused. Mac Explorer never asks for administrator rights."
        }
        syncControls(updateField: true)
    }

    private func syncControls(updateField: Bool) {
        for row in 0..<3 {
            let shift = UInt16(6 - row * 3)
            for column in 0..<3 {
                let bit: UInt16 = UInt16(4 >> column) << shift
                boxes[row][column].state = mode & bit != 0 ? .on : .off
            }
        }
        if updateField { octalField.stringValue = String(mode & 0o777, radix: 8) }
        symbolicLabel.stringValue = PermissionsService.symbolic(mode, isDirectory: original?.isDirectory ?? false)
    }

    @objc private func boxChanged(_ sender: NSButton) {
        let row = sender.tag / 3
        let column = sender.tag % 3
        let bit: UInt16 = UInt16(4 >> column) << UInt16(6 - row * 3)
        if sender.state == .on { mode |= bit } else { mode &= ~bit }
        syncControls(updateField: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        if let parsed = PermissionsService.parseOctal(octalField.stringValue) {
            mode = (mode & 0o7000) | (parsed & 0o777)
            syncControls(updateField: false)
        }
    }

    func triggerDefault() { applyPressed() }

    @objc private func applyPressed() {
        guard !busy, original != nil else { return }
        if PermissionsService.parseOctal(octalField.stringValue) == nil {
            messageLabel.textColor = Theme.danger
            messageLabel.stringValue = "Enter a 3-digit octal value such as 755 or 644."
            return
        }
        busy = true
        applyButton.isEnabled = false
        let paths = self.paths
        let mode = self.mode
        let locked = lockBox.state == .on
        let recursive = !recursiveBox.isHidden && recursiveBox.state == .on
        Task.detached(priority: .userInitiated) { [weak self] in
            // Unchanged items are skipped inside apply, so passing both values is cheap.
            let result = PermissionsService.apply(paths: paths, mode: mode, locked: locked, recursive: recursive)
            await MainActor.run { [weak self] in self?.finish(result) }
        }
    }

    private func finish(_ result: OpResult) {
        busy = false
        applyButton.isEnabled = true
        if result.ok, result.error == nil {
            onApplied?(result.count ?? 0)
            onDismiss?()
            return
        }
        messageLabel.textColor = Theme.danger
        messageLabel.stringValue = result.error ?? "Unable to change permissions."
    }

    @objc private func cancelPressed() {
        onDismiss?()
    }
}
