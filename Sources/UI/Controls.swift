import AppKit

@MainActor
final class ClosureTarget: NSObject {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
        super.init()
    }

    @objc func fire(_ sender: Any?) {
        closure()
    }
}

@MainActor
func makeMenuItem(
    _ title: String,
    icon: String? = nil,
    key: String? = nil,
    modifiers: NSEvent.ModifierFlags = .command,
    checked: Bool = false,
    enabled: Bool = true,
    action: @escaping () -> Void
) -> NSMenuItem {
    let target = ClosureTarget(action)
    let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire(_:)), keyEquivalent: key ?? "")
    item.target = target
    item.representedObject = target
    if let key {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
    }
    item.state = checked ? .on : .off
    item.isEnabled = enabled
    if let icon, let image = Icons.symbol(icon, size: 13) {
        image.isTemplate = true
        item.image = image
    }
    return item
}

@MainActor
func makeSeparator() -> NSMenuItem {
    NSMenuItem.separator()
}

@MainActor
func makeLabel(
    _ text: String = "",
    size: CGFloat = 13,
    weight: NSFont.Weight = .regular,
    color: NSColor = Theme.textPrimary,
    lines: Int = 1
) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = NSFont.systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
    field.maximumNumberOfLines = lines
    field.cell?.truncatesLastVisibleLine = lines == 1
    field.isEditable = false
    field.isSelectable = false
    field.isBordered = false
    field.drawsBackground = false
    return field
}

@MainActor
class HoverButton: NSButton {
    var hoverColor: NSColor? = Theme.hover
    var pressedColor: NSColor? = Theme.active
    var activeColor: NSColor?
    var isActive = false {
        didSet { updateBackground() }
    }
    var cornerRadius: CGFloat = 4 {
        didSet {
            layer?.cornerRadius = cornerRadius
            needsDisplay = true
        }
    }
    var allowsKeyboardFocus = false
    var isDropTarget = false {
        didSet { updateBackground() }
    }

    override var acceptsFirstResponder: Bool { allowsKeyboardFocus }

    override var title: String {
        didSet {
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
    }

    private var tracking: NSTrackingArea?
    private var hovering = false
    private var pressing = false

    init(title: String = "", image: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        configure()
        self.title = title
        if let image, let symbol = Icons.symbol(image, size: 15) {
            symbol.isTemplate = true
            self.image = symbol
        }
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        image = nil
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        title = ""
        image = nil
        configure()
    }

    private func configure() {
        setButtonType(.momentaryChange)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        font = Theme.smallFont
        contentTintColor = Theme.textPrimary
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
        focusRingType = .none
        showsBorderOnlyWhileMouseInside = false
        refusesFirstResponder = true
        if let buttonCell = cell as? NSButtonCell {
            buttonCell.isBordered = false
            buttonCell.bezelStyle = .inline
            buttonCell.highlightsBy = []
            buttonCell.showsStateBy = []
            buttonCell.imageScaling = .scaleProportionallyDown
        }
    }

    override var isFlipped: Bool { true }

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
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressing = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        updateBackground()
        super.mouseDown(with: event)
        pressing = false
        updateBackground()
    }

    var currentBackgroundColor: NSColor? {
        if !isEnabled { return nil }
        if isDropTarget { return Theme.selection }
        if pressing { return pressedColor }
        if hovering { return hoverColor }
        if isActive { return activeColor ?? Theme.selection }
        return nil
    }

