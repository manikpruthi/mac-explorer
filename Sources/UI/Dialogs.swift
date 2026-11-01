import AppKit

@MainActor
class OverlayView: NSView {
    let card = ThemedView()
    var cardSize: NSSize
    var onDismiss: (() -> Void)?
    var dismissOnOutsideClick = true

    init(cardSize: NSSize) {
        self.cardSize = cardSize
        super.init(frame: .zero)
        wantsLayer = true
        card.fillColor = Theme.dialog
        card.strokeColor = Theme.hairline
        card.borderWidth = 1
        card.cornerRadius = 8
        card.wantsLayer = true
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.28
        card.layer?.shadowRadius = 28
        card.layer?.shadowOffset = NSSize(width: 0, height: -10)
        addSubview(card)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        card.frame = NSRect(
            x: (bounds.width - cardSize.width) / 2,
            y: (bounds.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if card.frame.contains(point) {
            super.mouseDown(with: event)
        } else if dismissOnOutsideClick {
            onDismiss?()
        }
    }
}

@MainActor
final class AboutOverlay: OverlayView {
    init() {
        super.init(cardSize: NSSize(width: 430, height: 372))
        let icon = NSImageView()
        icon.image = IconService.shared.folderIcon(size: 64)
        icon.imageScaling = .scaleProportionallyUpOrDown
        card.addSubview(icon)

        let title = makeLabel("Mac Explorer", size: 19, weight: .semibold)
        let version = makeLabel("Version \(AppInfo.version)", size: 12, color: Theme.textSecondary)
        let body = makeLabel(
            "A Windows 11 File Explorer-style file manager, reverse-engineered for macOS. Tabs, breadcrumbs, command bar, Quick access, Gallery, details pane, and the Windows selection model — backed by your real filesystem.",
            size: 12.5,
            color: Theme.textPrimary,
            lines: 5
        )
        body.alignment = .center
        let meta = makeLabel(
            "Native AppKit build. Not affiliated with Microsoft.",
            size: 11.5,
            color: Theme.textSecondary,
            lines: 2
        )
        meta.alignment = .center
        let ok = HoverButton(title: "OK", image: nil, target: nil, action: nil)
        ok.bezelStyle = .rounded
        ok.isBordered = true
        ok.keyEquivalent = "\r"
        ok.target = self
        ok.action = #selector(okPressed)

        [title, version, body, meta, ok].forEach { card.addSubview($0) }
        icon.frame = NSRect(x: (cardSize.width - 64) / 2, y: 26, width: 64, height: 64)
        title.frame = NSRect(x: 24, y: 102, width: cardSize.width - 48, height: 24)
        title.alignment = .center
        version.frame = NSRect(x: 24, y: 128, width: cardSize.width - 48, height: 16)
        version.alignment = .center
        body.frame = NSRect(x: 36, y: 158, width: cardSize.width - 72, height: 84)
        meta.frame = NSRect(x: 36, y: 250, width: cardSize.width - 72, height: 36)
        ok.frame = NSRect(x: (cardSize.width - 90) / 2, y: cardSize.height - 52, width: 90, height: 28)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func okPressed() {
        onDismiss?()
    }
}

@MainActor
final class PropertiesOverlay: OverlayView {
    var onEditPermissions: (() -> Void)? {
        didSet { permissionsButton.isHidden = onEditPermissions == nil || !loaded || errorMessage != nil }
    }

    private let permissionsButton = HoverButton(title: "Permissions…", image: "lock.shield")
    private let head = makeLabel("Properties", size: 15, weight: .semibold)
    private let close = HoverButton(title: "", image: "xmark")
    private let spinner = NSProgressIndicator()
    private let summaryIcon = NSImageView()
    private let nameLabel = makeLabel("", size: 14, weight: .semibold, lines: 2)
    private let typeLabel = makeLabel("", size: 12, color: Theme.textSecondary)
    private var rows: [(NSTextField, NSTextField)] = []
    private let ok = HoverButton(title: "OK")
    private var values: [(String, String)] = []
    private var loaded = false
    private var errorMessage: String?

    init(paths: [String], kind: FileKind?) {
        super.init(cardSize: NSSize(width: 460, height: 540))
        card.addSubview(head)
        close.imagePosition = .imageOnly
        close.cornerRadius = 3
        close.target = self
        close.action = #selector(okPressed)
        card.addSubview(close)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = false
        spinner.startAnimation(nil)
        card.addSubview(spinner)
        summaryIcon.imageScaling = .scaleProportionallyUpOrDown
        card.addSubview(summaryIcon)
        card.addSubview(nameLabel)
        card.addSubview(typeLabel)
        ok.isBordered = true
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = self
        ok.action = #selector(okPressed)
        card.addSubview(ok)
        permissionsButton.isBordered = true
        permissionsButton.bezelStyle = .rounded
        permissionsButton.font = NSFont.systemFont(ofSize: 12.5)
        permissionsButton.target = self
        permissionsButton.action = #selector(permissionsPressed)
        permissionsButton.isHidden = true
        card.addSubview(permissionsButton)

        head.frame = NSRect(x: 18, y: 16, width: 200, height: 20)
        close.frame = NSRect(x: cardSize.width - 36, y: 10, width: 24, height: 24)
        spinner.frame = NSRect(x: cardSize.width / 2 - 8, y: 160, width: 16, height: 16)
        ok.frame = NSRect(x: cardSize.width - 96, y: cardSize.height - 44, width: 78, height: 28)
        permissionsButton.frame = NSRect(x: 18, y: cardSize.height - 44, width: 132, height: 28)

        load(paths: paths, kind: kind)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func load(paths: [String], kind: FileKind?) {
        Task.detached(priority: .userInitiated) { [paths] in
            let result = FileService.properties(paths)
            await MainActor.run { [weak self] in
                self?.apply(result: result, kind: kind)
            }
        }
    }

    private func apply(result: PropertiesResult, kind: FileKind?) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        loaded = true
        if !result.ok {
            errorMessage = result.error ?? "Unable to read properties."
            nameLabel.stringValue = "Properties unavailable"
            typeLabel.stringValue = ""
            layoutRows()
            return
        }
        let isApp = (result.path as NSString).pathExtension.lowercased() == "app"
        summaryIcon.image = isApp
            ? IconService.shared.workspaceIcon(forPath: result.path, size: 48)
            : IconService.shared.genericIcon(kind: kind ?? (result.isDirectory ? .folder : .file), size: 48)
        nameLabel.stringValue = result.name
        typeLabel.stringValue = result.type
        values = [
            ("Location", result.location),
            ("Size", (result.truncated ? "At least " : "") + FormatTools.bytes(result.size)),
            ("Size on disk", (result.truncated ? "At least " : "") + FormatTools.bytes(result.sizeOnDisk)),
        ]
        if result.isDirectory {
            values.append(("Contains", "\(result.files) file\(result.files == 1 ? "" : "s"), \(result.folders) folder\(result.folders == 1 ? "" : "s")"))
        }
        values.append(("Created", FormatTools.date(result.created)))
        values.append(("Modified", FormatTools.date(result.modified)))
        if !result.multiple, let permissions = PermissionsService.read(result.path) {
            let lock = permissions.locked ? " · Locked" : ""
            values.append(("Permissions", "\(permissions.symbolic) (\(permissions.octal)) · \(permissions.owner):\(permissions.group)\(lock)"))
        }
        values.append(("Path", result.path))
        permissionsButton.isHidden = onEditPermissions == nil
        layoutRows()
    }

    private func layoutRows() {
        rows.forEach {
            $0.0.removeFromSuperview()
            $0.1.removeFromSuperview()
        }
        rows = []
        summaryIcon.frame = NSRect(x: 24, y: 56, width: 48, height: 48)
        let textX: CGFloat = 86
        nameLabel.frame = NSRect(x: textX, y: 60, width: cardSize.width - textX - 24, height: 36)
        typeLabel.frame = NSRect(x: textX, y: 96, width: cardSize.width - textX - 24, height: 16)
        var y: CGFloat = 132
        if let errorMessage {
            let label = makeLabel(errorMessage, size: 12.5, color: Theme.danger, lines: 3)
            label.frame = NSRect(x: 24, y: y, width: cardSize.width - 48, height: 48)
            card.addSubview(label)
            return
        }
        for (title, value) in values {
            let label = makeLabel(title, size: 12, color: Theme.textSecondary)
            let valueLabel = makeLabel(value, size: 12, lines: 3)
            valueLabel.cell?.wraps = true
            valueLabel.lineBreakMode = .byWordWrapping
            valueLabel.isSelectable = true
            card.addSubview(label)
            card.addSubview(valueLabel)
            label.frame = NSRect(x: 24, y: y + 1, width: 90, height: 16)
            let valueWidth = cardSize.width - 24 - 110
            let height = measure(value, width: valueWidth, font: valueLabel.font ?? Theme.smallFont, maxLines: 3)
            valueLabel.frame = NSRect(x: 114, y: y, width: valueWidth, height: max(18, height))
            rows.append((label, valueLabel))
            y += max(24, height + 8)
        }
    }

    private func measure(_ text: String, width: CGFloat, font: NSFont, maxLines: Int) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.ascender - font.descender + font.leading
        return min(CGFloat(maxLines) * lineHeight + 2, ceil(rect.height))
    }

    @objc private func okPressed() {
        onDismiss?()
    }

    @objc private func permissionsPressed() {
        onEditPermissions?()
    }
}

@MainActor
final class ConfirmOverlay: OverlayView {
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let confirmButton: HoverButton
    private let confirmClosure: () -> Void

    init(title: String, message: String, confirmLabel: String, dangerous: Bool, onConfirm: @escaping () -> Void) {
        titleLabel = makeLabel(title, size: 15, weight: .semibold)
        messageLabel = makeLabel(message, size: 12.5, color: Theme.textSecondary, lines: 4)
        confirmButton = HoverButton(title: confirmLabel)
        confirmClosure = onConfirm
        super.init(cardSize: NSSize(width: 430, height: 232))
        dismissOnOutsideClick = false

        let icon = NSImageView()
        icon.image = Icons.symbol(dangerous ? "exclamationmark.triangle" : "info.circle", size: 28)
        icon.image?.isTemplate = true
        icon.contentTintColor = dangerous ? Theme.danger : Theme.accent
        let cancel = HoverButton(title: "Cancel")
        cancel.isBordered = true
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        confirmButton.isBordered = true
        confirmButton.bezelStyle = .rounded
        confirmButton.bezelColor = dangerous ? Theme.danger : Theme.accent
        confirmButton.contentTintColor = .white
        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed)

        [icon, titleLabel, messageLabel, cancel, confirmButton].forEach { card.addSubview($0) }
        icon.frame = NSRect(x: 22, y: 24, width: 30, height: 30)
        titleLabel.frame = NSRect(x: 62, y: 26, width: cardSize.width - 86, height: 22)
        messageLabel.frame = NSRect(x: 24, y: 68, width: cardSize.width - 48, height: 70)
        cancel.frame = NSRect(x: cardSize.width - 196, y: cardSize.height - 48, width: 84, height: 28)
        confirmButton.frame = NSRect(x: cardSize.width - 106, y: cardSize.height - 48, width: 88, height: 28)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func triggerConfirm() {
        confirmPressed()
    }

    @objc private func cancelPressed() {
        onDismiss?()
    }

    @objc private func confirmPressed() {
        confirmClosure()
    }
}

@MainActor
final class ToastView: NSView {
    private let icon = NSImageView()
    private let label = makeLabel("", size: 12.5)

    init(message: String, isError: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.resolved(Theme.menu, for: effectiveAppearance).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Theme.resolved(Theme.hairline, for: effectiveAppearance).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 16
        icon.image = Icons.symbol(isError ? "exclamationmark.triangle" : "checkmark.circle", size: 15)
        icon.image?.isTemplate = true
        icon.contentTintColor = isError ? Theme.danger : Theme.textSecondary
        addSubview(icon)
        label.stringValue = message
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 38, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 52), height: 16)
    }
}

enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
