import AppKit

/// Clears chosen kinds of metadata from several items, and optionally from everything inside
/// selected folders. Nothing is changed until the user presses Confirm; the work runs off the
/// main thread, visits one item at a time, and can be stopped part-way.
@MainActor
final class BulkMetadataOverlay: OverlayView {
    /// Called when a run finished and changed at least one item.
    var onFinished: ((MetadataService.BulkResult) -> Void)?

    private let paths: [String]
    private let hasFolder: Bool
    private let head = makeLabel("Clear metadata", size: 15, weight: .semibold)
    private let close = HoverButton(title: "", image: "xmark")
    private let summaryLabel = makeLabel("", size: 13, weight: .semibold, lines: 2)
    private let finderBox = NSButton(checkboxWithTitle: "Tags and comments", target: nil, action: nil)
    private let downloadBox = NSButton(checkboxWithTitle: "Download info (Where from, quarantine flag)", target: nil, action: nil)
    private let embeddedBox = NSButton(checkboxWithTitle: "Image metadata (EXIF, GPS location, camera, IPTC, XMP)", target: nil, action: nil)
    private let extendedBox = NSButton(checkboxWithTitle: "All other extended attributes (advanced)", target: nil, action: nil)
    private let recursiveBox = NSButton(checkboxWithTitle: "Include everything inside the selected folders", target: nil, action: nil)
    private let noteLabel = makeLabel("", size: 11.5, color: Theme.textSecondary, lines: 3)
    private let statusLabel = makeLabel("", size: 12, color: Theme.textSecondary, lines: 3)
    private let spinner = NSProgressIndicator()
    private let confirmButton = HoverButton(title: "Confirm")
    private let cancelButton = HoverButton(title: "Cancel")
    private var task: Task<Void, Never>?
    private let stopFlag = StopFlag()
    private var finished = false

    init(paths: [String]) {
        self.paths = paths
        hasFolder = paths.contains { FileService.statInfo($0, followSymlinks: false)?.isDirectory == true }
        super.init(cardSize: NSSize(width: 500, height: 432))
        dismissOnOutsideClick = false
        close.imagePosition = .imageOnly
        close.cornerRadius = 3
        close.target = self
        close.action = #selector(cancelPressed)

        let folders = paths.filter { FileService.statInfo($0, followSymlinks: false)?.isDirectory == true }.count
        let files = paths.count - folders
        var parts: [String] = []
        if files > 0 { parts.append(FormatTools.plural(files, "file")) }
        if folders > 0 { parts.append(FormatTools.plural(folders, "folder")) }
        summaryLabel.stringValue = paths.count == 1
            ? "“\(PathTools.basename(paths[0]))”"
            : parts.joined(separator: " and ") + " selected"

        for box in [finderBox, downloadBox, embeddedBox, recursiveBox] { box.state = .on }
        extendedBox.state = .off
        for box in [finderBox, downloadBox, embeddedBox, extendedBox, recursiveBox] {
            box.target = self
            box.action = #selector(optionChanged)
        }
        recursiveBox.isHidden = !hasFolder
        noteLabel.stringValue = "Image orientation and file dates are kept. Contents of apps and other packages are skipped, and symbolic links aren’t followed. This can’t be undone."
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        for button in [confirmButton, cancelButton] {
            button.isBordered = true
            button.bezelStyle = .rounded
        }
        confirmButton.bezelColor = Theme.danger
        confirmButton.contentTintColor = .white
        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        [head, close, summaryLabel, finderBox, downloadBox, embeddedBox, extendedBox, recursiveBox, noteLabel, spinner, statusLabel, confirmButton, cancelButton]
            .forEach { card.addSubview($0) }

        let padding: CGFloat = 24
        let width = cardSize.width
        let inner = width - padding * 2
        head.frame = NSRect(x: 18, y: 16, width: 300, height: 20)
        close.frame = NSRect(x: width - 36, y: 10, width: 24, height: 24)
        summaryLabel.frame = NSRect(x: padding, y: 50, width: inner, height: 34)
        let what = makeLabel("Remove:", size: 12, weight: .semibold, color: Theme.textSecondary)
        what.frame = NSRect(x: padding, y: 92, width: inner, height: 16)
        card.addSubview(what)
        var y: CGFloat = 116
        for box in [finderBox, downloadBox, embeddedBox, extendedBox] {
            box.frame = NSRect(x: padding - 2, y: y, width: inner, height: 20)
            y += 26
        }
        recursiveBox.frame = NSRect(x: padding - 2, y: y + 8, width: inner, height: 20)
        noteLabel.frame = NSRect(x: padding, y: y + 40, width: inner, height: 46)
        spinner.frame = NSRect(x: padding, y: y + 98, width: 16, height: 16)
        statusLabel.frame = NSRect(x: padding, y: y + 96, width: inner, height: 48)
        layoutButtons()
        optionChanged()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { stopFlag.stop() }
    }