    func updateBackground() {
        let color = currentBackgroundColor
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = color.map { Theme.resolved($0, for: effectiveAppearance).cgColor }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
}

@MainActor
final class IconButton: HoverButton {
    init(image: String, accessibility: String, target: AnyObject? = nil, action: Selector? = nil, size: CGFloat = 17) {
        super.init(title: "", image: nil, target: target, action: action)
        if let symbol = Icons.symbol(image, size: size) {
            symbol.isTemplate = true
            self.image = symbol
        }
        self.setAccessibilityLabel(accessibility)
        self.toolTip = accessibility
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

@MainActor
final class WindowControlButton: HoverButton {
    enum Kind {
        case minimize
        case maximize
        case close
    }

    let kind: Kind
    private var restoreMode = false

    init(kind: Kind, target: AnyObject?, action: Selector) {
        self.kind = kind
        super.init(title: "", image: nil, target: target, action: action)
        cornerRadius = 0
        hoverColor = kind == .close ? Theme.danger : Theme.hover
        updateImage()
        switch kind {
        case .minimize: toolTip = "Minimize"
        case .maximize: toolTip = "Maximize"
        case .close: toolTip = "Close"
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRestore(_ restore: Bool) {
        restoreMode = restore
        updateImage()
    }

    private func updateImage() {
        let name: String
        switch kind {
        case .minimize: name = "minus"
        case .maximize: name = restoreMode ? "square.on.square" : "square"
        case .close: name = "xmark"
        }
        if let symbol = Icons.symbol(name, size: 10, weight: .medium) {
            symbol.isTemplate = true
            image = symbol
        }
        if kind == .maximize {
            toolTip = restoreMode ? "Restore" : "Maximize"
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if kind == .close {
            contentTintColor = .white
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if kind == .close {
            contentTintColor = Theme.textPrimary
        }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if kind == .close {
            contentTintColor = .white
        }
        super.mouseDown(with: event)
    }

    override func updateBackground() {
        super.updateBackground()
        if kind != .close {
            contentTintColor = Theme.textPrimary
        }
    }
}

@MainActor
final class BreadcrumbButton: HoverButton {
    init(title: String, icon: String? = nil, isCurrent: Bool, action: @escaping () -> Void) {
        super.init(title: title, image: nil, target: nil, action: nil)
        font = NSFont.systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .regular)
        if let icon, let symbol = Icons.symbol(icon, size: 13) {
            symbol.isTemplate = true
            image = symbol
            imagePosition = .imageLeading
        }
        self.target = self
        self.action = #selector(fireAction)
        self.closure = action
        toolTip = title
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        registerForDraggedTypes([FileListView.dragType, .fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var closure: (() -> Void)?

    var desiredWidth: CGFloat {
        let font = self.font ?? NSFont.systemFont(ofSize: 12.5)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let iconWidth: CGFloat = image == nil ? 0 : 19
        return min(190, ceil(textWidth + iconWidth + 14))
    }

    var dropPath: String?
    var onDrop: (([String], String, Bool) -> Void)?

    private func acceptable(_ info: NSDraggingInfo) -> Bool {
        guard dropPath != nil else { return false }
        let types = info.draggingPasteboard.types ?? []
        return types.contains(FileListView.dragType) || types.contains(.fileURL)
    }

    private func dragOperation(for info: NSDraggingInfo) -> NSDragOperation {
        let internalDrag = info.draggingPasteboard.types?.contains(FileListView.dragType) ?? false
        return internalDrag && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptable(sender) else { return [] }
        isDropTarget = true
        return dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptable(sender) else { return [] }
        return dragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptable(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { isDropTarget = false }
        guard let destination = dropPath, acceptable(sender) else { return false }
        let pasteboard = sender.draggingPasteboard
        var paths: [String] = []
        if let json = pasteboard.string(forType: FileListView.dragType),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            paths = decoded
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            paths = urls.filter { $0.isFileURL }.map { $0.path }
        }
        guard !paths.isEmpty else { return false }
        let internalDrag = pasteboard.types?.contains(FileListView.dragType) ?? false
        let copy = internalDrag ? NSEvent.modifierFlags.contains(.option) : true
        onDrop?(paths, destination, copy)
        return true
    }

    @objc private func fireAction() {
        closure?()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: desiredWidth, height: 24)
    }
}

@MainActor
final class FlatTextField: NSTextField {
    init(placeholder: String = "") {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        font = NSFont.systemFont(ofSize: 12.5)
        textColor = Theme.textPrimary
        placeholderString = placeholder
        focusRingType = .none
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.truncatesLastVisibleLine = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class SurfaceTextField: NSTextField {
    init(placeholder: String = "") {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        font = NSFont.systemFont(ofSize: 12.5)
        textColor = Theme.textPrimary
        placeholderString = placeholder
        focusRingType = .none
        cell?.isScrollable = true
        cell?.wraps = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
func addFilling(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
    ])
}

@MainActor
func addSeparatorLine(in parent: NSView, top: Bool) -> NSView {
    let line = ThemedView()
    line.fillColor = Theme.hairline
    line.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(line)
    NSLayoutConstraint.activate([
        line.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        line.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        line.heightAnchor.constraint(equalToConstant: 1),
        top ? line.topAnchor.constraint(equalTo: parent.topAnchor) : line.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
    return line
}

@MainActor
func makeScroller() -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.scrollerStyle = .overlay
    return scroll
}
