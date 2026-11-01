import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

private final class ImageBox: @unchecked Sendable {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
}

@MainActor
final class IconService {
    static let shared = IconService()

    private let iconCache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var queue: [String: [(NSImage?) -> Void]] = [:]
    private let folderIcons = NSCache<NSString, NSImage>()

    private init() {
        iconCache.countLimit = 384
        iconCache.totalCostLimit = 8 * 1024 * 1024
        thumbnailCache.countLimit = 140
        thumbnailCache.totalCostLimit = 16 * 1024 * 1024
        folderIcons.countLimit = 16
    }

    func folderIcon(size: CGFloat) -> NSImage {
        let key = "\(Int(size.rounded()))" as NSString
        if let cached = folderIcons.object(forKey: key) { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            let back = NSBezierPath(
                roundedRect: NSRect(x: s * 0.06, y: s * 0.18, width: s * 0.88, height: s * 0.58),
                xRadius: s * 0.07,
                yRadius: s * 0.07
            )
            NSColor(srgbRed: 0.83, green: 0.60, blue: 0.10, alpha: 1).setFill()
            back.fill()

            let tab = NSBezierPath(
                roundedRect: NSRect(x: s * 0.06, y: s * 0.62, width: s * 0.40, height: s * 0.20),
                xRadius: s * 0.06,
                yRadius: s * 0.06
            )
            NSColor(srgbRed: 0.86, green: 0.63, blue: 0.11, alpha: 1).setFill()
            tab.fill()

            let front = NSBezierPath(
                roundedRect: NSRect(x: s * 0.06, y: s * 0.14, width: s * 0.88, height: s * 0.52),
                xRadius: s * 0.06,
                yRadius: s * 0.06
            )
            NSColor(srgbRed: 1.0, green: 0.78, blue: 0.24, alpha: 1).setFill()
            front.fill()

            let highlight = NSBezierPath(
                roundedRect: NSRect(x: s * 0.10, y: s * 0.16, width: s * 0.80, height: s * 0.08),
                xRadius: s * 0.03,
                yRadius: s * 0.03
            )
            NSColor(srgbRed: 1.0, green: 0.85, blue: 0.42, alpha: 0.75).setFill()
            highlight.fill()
            return true
        }
        folderIcons.setObject(image, forKey: key)
        return image
    }

    /// The Dock icon uses the same folder artwork with a small transparent margin so it
    /// sits slightly smaller than the standard Dock tile without changing the drawing.
    func appIcon(size: CGFloat, contentScale: CGFloat = 0.88) -> NSImage {
        let key = "app-\(Int(size.rounded()))-\(Int((contentScale * 100).rounded()))" as NSString
        if let cached = folderIcons.object(forKey: key) { return cached }
        let contentSize = size * contentScale
        let base = folderIcon(size: contentSize)
        let inset = (size - contentSize) / 2
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        folderIcons.setObject(image, forKey: key)
        return image
    }

    func fileIcon(for entry: FileEntry, size: CGFloat) -> NSImage {
        if entry.isDirectory && entry.kind != .app {
            return folderIcon(size: size)
        }
        // Plain documents share one icon per extension: avoids a synchronous
        // NSWorkspace lookup (and a cache slot) for every row in large folders.
        let ext = FileKinds.extensionOf(entry.name)
        if !entry.isDirectory, !entry.isSymlink, entry.kind != .app, !ext.isEmpty,
           let type = UTType(filenameExtension: ext) {
            return typeIcon(type, ext: ext, size: size)
        }
        return workspaceIcon(forPath: entry.path, size: size)
    }

    private func typeIcon(_ type: UTType, ext: String, size: CGFloat) -> NSImage {
        let key = "type:\(ext)|\(Int(size))" as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let source = NSWorkspace.shared.icon(for: type)
        let targetSize = NSSize(width: size, height: size)
        let image = NSImage(size: targetSize, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        iconCache.setObject(image, forKey: key, cost: Int(size * size * 4))
        return image
    }

    func workspaceIcon(forPath path: String, size: CGFloat) -> NSImage {
        let key = "\(path)|\(Int(size))" as NSString
        if let cached = iconCache.object(forKey: key) { return cached }

        let source = NSWorkspace.shared.icon(forFile: path)
        let targetSize = NSSize(width: size, height: size)
        source.size = targetSize
        let image = NSImage(size: targetSize, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        iconCache.setObject(image, forKey: key, cost: Int(size * size * 4))
        return image
    }

    func genericIcon(kind: FileKind, size: CGFloat) -> NSImage {
        if kind == .folder {
            return folderIcon(size: size)
        }
        let key = "generic:\(kind.rawValue):\(Int(size))" as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let symbolName: String
        switch kind {
        case .image: symbolName = "photo"
        case .video: symbolName = "film"
        case .audio: symbolName = "music.note"
        case .pdf: symbolName = "doc.richtext"
        case .archive: symbolName = "archivebox"
        case .code: symbolName = "chevron.left.forwardslash.chevron.right"
        case .text: symbolName = "doc.text"
        case .app: symbolName = "app"
        case .disk: symbolName = "externaldrive"
        case .font: symbolName = "textformat"
        case .word, .excel, .powerpoint: symbolName = "doc"
        case .folder: symbolName = "folder"
        case .file: symbolName = "doc"
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: size, height: size))
        iconCache.setObject(image, forKey: key, cost: Int(size * size * 4))
        return image
    }

    func thumbnail(for entry: FileEntry, size: CGFloat, completion: @escaping @MainActor (NSImage?) -> Void) {
        guard entry.kind == .image else {
            completion(nil)
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(entry.path)|\(entry.modified.timeIntervalSince1970)|\(Int(size))@\(Int(scale))"
        let cacheKey = key as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }
        if queue[key] != nil {
            queue[key]?.append(completion)
            return
        }
        queue[key] = [completion]

        let url = URL(fileURLWithPath: entry.path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let boxed = ImageBox(representation?.nsImage)
            let keyValue = key
            Task { @MainActor in
                guard let self else { return }
                let image = boxed.image
                if let image {
                    self.thumbnailCache.setObject(
                        image,
                        forKey: keyValue as NSString,
                        cost: Int(image.size.width * image.size.height * 4)
                    )
                }
                let waiters = self.queue.removeValue(forKey: keyValue) ?? []
                for waiter in waiters { waiter(image) }
            }
        }
    }
}
