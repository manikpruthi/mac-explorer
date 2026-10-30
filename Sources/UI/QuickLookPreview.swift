import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreview: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    var sourceFrameForPath: ((String) -> NSRect)?
    var onEvent: ((NSEvent) -> Bool)?
    var onShownPathChange: ((String?) -> Void)?
    var onDidClose: ((String?) -> Void)?

    private(set) var isOpen = false
    private var paths: [String] = []
    private var items: [NSURL] = []
    private var shownPath: String?

    var isVisible: Bool {
        QLPreviewPanel.shared()?.isVisible == true
    }

    func show(paths: [String], current: Int) {
        guard !paths.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.paths = paths
        items = paths.map { URL(fileURLWithPath: $0) as NSURL }
        isOpen = true
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, current), items.count - 1)
        shownPath = self.paths[min(max(0, current), items.count - 1)]
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        let panel = QLPreviewPanel.shared()
        let wasVisible = panel?.isVisible == true
        let shown = shownPath ?? currentPreviewPath()
        isOpen = false
        paths = []
        items = []
        shownPath = nil
        if wasVisible {
            panel?.orderOut(nil)
            onDidClose?(shown)
        }
    }

    func sync(paths: [String]) {
        guard isOpen, let panel = QLPreviewPanel.shared() else { return }
        guard paths != self.paths else { return }
        let shown = currentPreviewPath()
        self.paths = paths
        items = paths.map { URL(fileURLWithPath: $0) as NSURL }
        panel.reloadData()
        if let shown, let index = paths.firstIndex(of: shown) {
            panel.currentPreviewItemIndex = index
            shownPath = shown
        } else {
            hide()
        }
    }

    func currentPreviewPath() -> String? {
        QLPreviewPanel.shared()?.currentPreviewItem?.previewItemURL?.path
    }

    // MARK: - QLPreviewPanelDataSource

    @objc(numberOfPreviewItemsInPreviewPanel:)
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    @objc(previewPanel:previewItemAtIndex:)
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    // MARK: - QLPreviewPanelDelegate

    @objc(previewPanel:sourceFrameOnScreenForPreviewItem:)
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let path = item?.previewItemURL?.path else { return .zero }
        return sourceFrameForPath?(path) ?? .zero
    }

    @objc(previewPanel:handleEvent:)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event else { return false }
        return onEvent?(event) ?? false
    }

    func windowDidUpdate(_ notification: Notification) {
        guard isOpen else { return }
        let path = currentPreviewPath()
        guard path != shownPath else { return }
        shownPath = path
        onShownPathChange?(path)
    }

    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        isOpen = false
        let shown = shownPath ?? currentPreviewPath()
        paths = []
        items = []
        shownPath = nil
        onDidClose?(shown)
    }
}