    private var options: MetadataService.ClearOptions {
        var options: MetadataService.ClearOptions = []
        if finderBox.state == .on { options.insert(.finder) }
        if downloadBox.state == .on { options.insert(.download) }
        if embeddedBox.state == .on { options.insert(.embedded) }
        if extendedBox.state == .on { options.insert(.extended) }
        return options
    }

    private func layoutButtons() {
        layoutButtonRow([cancelButton, confirmButton], trailing: cardSize.width - 18, y: cardSize.height - 48, spacing: 6, minimumWidth: 84)
    }

    @objc private func optionChanged() {
        guard task == nil, !finished else { return }
        confirmButton.isEnabled = !options.isEmpty
        let recursive = hasFolder && recursiveBox.state == .on
        setStatus(options.isEmpty
            ? "Choose at least one kind of metadata to remove."
            : "Press Confirm to remove the checked metadata from \(target(recursive: recursive)).",
            isError: false)
    }

    private func target(recursive: Bool) -> String {
        guard paths.count > 1 else {
            return hasFolder ? (recursive ? "this folder and everything inside it" : "this folder") : "this file"
        }
        return recursive ? "these items and everything inside the folders" : "these items"
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? Theme.danger : Theme.textSecondary
        statusLabel.frame.origin.x = spinner.isHidden ? 24 : 46
        statusLabel.frame.size.width = cardSize.width - 24 - statusLabel.frame.origin.x
    }

    @objc private func confirmPressed() {
        if finished {
            onDismiss?()
            return
        }
        guard task == nil, !options.isEmpty else { return }
        let paths = self.paths
        let options = self.options
        let recursive = hasFolder && recursiveBox.state == .on
        let stopFlag = self.stopFlag
        [finderBox, downloadBox, embeddedBox, extendedBox, recursiveBox].forEach { $0.isEnabled = false }
        confirmButton.isEnabled = false
        cancelButton.title = "Stop"
        layoutButtons()
        spinner.isHidden = false
        spinner.startAnimation(nil)
        setStatus("Clearing metadata…", isError: false)
        let progress: @Sendable (MetadataService.BulkResult) -> Void = { [weak self] result in
            Task { @MainActor in self?.showProgress(result) }
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MetadataService.clear(paths: paths, options: options, recursive: recursive, progress: progress) {
                stopFlag.isStopped
            }
            await MainActor.run { [weak self] in self?.finish(result) }
        }
    }

    private func showProgress(_ result: MetadataService.BulkResult) {
        guard !finished else { return }
        setStatus("Checked \(result.scanned.formatted()) items · cleared \(result.changed.formatted())…", isError: false)
    }

    private func finish(_ result: MetadataService.BulkResult) {
        task = nil
        finished = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        var text = result.cancelled ? "Stopped. " : ""
        let untouched = result.scanned - result.changed - result.failed
        text += "Checked \(FormatTools.plural(result.scanned, "item")): cleared \(result.changed.formatted())"
        text += untouched > 0 ? ", \(untouched.formatted()) had nothing to remove." : "."
        if result.failed > 0 {
            text += " \(FormatTools.plural(result.failed, "item")) couldn’t be changed"
            if let first = result.firstError { text += " — \(first)" }
        }
        setStatus(text, isError: result.failed > 0)
        confirmButton.title = "Done"
        confirmButton.bezelColor = Theme.accent
        confirmButton.isEnabled = true
        cancelButton.isHidden = true
        layoutButtons()
        if result.changed > 0 { onFinished?(result) }
    }

    /// Presses Confirm (UI smoke test).
    func pressConfirmForTesting() { confirmButton.performClick(nil) }
    var isFinishedForTesting: Bool { finished }

    @objc private func cancelPressed() {
        if task != nil {
            stopFlag.stop()
            cancelButton.isEnabled = false
            setStatus("Stopping…", isError: false)
            return
        }
        onDismiss?()
    }

    /// Shared between the main thread and the worker; checked once per item.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool { lock.withLock { stopped } }
        func stop() { lock.withLock { stopped = true } }
    }
}
