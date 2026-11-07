import AppKit

@MainActor
enum Theme {
    static let accent = NSColor(srgbRed: 0x00 / 255, green: 0x67 / 255, blue: 0xC0 / 255, alpha: 1)
    static let accentHover = NSColor(srgbRed: 0x00 / 255, green: 0x78 / 255, blue: 0xD4 / 255, alpha: 1)
    static let accentPressed = NSColor(srgbRed: 0x00 / 255, green: 0x5A / 255, blue: 0x9E / 255, alpha: 1)
    static let danger = NSColor(srgbRed: 0xC4 / 255, green: 0x2B / 255, blue: 0x1C / 255, alpha: 1)
    static let dangerHover = NSColor(srgbRed: 0xD1 / 255, green: 0x34 / 255, blue: 0x38 / 255, alpha: 1)

    static let chrome = dynamic(light: 0xF3F3F3, dark: 0x202020)
    static let surface = dynamic(light: 0xF9F9F9, dark: 0x272727)
    static let content = dynamic(light: 0xFFFFFF, dark: 0x191919)
    static let sidebar = dynamic(light: 0xF5F5F5, dark: 0x202020)
    static let field = dynamic(light: 0xFFFFFF, dark: 0x2D2D2D)
    static let menu = dynamic(light: 0xFBFBFB, dark: 0x2B2B2B)
    static let dialog = dynamic(light: 0xFBFBFB, dark: 0x292929)
    static let textPrimary = dynamic(light: 0x1B1B1B, dark: 0xF2F2F2)
    static let textSecondary = dynamic(light: 0x616161, dark: 0xC2C2C2)
    static let textTertiary = dynamic(light: 0x8A8A8A, dark: 0x9A9A9A)
    static let border = dynamic(light: 0xD6D6D6, dark: 0x3A3A3A)
    static let hairline = dynamic(light: 0xE6E6E6, dark: 0x333333)
    static let controlBorder = dynamic(light: 0xD0D0D0, dark: 0x4A4A4A)
    static let controlBackground = dynamic(light: 0xFDFDFD, dark: 0x2D2D2D)
    static let tabActive = dynamic(light: 0xFBFBFB, dark: 0x2B2B2B)

    static let hover = dynamicAlpha(light: (0, 0, 0, 0.045), dark: (1, 1, 1, 0.06))
    static let active = dynamicAlpha(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.09))
    static let selection = dynamicAlpha(light: (0, 103, 192, 0.14), dark: (0, 120, 212, 0.34))
    static let selectionStrong = dynamicAlpha(light: (0, 103, 192, 0.22), dark: (0, 120, 212, 0.42))
    static let selectionBorder = dynamicAlpha(light: (0, 103, 192, 0.45), dark: (76, 166, 255, 0.55))
    /// Folder under the pointer during a drag: stronger than selection, with an accent ring.
    static let dropTarget = dynamicAlpha(light: (0, 103, 192, 0.24), dark: (0, 120, 212, 0.5))

    static func drawDropTarget(in rect: NSRect, radius: CGFloat) {
        dropTarget.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        accent.setStroke()
        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        ring.lineWidth = 1.5
        ring.stroke()
    }

    static let font = NSFont.systemFont(ofSize: 13)
    static let smallFont = NSFont.systemFont(ofSize: 12)
    static let tinyFont = NSFont.systemFont(ofSize: 11.5)
    static let semiboldFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let headlineFont = NSFont.systemFont(ofSize: 19, weight: .semibold)

    static func dynamic(light: Int, dark: Int) -> NSColor {
        dynamicAlpha(
            light: (CGFloat((light >> 16) & 0xFF) / 255, CGFloat((light >> 8) & 0xFF) / 255, CGFloat(light & 0xFF) / 255, 1),
            dark: (CGFloat((dark >> 16) & 0xFF) / 255, CGFloat((dark >> 8) & 0xFF) / 255, CGFloat(dark & 0xFF) / 255, 1)
        )
    }

    static func dynamicAlpha(
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: value.3)
        }
    }

    static func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    static func resolved(_ color: NSColor, for view: NSView) -> NSColor {
        resolved(color, for: view.effectiveAppearance)
    }

    static func apply(_ preference: ThemePreference) {
        switch preference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

class ThemedView: NSView {
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var strokeColor: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }

    nonisolated override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        if let fillColor {
            Theme.resolved(fillColor, for: effectiveAppearance).setFill()
            path.fill()
        }
        if let strokeColor, borderWidth > 0 {
            Theme.resolved(strokeColor, for: effectiveAppearance).setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
        _ = context
    }
}

class HoverView: ThemedView {
    var hoverColor: NSColor? = Theme.hover
    var activeColor: NSColor? = Theme.active
    var selectedColor: NSColor?
    var isSelected = false { didSet { needsDisplay = true } }
    var onTap: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onClickWithEvent: ((NSEvent) -> Void)?

    private var tracking: NSTrackingArea?
    private var hovering = false

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
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(event)
            return
        }
        onClickWithEvent?(event)
        if onClickWithEvent == nil { onTap?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor?
        if isSelected {
            color = selectedColor ?? Theme.selection
        } else if hovering {
            color = hoverColor
        } else {
            color = fillColor
        }
        guard let color else { return }
        Theme.resolved(color, for: effectiveAppearance).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        if let strokeColor, borderWidth > 0 {
            Theme.resolved(strokeColor, for: effectiveAppearance).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                    xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = borderWidth
            path.stroke()
        }
    }
}

final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}

final class DraggableTitleView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.performDrag(with: event)
    }
}

@MainActor
enum Icons {
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    static func imageButton(_ name: String, size: CGFloat, accessibility: String) -> NSImage? {
        let image = symbol(name, size: size)
        image?.isTemplate = true
        image?.accessibilityDescription = accessibility
        return image
    }
}
