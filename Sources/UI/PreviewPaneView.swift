import AppKit
import QuickLookUI

/// Windows-style preview pane. The Quick Look view is only created while the pane is open and is
/// closed (releasing its renderer) when the pane goes away or the selection can't be previewed.
@MainActor
final class PreviewPaneView: ThemedView {
    var onClose: (() -> Void)?

    private let headLabel = makeLabel("Preview", size: 12, weight: .semibold, color: Theme.textSecondary)
    private let closeButton = HoverButton(title: "", image: "xmark")
    private let placeholderIcon = NSImageView()
    private let placeholderLabel = makeLabel("", size: 12.5, color: Theme.textSecondary, lines: 4)
    private var quickLookView: QLPreviewView?
    private var shownPath: String?
    private var pendingWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.content
        closeButton.imagePosition = .imageOnly
        closeButton.cornerRadius = 3
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.toolTip = "Close preview pane"
        placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
        placeholderLabel.alignment = .center
        [headLabel, closeButton, placeholderIcon, placeholderLabel].forEach { addSubview($0) }
        showPlaceholder("Select a file to preview its contents.", icon: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Releases the Quick Look renderer. Call before removing the pane.
    func tearDown() {
        pendingWork?.cancel()
        pendingWork = nil
        releaseQuickLook()
    }

    func update(entries: [FileEntry]) {
        pendingWork?.cancel()
        guard entries.count == 1, let entry = entries.first else {
            shownPath = nil
            releaseQuickLook()
            showPlaceholder(
                entries.isEmpty ? "Select a file to preview its contents." : "\(entries.count) items selected.",
                icon: nil
            )
            return
        }
        guard entry.path != shownPath else { return }
        shownPath = entry.path
        if entry.isDirectory && entry.kind != .app {
            releaseQuickLook()
            showPlaceholder(entry.name, icon: IconService.shared.fileIcon(for: entry, size: 96))
            return
        }
        // Debounce so arrowing through a folder doesn't spin up a renderer for every row.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shownPath == entry.path else { return }
            self.showQuickLook(entry)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func showQuickLook(_ entry: FileEntry) {
        let view: QLPreviewView
        if let quickLookView {
            view = quickLookView
        } else {
            guard let created = QLPreviewView(frame: previewFrame(), style: .normal) else {
                showPlaceholder("No preview available.", icon: IconService.shared.fileIcon(for: entry, size: 96))
                return
            }
            created.autostarts = true
            created.shouldCloseWithWindow = true
            addSubview(created)
            quickLookView = created
            view = created
        }
        placeholderIcon.isHidden = true
        placeholderLabel.isHidden = true
        view.isHidden = false
        view.previewItem = URL(fileURLWithPath: entry.path) as NSURL
    }

    private func releaseQuickLook() {
        guard let quickLookView else { return }
        quickLookView.previewItem = nil
        quickLookView.close()
        quickLookView.removeFromSuperview()
        self.quickLookView = nil
    }

    private func showPlaceholder(_ text: String, icon: NSImage?) {
        quickLookView?.isHidden = true
        placeholderIcon.image = icon
        placeholderIcon.isHidden = icon == nil
        placeholderLabel.stringValue = text
        placeholderLabel.isHidden = false
        needsLayout = true
    }

    private func previewFrame() -> NSRect {
        NSRect(x: 8, y: 40, width: max(0, bounds.width - 16), height: max(0, bounds.height - 48))
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 16
        headLabel.frame = NSRect(x: padding, y: 14, width: bounds.width - 70, height: 16)
        closeButton.frame = NSRect(x: bounds.width - padding - 24, y: 8, width: 24, height: 24)
        quickLookView?.frame = previewFrame()
        let hasIcon = !placeholderIcon.isHidden
        let centerY = 40 + (bounds.height - 40) / 2
        placeholderIcon.frame = NSRect(x: (bounds.width - 96) / 2, y: centerY - 70, width: 96, height: 96)
        placeholderLabel.frame = NSRect(
            x: padding,
            y: hasIcon ? centerY + 34 : centerY - 20,
            width: bounds.width - padding * 2,
            height: 54
        )
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
