import AppKit

@MainActor
final class DetailsPaneView: ThemedView {
    var onClose: (() -> Void)?
    var onOpen: ((FileEntry) -> Void)?
    var onReveal: ((FileEntry) -> Void)?

    private let scroll = makeScroller()
    private let content = FlippedView()
    private let headLabel = makeLabel("Details", size: 12, weight: .semibold, color: Theme.textSecondary)
    private let closeButton = HoverButton(title: "", image: "xmark")
    private let previewBox = ThemedView()
    private let previewImage = NSImageView()
    private let emptyLabel = makeLabel("Select a file or folder to see its details.", size: 12.5, color: Theme.textSecondary, lines: 3)
    private let nameLabel = makeLabel("", size: 14, weight: .semibold, lines: 2)
    private let subLabel = makeLabel("", size: 12, color: Theme.textSecondary)
    private var rowPool: [(label: NSTextField, value: NSTextField)] = []
    private var activeRowCount = 0
    private var actionPool: [HoverButton] = []
    private var activeActionCount = 0
    private var entries: [FileEntry] = []
    private var isArchive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.content
        scroll.documentView = content
        addSubview(scroll)
        content.addSubview(headLabel)
        closeButton.imagePosition = .imageOnly
        closeButton.cornerRadius = 3
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close details pane"
        content.addSubview(closeButton)
        content.addSubview(emptyLabel)
        emptyLabel.alignment = .center
        previewBox.fillColor = Theme.surface
        previewBox.strokeColor = Theme.hairline
        previewBox.borderWidth = 1
        previewBox.cornerRadius = 6
        content.addSubview(previewBox)
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewBox.addSubview(previewImage)
        content.addSubview(nameLabel)
        content.addSubview(subLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(entries: [FileEntry], isArchive: Bool) {
        self.entries = entries
        self.isArchive = isArchive
        rebuild()
        needsLayout = true
    }

    private func rebuild() {
        activeRowCount = 0
        activeActionCount = 0
        targets.removeAll()

        let hasSelection = !entries.isEmpty
        emptyLabel.isHidden = hasSelection
        previewBox.isHidden = !hasSelection
        nameLabel.isHidden = !hasSelection
        subLabel.isHidden = !hasSelection
        guard hasSelection else {
            previewImage.image = nil
            hideUnusedPoolItems()
            return
        }

        let single = entries.count == 1 ? entries[0] : nil
        let totalSize = entries.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        let latest = entries.reduce(Date(timeIntervalSince1970: 0)) { max($0, $1.modified) }

        if let single {
            nameLabel.stringValue = single.name
            subLabel.stringValue = FileKinds.typeLabel(single.name, single.isDirectory)
            previewImage.image = IconService.shared.fileIcon(for: single, size: 72)
            if single.kind == .image {
                IconService.shared.thumbnail(for: single, size: 300) { [weak self] image in
                    guard let self, let image, self.entries.first?.path == single.path else { return }
                    self.previewImage.image = image
                }
            }
            addRow("Type", FileKinds.typeLabel(single.name, single.isDirectory))
            addRow("Size", single.isDirectory ? "—" : FormatTools.bytes(single.size))
            addRow("Date modified", FormatTools.date(single.modified))
            addRow("Date created", FormatTools.date(single.created))
            addRow("Path", single.path)
        } else {
            nameLabel.stringValue = "\(entries.count) items selected"
            subLabel.stringValue = "Multiple items"
            previewImage.image = IconService.shared.genericIcon(kind: .folder, size: 64)
            addRow("Type", "Multiple types")
            addRow("Size", totalSize > 0 ? FormatTools.bytes(totalSize) : "—")
            addRow("Latest change", FormatTools.date(latest))
        }

        if let single {
            addAction("Open", icon: "arrow.up.forward.app") { [weak self] in self?.onOpen?(single) }
            if !isArchive {
                addAction("Show in Finder", icon: "folder") { [weak self] in self?.onReveal?(single) }
            }
        }

        hideUnusedPoolItems()
    }

    private func hideUnusedPoolItems() {
        for i in activeRowCount..<rowPool.count {
            rowPool[i].label.isHidden = true
            rowPool[i].value.isHidden = true
        }
        for i in activeActionCount..<actionPool.count {
            actionPool[i].isHidden = true
        }
    }

    private func addRow(_ title: String, _ value: String) {
        let pair: (label: NSTextField, value: NSTextField)
        if activeRowCount < rowPool.count {
            pair = rowPool[activeRowCount]
            pair.label.stringValue = title
            pair.value.stringValue = value
            pair.label.isHidden = false
            pair.value.isHidden = false
        } else {
            let label = makeLabel(title, size: 12, color: Theme.textSecondary)
            let valueLabel = makeLabel(value, size: 12, lines: 3)
            valueLabel.cell?.wraps = true
            valueLabel.lineBreakMode = .byWordWrapping
            valueLabel.isSelectable = true
            content.addSubview(label)
            content.addSubview(valueLabel)
            pair = (label, valueLabel)
            rowPool.append(pair)
        }
        activeRowCount += 1
    }

    private func addAction(_ title: String, icon: String, action: @escaping () -> Void) {
        let button: HoverButton
        if activeActionCount < actionPool.count {
            button = actionPool[activeActionCount]
            button.title = title
            let symbol = Icons.symbol(icon, size: 15)
            symbol?.isTemplate = true
            button.image = symbol
            button.isHidden = false
        } else {
            button = HoverButton(title: title, image: icon, target: nil, action: nil)
            button.font = NSFont.systemFont(ofSize: 12)
            button.isBordered = true
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.hoverColor = nil
            content.addSubview(button)
            actionPool.append(button)
        }
        let target = ClosureTarget(action)
        button.target = target
        button.action = #selector(ClosureTarget.fire(_:))
        targets.append(target)
        activeActionCount += 1
    }

    private var targets: [ClosureTarget] = []

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutContent()
    }

