import AppKit

@MainActor
enum PasteboardService {
    private static var internalPaths: [String] = []
    private static var internalCut = false
    private static var ownedChangeCount: Int?

    private static let readingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
    ]

    private static func readSystemPaths() -> [String]? {
        let pasteboard = NSPasteboard.general
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: readingOptions) as? [URL]
        guard let objects else { return nil }
        return objects.filter { $0.isFileURL }.map { $0.path }
    }

    private static func publish(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        pasteboard.writeObjects(urls)
        ownedChangeCount = pasteboard.changeCount
    }

    static func copy(_ paths: [String], cut: Bool) -> OpResult {
        let valid = paths.filter { FileService.exists($0) }
        internalPaths = valid
        internalCut = cut
        if !valid.isEmpty {
            publish(valid)
        }
        return OpResult(
            ok: !valid.isEmpty,
            error: valid.isEmpty ? "Nothing to copy." : nil,
            path: nil,
            paths: nil,
            count: valid.count
        )
    }

    static func current() -> ClipboardInfo {
        let systemPaths = readSystemPaths()
        let changeCount = NSPasteboard.general.changeCount
        if let systemPaths {
            if ownedChangeCount == changeCount && !internalPaths.isEmpty {
                return ClipboardInfo(paths: internalPaths, cut: internalCut)
            }
            if systemPaths.isEmpty && ownedChangeCount == nil && !internalPaths.isEmpty {
                return ClipboardInfo(paths: internalPaths, cut: internalCut)
            }
            return ClipboardInfo(paths: systemPaths, cut: false)
        }
        return ClipboardInfo(paths: internalPaths, cut: internalCut)
    }

    static func pastePlan() -> FileService.PastePlan? {
        let info = current()
        guard !info.paths.isEmpty else { return nil }
        let internalSource = ownedChangeCount == NSPasteboard.general.changeCount && !internalPaths.isEmpty
        return FileService.PastePlan(sources: info.paths, cut: info.cut, internalSource: internalSource)
    }

    static func finishCut(remaining: [String]) {
        guard internalCut else { return }
        internalPaths = remaining
        if remaining.isEmpty {
            internalCut = false
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            ownedChangeCount = pasteboard.changeCount
        } else {
            publish(remaining)
        }
    }

    static func clear() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        ownedChangeCount = pasteboard.changeCount
        internalPaths = []
        internalCut = false
    }

    static func hasFiles() -> Bool {
        !current().paths.isEmpty
    }
}
