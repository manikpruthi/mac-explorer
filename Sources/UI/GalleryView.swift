import AppKit

@MainActor
final class GalleryView: ThemedView {
    var onOpen: ((FileEntry) -> Void)?
    var onContextMenu: ((FileEntry, NSEvent) -> Void)?

    private let scroll = makeScroller()
    private let content = FlippedView()
    private let titleLabel = makeLabel("Gallery", size: 15, weight: .semibold)
    private let countLabel = makeLabel("", size: 12, color: Theme.textSecondary)
    private let noteLabel = makeLabel("", size: 12, color: Theme.textSecondary)
    private var entries: [FileEntry] = []
    private var root: String = ""
    private var truncated = false
    private var loading = false
    private var errorMessage: String?
    private var cards: [GalleryCardView] = []
    private var yearLabels: [NSTextField] = []
    private var selectedPath: String?
    private let spinner = NSProgressIndicator()
    private let emptyLabel = makeLabel("No pictures yet", size: 14, weight: .semibold)
    private let emptySub = makeLabel("Images added to your Pictures folder will appear here.", size: 12.5, color: Theme.textSecondary)

    private var observingScroll = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.content
        scroll.documentView = content
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        content.addSubview(titleLabel)
        content.addSubview(countLabel)
        content.addSubview(noteLabel)
        spinner.style = .spinning
        spinner.controlSize = .small
        content.addSubview(spinner)
        content.addSubview(emptyLabel)
        content.addSubview(emptySub)
        emptyLabel.isHidden = true
        emptySub.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !observingScroll else { return }
        observingScroll = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
    }

    @objc private func boundsChanged() {
        loadVisibleThumbnails()
    }

    private func loadVisibleThumbnails() {
        let visible = scroll.documentVisibleRect
        for card in cards where card.frame.intersects(visible) {
            card.loadThumbnailIfNeeded()
        }
    }

    func update(root: String, entries: [FileEntry], truncated: Bool, loading: Bool, errorMessage: String?) {
        self.root = root
        self.entries = entries
        self.truncated = truncated
        self.loading = loading
        self.errorMessage = errorMessage
        rebuild()
        needsLayout = true
    }

    private func rebuild() {
        cards.forEach { $0.removeFromSuperview() }
        yearLabels.forEach { $0.removeFromSuperview() }
        cards = []
        yearLabels = []
        countLabel.stringValue = loading ? "Loading…" : "\(entries.count) item\(entries.count == 1 ? "" : "s")"
        noteLabel.stringValue = "Photos and images from \(root)\(truncated ? " · showing the most recent items" : "")"

        spinner.isHidden = !(loading && entries.isEmpty)
        if loading && entries.isEmpty { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        let showEmpty = !loading && errorMessage == nil && entries.isEmpty
        emptyLabel.isHidden = !showEmpty
        emptySub.isHidden = !showEmpty
        if showEmpty {
            emptyLabel.stringValue = "No pictures yet"
            emptySub.stringValue = "Images added to your Pictures folder will appear here."
        }

        guard errorMessage == nil else {
            emptyLabel.isHidden = false
            emptySub.isHidden = false
            emptyLabel.stringValue = "Gallery is unavailable"
            emptySub.stringValue = errorMessage ?? ""
            return
        }

        let groups = Dictionary(grouping: entries) { entry -> String in
            String(Calendar.current.component(.year, from: entry.modified))
        }
        let years = groups.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
        for year in years {
            let label = makeLabel(year, size: 22, weight: .semibold)
            content.addSubview(label)
            yearLabels.append(label)
            for entry in groups[year] ?? [] {
                let card = GalleryCardView(entry: entry)
                card.onOpen = { [weak self] in
                    self?.selectedPath = entry.path
                    self?.onOpen?(entry)
                }
                card.onSelect = { [weak self] in
                    self?.select(entry)
                }
                card.onMenu = { [weak self] event in
                    self?.select(entry)
                    self?.onContextMenu?(entry, event)
                }
                content.addSubview(card)
                cards.append(card)
            }
        }
    }

    private func select(_ entry: FileEntry) {
        selectedPath = entry.path
        for card in cards {
            card.isSelected = card.entry.path == entry.path
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutContent()
    }

    private func layoutContent() {
        let width = max(600, scroll.contentSize.width)
        let padding: CGFloat = 28
        var y: CGFloat = 22
        titleLabel.frame = NSRect(x: padding, y: y, width: 200, height: 20)
        countLabel.frame = NSRect(x: width - padding - 200, y: y + 2, width: 200, height: 16)
        countLabel.alignment = .right
        y += 26
        noteLabel.frame = NSRect(x: padding, y: y, width: width - padding * 2, height: 16)
        y += 22

        if !emptyLabel.isHidden {
            emptyLabel.frame = NSRect(x: padding, y: y + 40, width: width - padding * 2, height: 20)
            emptyLabel.alignment = .center
            emptySub.frame = NSRect(x: padding, y: y + 66, width: width - padding * 2, height: 18)
            emptySub.alignment = .center
            spinner.frame = NSRect(x: width / 2 - 8, y: y + 40, width: 16, height: 16)
            content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y + 140))
            return
        }
        if !spinner.isHidden {
            spinner.frame = NSRect(x: padding, y: y + 8, width: 16, height: 16)
            y += 36
        }

        let usable = width - padding * 2
        let cardWidth: CGFloat = 168
        let gap: CGFloat = 12
        let columns = max(1, Int((usable + gap) / (cardWidth + gap)))
        var index = 0
        let groups = Dictionary(grouping: cards) { card -> String in
            String(Calendar.current.component(.year, from: card.entry.modified))
        }
        let years = groups.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
        var labelIndex = 0
        for year in years {
            guard labelIndex < yearLabels.count else { break }
            yearLabels[labelIndex].frame = NSRect(x: padding, y: y, width: usable, height: 30)
            labelIndex += 1
            y += 38
            let cardsForYear = groups[year] ?? []
            for (cardIndex, card) in cardsForYear.enumerated() {
                let column = cardIndex % columns
                let row = cardIndex / columns
                card.frame = NSRect(
                    x: padding + CGFloat(column) * (cardWidth + gap),
                    y: y + CGFloat(row) * (cardWidth + 34),
                    width: cardWidth,
                    height: cardWidth + 24
                )
                index += 1
            }
            let rows = (cardsForYear.count + columns - 1) / columns
            y += CGFloat(rows) * (cardWidth + 34) + 18
        }
        _ = index
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y + 24))
        loadVisibleThumbnails()
    }
}