    private func layoutContent() {
        let width = max(260, scroll.contentSize.width)
        let padding: CGFloat = 16
        let usable = width - padding * 2
        headLabel.frame = NSRect(x: padding, y: 14, width: usable - 40, height: 16)
        closeButton.frame = NSRect(x: width - padding - 24, y: 8, width: 24, height: 24)

        guard !entries.isEmpty else {
            emptyLabel.frame = NSRect(x: padding, y: 90, width: usable, height: 60)
            content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, 200))
            return
        }

        previewBox.frame = NSRect(x: padding, y: 44, width: usable, height: 168)
        previewImage.frame = NSRect(x: 8, y: 8, width: usable - 16, height: 152)
        previewImage.imageScaling = .scaleProportionallyUpOrDown

        let nameHeight = measure(nameLabel.stringValue, width: usable, font: nameLabel.font ?? Theme.font, maxLines: 2)
        nameLabel.frame = NSRect(x: padding, y: 224, width: usable, height: max(18, nameHeight))
        subLabel.frame = NSRect(x: padding, y: nameLabel.frame.maxY + 2, width: usable, height: 16)

        var y = subLabel.frame.maxY + 14
        for i in 0..<activeRowCount {
            let row = rowPool[i]
            row.label.frame = NSRect(x: padding, y: y + 1, width: 96, height: 16)
            let valueWidth = usable - 102
            let valueHeight = measure(row.value.stringValue, width: valueWidth, font: row.value.font ?? Theme.smallFont, maxLines: 3)
            row.value.frame = NSRect(x: padding + 102, y: y, width: valueWidth, height: max(18, valueHeight))
            y += max(22, valueHeight + 6)
        }

        y += 10
        var x = padding
        for i in 0..<activeActionCount {
            let button = actionPool[i]
            let size = button.fittingSize
            let widthValue = min(usable, max(76, size.width + 16))
            button.frame = NSRect(x: x, y: y, width: widthValue, height: 28)
            x += widthValue + 6
            if x > padding + usable - 70 {
                x = padding
                y += 34
            }
        }
        y += 40
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y))
    }

    private func measure(_ text: String, width: CGFloat, font: NSFont, maxLines: Int) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = font.ascender - font.descender + font.leading
        return min(CGFloat(maxLines) * lineHeight + 2, ceil(rect.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.hairline.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.5, y: 0))
        path.line(to: NSPoint(x: 0.5, y: bounds.height))
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func closePressed() { onClose?() }
}
