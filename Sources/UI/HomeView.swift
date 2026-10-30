import AppKit

struct QuickItem {
    let path: String
    let label: String
}

@MainActor
final class HomeView: ThemedView {
    var onOpenFolder: ((String) -> Void)?
    var onOpenRecent: ((RecentItem) -> Void)?
    var onClearRecent: (() -> Void)?
    var onOpenGallery: (() -> Void)?
    var onQuickMenu: ((QuickItem, NSEvent) -> Void)?
    var onRecentMenu: ((RecentItem, NSEvent) -> Void)?
    var onOpenVolume: ((Volume) -> Void)?
    var onVolumeMenu: ((Volume, NSEvent) -> Void)?

    private let scroll = makeScroller()
    private let content = FlippedView()
    private var quickItems: [QuickItem] = []
    private var recent: [RecentItem] = []
    private var volumes: [Volume] = []
    private var cardViews: [QuickCardView] = []
    private var recentRows: [RecentRowView] = []
    private var volumeCards: [VolumeCardView] = []
    private let quickTitle = makeLabel("Quick access", size: 15, weight: .semibold)
    private let devicesTitle = makeLabel("Devices and drives", size: 15, weight: .semibold)
    private let recentTitle = makeLabel("Recent", size: 15, weight: .semibold)
    private let galleryButton = HoverButton(title: "Open Gallery")
    private let clearButton = HoverButton(title: "Clear recent files")
    private let quickEmpty = makeLabel("Pin folders from the navigation pane to see them here.", size: 12.5, color: Theme.textSecondary)
    private let recentCard = ThemedView()
    private let recentEmpty = makeLabel("Files you open from Mac Explorer will show up here.", size: 12.5, color: Theme.textSecondary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.content
        scroll.documentView = content
        addSubview(scroll)
        content.addSubview(quickTitle)
        content.addSubview(devicesTitle)
        content.addSubview(recentTitle)
        for button in [galleryButton, clearButton] {
            button.font = NSFont.systemFont(ofSize: 12)
            button.contentTintColor = Theme.accent
            button.imagePosition = .noImage
            content.addSubview(button)
        }
        galleryButton.target = self
        galleryButton.action = #selector(openGallery)
        clearButton.target = self
        clearButton.action = #selector(clearRecent)
        content.addSubview(quickEmpty)
        recentCard.fillColor = Theme.surface
        recentCard.strokeColor = Theme.hairline
        recentCard.borderWidth = 1
        recentCard.cornerRadius = 8
        content.addSubview(recentCard)
        content.addSubview(recentEmpty)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(quickItems: [QuickItem], recent: [RecentItem], volumes: [Volume]) {
        self.quickItems = quickItems
        self.recent = recent
        self.volumes = volumes
        rebuild()
        needsLayout = true
    }

    private func rebuild() {
        cardViews.forEach { $0.removeFromSuperview() }
        recentRows.forEach { $0.removeFromSuperview() }
        volumeCards.forEach { $0.removeFromSuperview() }
        cardViews = quickItems.map { item in
            let card = QuickCardView(item: item)
            card.onOpen = { [weak self] in self?.onOpenFolder?(item.path) }
            card.onMenu = { [weak self] event in self?.onQuickMenu?(item, event) }
            content.addSubview(card)
            return card
        }
        volumeCards = volumes.map { volume in
            let card = VolumeCardView(volume: volume)
            card.onOpen = { [weak self] in self?.onOpenVolume?(volume) }
            card.onMenu = { [weak self] event in self?.onVolumeMenu?(volume, event) }
            content.addSubview(card)
            return card
        }
        recentRows = recent.map { item in
            let row = RecentRowView(item: item)
            row.onOpen = { [weak self] in self?.onOpenRecent?(item) }
            row.onMenu = { [weak self] event in self?.onRecentMenu?(item, event) }
            recentCard.addSubview(row)
            return row
        }
        devicesTitle.isHidden = volumes.isEmpty
        quickEmpty.isHidden = !quickItems.isEmpty
        recentEmpty.isHidden = !recent.isEmpty
        clearButton.isHidden = recent.isEmpty
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutContent()
    }

    private func layoutContent() {
        let width = max(600, scroll.contentSize.width)
        let padding: CGFloat = 28
        let usable = width - padding * 2
        var y: CGFloat = 22
        quickTitle.frame = NSRect(x: padding, y: y, width: usable, height: 20)
        y += 32

        if !quickItems.isEmpty {
            let cardMin: CGFloat = 210
            let gap: CGFloat = 6
            let columns = max(1, Int((usable + gap) / (cardMin + gap)))
            let cardWidth = (usable - CGFloat(columns - 1) * gap) / CGFloat(columns)
            for (index, card) in cardViews.enumerated() {
                let column = index % columns
                let row = index / columns
                card.frame = NSRect(
                    x: padding + CGFloat(column) * (cardWidth + gap),
                    y: y + CGFloat(row) * (52 + gap),
                    width: cardWidth,
                    height: 52
                )
            }
            let rows = (cardViews.count + columns - 1) / columns
            y += CGFloat(rows) * (52 + gap) + 8
        } else {
            quickEmpty.frame = NSRect(x: padding + 4, y: y + 4, width: usable, height: 18)
            y += 40
        }

        if !volumes.isEmpty {
            y += 18
            devicesTitle.frame = NSRect(x: padding, y: y, width: 240, height: 20)
            y += 32
            let cardMin: CGFloat = 300
            let gap: CGFloat = 8
            let columns = max(1, Int((usable + gap) / (cardMin + gap)))
            let cardWidth = (usable - CGFloat(columns - 1) * gap) / CGFloat(columns)
            for (index, card) in volumeCards.enumerated() {
                let column = index % columns
                let row = index / columns
                card.frame = NSRect(
                    x: padding + CGFloat(column) * (cardWidth + gap),
                    y: y + CGFloat(row) * (92 + gap),
                    width: cardWidth,
                    height: 92
                )
            }
            let rows = (volumeCards.count + columns - 1) / columns
            y += CGFloat(rows) * (92 + gap) + 8
        }

        y += 18
        recentTitle.frame = NSRect(x: padding, y: y, width: 140, height: 20)
        let clearWidth = clearButton.fittingSize.width + 12
        let galleryWidth = galleryButton.fittingSize.width + 12
        galleryButton.frame = NSRect(x: width - padding - galleryWidth - (recent.isEmpty ? 0 : 8) - (recent.isEmpty ? 0 : clearWidth), y: y - 2, width: galleryWidth, height: 24)
        clearButton.frame = NSRect(x: width - padding - clearWidth, y: y - 2, width: clearWidth, height: 24)
        y += 32

        if recent.isEmpty {
            recentCard.frame = NSRect(x: padding, y: y, width: usable, height: 44)
            recentEmpty.frame = NSRect(x: padding + 14, y: y + 13, width: usable - 28, height: 18)
            y += 62
        } else {
            let cardHeight = CGFloat(recent.count) * 34 + 10
            recentCard.frame = NSRect(x: padding, y: y, width: usable, height: cardHeight)
            for (index, row) in recentRows.enumerated() {
                row.frame = NSRect(x: 6, y: 5 + CGFloat(index) * 34, width: usable - 12, height: 34)
            }
            y += cardHeight + 10
        }

        content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y + 24))
    }

    @objc private func openGallery() { onOpenGallery?() }
    @objc private func clearRecent() { onClearRecent?() }
}