@MainActor
private final class CoverImageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.resolved(Theme.surface, for: effectiveAppearance).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

@MainActor
private final class GalleryCardView: HoverView {
    let entry: FileEntry
    private let thumb = CoverImageView()
    private let caption = makeLabel("", size: 12)
    private let fallback = NSImageView()
    private var loaded = false
    var onOpen: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(entry: FileEntry) {
        self.entry = entry
        super.init(frame: .zero)
        cornerRadius = 6
        selectedColor = Theme.selection
        fallback.image = IconService.shared.genericIcon(kind: .image, size: 44)
        fallback.isHidden = true
        caption.stringValue = entry.name
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        toolTip = entry.name
        addSubview(thumb)
        addSubview(fallback)
        addSubview(caption)
        onTap = { [weak self] in self?.onSelect?() }
        onClickWithEvent = { [weak self] event in
            if event.clickCount == 2 { self?.onOpen?() }
            else { self?.onSelect?() }
        }
        onRightClick = { [weak self] event in self?.onMenu?(event) }

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadThumbnailIfNeeded() {
        guard !loaded else { return }
        loaded = true
        IconService.shared.thumbnail(for: entry, size: 320) { [weak self] image in
            guard let self else { return }
            if let image {
                self.thumb.image = image
                self.needsLayout = true
            } else {
                self.fallback.isHidden = false
            }
        }
    }

    override func layout() {
        super.layout()
        thumb.frame = NSRect(x: 4, y: 4, width: bounds.width - 8, height: bounds.width - 8)
        fallback.frame = NSRect(x: (bounds.width - 44) / 2, y: (bounds.width - 44) / 2, width: 44, height: 44)
        caption.frame = NSRect(x: 4, y: bounds.width - 2, width: bounds.width - 8, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            Theme.selectionBorder.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            path.lineWidth = 1
            path.stroke()
        }
    }
}
