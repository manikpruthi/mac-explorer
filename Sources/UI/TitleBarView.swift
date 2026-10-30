import AppKit

struct TabDisplay {
    let title: String
    let icon: String
}

@MainActor
protocol TitleBarDelegate: AnyObject {
    func titleBarActivateTab(_ index: Int)
    func titleBarCloseTab(_ index: Int)
    func titleBarNewTab()
    func titleBarDetachTab(_ index: Int)
    func titleBarMoveTab(_ from: Int, _ to: Int)
    func titleBarShowMenu(_ index: Int, event: NSEvent)
    func titleBarMinimize()
    func titleBarToggleMaximize()
    func titleBarCloseWindow()
    func titleBarReorderTab(_ from: Int, screenPoint: NSPoint)
}

@MainActor
final class TabItemView: ThemedView {
    var index: Int = 0
    var isSelected = false {
        didSet { needsDisplay = true; updateCloseVisibility() }
    }
    var display = TabDisplay(title: "", icon: "folder") {
        didSet { updateContent() }
    }

    var onActivate: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMenu: ((Int, NSEvent) -> Void)?
    var onDragComplete: ((Int, NSPoint) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = makeLabel("", size: 12.5)
    private let closeButton = HoverButton()
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var dragOrigin: NSPoint?
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(closeButton)

        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.lineBreakMode = .byTruncatingTail
        closeButton.image = Icons.symbol("xmark", size: 9, weight: .semibold)
        closeButton.image?.isTemplate = true
        closeButton.contentTintColor = Theme.textSecondary
        closeButton.cornerRadius = 10
        closeButton.hoverColor = Theme.active
        closeButton.pressedColor = Theme.active
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close tab"
        closeButton.setAccessibilityLabel("Close tab")
        updateContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateContent() {
        titleLabel.stringValue = display.title
        titleLabel.toolTip = display.title
        iconView.image = Icons.symbol(display.icon, size: 15)
        iconView.contentTintColor = isSelected ? Theme.accent : Theme.textSecondary
        needsDisplay = true
    }

    private func updateCloseVisibility() {
        closeButton.isHidden = false
        closeButton.alphaValue = isSelected || hovering ? 1 : 0
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
        needsDisplay = true
        updateCloseVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        updateCloseVisibility()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
        let closeSize: CGFloat = 20
        closeButton.frame = NSRect(x: bounds.width - closeSize - 5, y: (h - closeSize) / 2, width: closeSize, height: closeSize)
        titleLabel.frame = NSRect(x: 32, y: (h - 17) / 2, width: max(0, bounds.width - 32 - closeSize - 8), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor?
        if isSelected {
            color = Theme.tabActive
        } else if hovering {
            color = Theme.hover
        } else {
            color = nil
        }
        if let color {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + 10),
                         xRadius: 8, yRadius: 8).fill()
        }
        if isSelected {
            Theme.hairline.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 8, y: 0))
            path.line(to: NSPoint(x: 0, y: 8))
            path.line(to: NSPoint(x: 0, y: bounds.height))
            path.move(to: NSPoint(x: bounds.width - 8, y: 0))
            path.line(to: NSPoint(x: bounds.width, y: 8))
            path.line(to: NSPoint(x: bounds.width, y: bounds.height))
            path.move(to: NSPoint(x: 8, y: 0.5))
            path.line(to: NSPoint(x: bounds.width - 8, y: 0.5))
            path.lineWidth = 1
            path.stroke()
        } else {
            Theme.hairline.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.width - 0.5, y: 9))
            path.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height - 8))
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            onActivate?(index)
        }
        dragOrigin = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = NSEvent.mouseLocation
        if !dragging && hypot(current.x - origin.x, current.y - origin.y) > 6 {
            dragging = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil; dragging = false }
        guard dragging else { return }
        onDragComplete?(index, NSEvent.mouseLocation)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onClose?(index)
        } else {
            super.otherMouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(index, event)
    }

    @objc private func closePressed() {
        onClose?(index)
    }
}

@MainActor
final class TitleBarView: ThemedView, TitleBarDelegate {
    weak var delegate: TitleBarDelegate?

    private var tabs: [TabItemView] = []
    private var plusButton: HoverButton!
    private var dragSpace: DraggableTitleView!
    private var minimizeButton: WindowControlButton!
    private var maximizeButton: WindowControlButton!
    private var closeButton: WindowControlButton!
    private var tabList: [TabDisplay] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.chrome