@MainActor
private final class StorageBarView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Theme.hairline.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let usable = min(max(fraction, 0), 1)
        guard usable > 0 else { return }
        let width = max(bounds.height, bounds.width * usable)
        let fill = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let color = usable >= 0.9 ? Theme.danger : Theme.accent
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}

@MainActor
private final class VolumeCardView: HoverView {
    private let volume: Volume
    private let icon = NSImageView()
    private let name = makeLabel("", size: 13, weight: .semibold)
    private let detail = makeLabel("", size: 11.5, color: Theme.textSecondary)
    private let percent = makeLabel("", size: 11, color: Theme.textSecondary)
    private let bar = StorageBarView()
    var onOpen: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(volume: Volume) {
        self.volume = volume
        super.init(frame: .zero)
        fillColor = Theme.surface
        strokeColor = Theme.hairline
        borderWidth = 1
        cornerRadius = 8
        icon.image = Icons.symbol("internaldrive", size: 30)
        icon.contentTintColor = Theme.textSecondary
        icon.imageScaling = .scaleProportionallyDown
        name.stringValue = volume.name
        name.lineBreakMode = .byTruncatingTail
        if volume.total > 0 {
            detail.stringValue = "\(FormatTools.bytes(volume.free)) free of \(FormatTools.bytes(volume.total))"
            let used = max(0, volume.total - volume.free)
            let fraction = Double(used) / Double(volume.total)
            bar.fraction = fraction
            percent.stringValue = "\(Int((fraction * 100).rounded()))% used"
        } else {
            detail.stringValue = "Storage information unavailable"
            percent.stringValue = ""
        }
        percent.alignment = .right
        toolTip = volume.path
        [icon, name, detail, percent, bar].forEach { addSubview($0) }
        onTap = { [weak self] in self?.onOpen?() }
        onRightClick = { [weak self] event in self?.onMenu?(event) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: 16, width: 30, height: 30)
        name.frame = NSRect(x: 54, y: 14, width: max(0, bounds.width - 54 - 104), height: 18)
        percent.frame = NSRect(x: bounds.width - 104, y: 15, width: 90, height: 16)
        detail.frame = NSRect(x: 54, y: 34, width: max(0, bounds.width - 68), height: 16)
        bar.frame = NSRect(x: 14, y: 70, width: max(0, bounds.width - 28), height: 8)
    }
}

@MainActor
private final class QuickCardView: HoverView {
    private let icon = NSImageView()
    private let name = makeLabel("", size: 13)
    private let sub = makeLabel("Pinned folder", size: 11.5, color: Theme.textSecondary)
    private let item: QuickItem
    var onOpen: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(item: QuickItem) {
        self.item = item
        super.init(frame: .zero)
        cornerRadius = 4
        icon.image = IconService.shared.folderIcon(size: 28)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.stringValue = item.label
        name.lineBreakMode = .byTruncatingTail
        toolTip = item.path
        addSubview(icon)
        addSubview(name)
        addSubview(sub)
        onTap = { [weak self] in self?.onOpen?() }
        onRightClick = { [weak self] event in self?.onMenu?(event) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: (bounds.height - 28) / 2, width: 28, height: 28)
        name.frame = NSRect(x: 50, y: 11, width: max(0, bounds.width - 58), height: 16)
        sub.frame = NSRect(x: 50, y: 28, width: max(0, bounds.width - 58), height: 14)
    }
}

@MainActor
private final class RecentRowView: HoverView {
    private let icon = NSImageView()
    private let name = makeLabel("", size: 12.5)
    private let location = makeLabel("", size: 12, color: Theme.textSecondary)
    private let date = makeLabel("", size: 12, color: Theme.textSecondary)
    var onOpen: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(item: RecentItem) {
        super.init(frame: .zero)
        cornerRadius = 4
        icon.image = IconService.shared.genericIcon(kind: item.kind, size: 20)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.stringValue = item.name
        location.stringValue = item.parent
        date.stringValue = FormatTools.date(item.modified)
        date.alignment = .right
        toolTip = item.path
        [icon, name, location, date].forEach { addSubview($0) }
        onTap = { [weak self] in self?.onOpen?() }
        onRightClick = { [weak self] event in self?.onMenu?(event) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let dateWidth: CGFloat = 150
        let locationWidth = max(120, (bounds.width - 240) * 0.42)
        name.frame = NSRect(x: 36, y: (bounds.height - 16) / 2, width: max(80, bounds.width - 36 - locationWidth - dateWidth - 20), height: 16)
        location.frame = NSRect(x: bounds.width - dateWidth - locationWidth, y: (bounds.height - 16) / 2, width: locationWidth - 12, height: 16)
        date.frame = NSRect(x: bounds.width - dateWidth, y: (bounds.height - 16) / 2, width: dateWidth - 8, height: 16)
    }
}