        plusButton = HoverButton(title: "", image: "plus", target: self, action: #selector(newTabPressed))
        plusButton.cornerRadius = 4
        plusButton.imagePosition = .imageOnly
        plusButton.toolTip = "New tab (⌘T)"
        addSubview(plusButton)

        dragSpace = DraggableTitleView()
        dragSpace.onDoubleClick = { [weak self] in self?.delegate?.titleBarToggleMaximize() }
        addSubview(dragSpace)

        minimizeButton = WindowControlButton(kind: .minimize, target: self, action: #selector(minimizePressed))
        maximizeButton = WindowControlButton(kind: .maximize, target: self, action: #selector(maximizePressed))
        closeButton = WindowControlButton(kind: .close, target: self, action: #selector(closePressed))
        addSubview(minimizeButton)
        addSubview(maximizeButton)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(tabs displays: [TabDisplay], activeIndex: Int, maximized: Bool) {
        tabList = displays
        if tabs.count != displays.count {
            tabs.forEach { $0.removeFromSuperview() }
            tabs = displays.enumerated().map { index, _ in
                let tab = TabItemView()
                tab.onActivate = { [weak self] i in self?.delegate?.titleBarActivateTab(i) }
                tab.onClose = { [weak self] i in self?.delegate?.titleBarCloseTab(i) }
                tab.onMenu = { [weak self] i, event in self?.delegate?.titleBarShowMenu(i, event: event) }
                tab.onDragComplete = { [weak self] i, point in
                    guard let self else { return }
                    if let window, !window.frame.contains(point) {
                        self.delegate?.titleBarDetachTab(i)
                    } else {
                        self.delegate?.titleBarReorderTab(i, screenPoint: point)
                    }
                }
                addSubview(tab)
                return tab
            }
        }
        for (index, tab) in tabs.enumerated() {
            tab.index = index
            tab.display = displays[index]
            tab.isSelected = index == activeIndex
        }
        maxButtonSetRestore(maximized)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func updateMaximized(_ maximized: Bool) {
        maxButtonSetRestore(maximized)
    }

    func tabIndex(atScreenPoint point: NSPoint) -> Int {
        guard let window else { return 0 }
        let windowPoint = window.convertPoint(fromScreen: point)
        let local = convert(windowPoint, from: nil)
        for (index, tab) in tabs.enumerated() {
            if local.x >= tab.frame.minX && local.x <= tab.frame.maxX { return index }
        }
        guard let first = tabs.first else { return 0 }
        return local.x < first.frame.midX ? 0 : max(0, tabs.count - 1)
    }

    private func maxButtonSetRestore(_ restore: Bool) {
        maximizeButton.setRestore(restore)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let controlsWidth: CGFloat = 46 * 3
        let available = max(0, bounds.width - controlsWidth - 8)
        var x: CGFloat = 8
        let count = max(1, tabs.count)
        let spacing: CGFloat = 2
        let totalSpacing = CGFloat(max(0, count - 1)) * spacing
        let perTab = min(230, max(112, (available - 28 - totalSpacing) / CGFloat(count)))
        let tabHeight: CGFloat = 33
        for tab in tabs {
            tab.frame = NSRect(x: x, y: height - tabHeight, width: perTab, height: tabHeight)
            x += perTab + spacing
        }
        plusButton.frame = NSRect(x: x + 2, y: height - 28, width: 28, height: 28)
        let dragX = plusButton.frame.maxX + 4
        dragSpace.frame = NSRect(x: dragX, y: 0, width: max(0, bounds.width - controlsWidth - dragX), height: height)
        minimizeButton.frame = NSRect(x: bounds.width - controlsWidth, y: 0, width: 46, height: height)
        maximizeButton.frame = NSRect(x: bounds.width - controlsWidth + 46, y: 0, width: 46, height: height)
        closeButton.frame = NSRect(x: bounds.width - 46, y: 0, width: 46, height: height)
    }

    @objc private func newTabPressed() {
        delegate?.titleBarNewTab()
    }

    @objc private func minimizePressed() {
        delegate?.titleBarMinimize()
    }

    @objc private func maximizePressed() {
        delegate?.titleBarToggleMaximize()
    }

    @objc private func closePressed() {
        delegate?.titleBarCloseWindow()
    }

    // MARK: - TitleBarDelegate forwarding

    func titleBarActivateTab(_ index: Int) { delegate?.titleBarActivateTab(index) }
    func titleBarCloseTab(_ index: Int) { delegate?.titleBarCloseTab(index) }
    func titleBarNewTab() { delegate?.titleBarNewTab() }
    func titleBarDetachTab(_ index: Int) { delegate?.titleBarDetachTab(index) }
    func titleBarMoveTab(_ from: Int, _ to: Int) { delegate?.titleBarMoveTab(from, to) }
    func titleBarShowMenu(_ index: Int, event: NSEvent) { delegate?.titleBarShowMenu(index, event: event) }
    func titleBarMinimize() { delegate?.titleBarMinimize() }
    func titleBarToggleMaximize() { delegate?.titleBarToggleMaximize() }
    func titleBarCloseWindow() { delegate?.titleBarCloseWindow() }
    func titleBarReorderTab(_ from: Int, screenPoint: NSPoint) { delegate?.titleBarReorderTab(from, screenPoint: screenPoint) }
}
