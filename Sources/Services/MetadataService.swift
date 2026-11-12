import CoreServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Embedded (in-file) image metadata, split the way photo tools present it.
enum EmbeddedSection: String, Sendable, CaseIterable {
    case exif = "EXIF (camera)"
    case gps = "GPS (location)"
    case tiff = "TIFF (device)"
    case iptc = "IPTC"
    case xmp = "XMP"
    /// PNG chunks / JPEG segments ImageIO doesn't expose (C2PA credentials, text chunks, …).
    case container = "Other embedded data"
}

enum MetadataGroupKind: Hashable, Sendable {
    case file
    case finder
    case embedded(EmbeddedSection)
    case extended
    case spotlight
}

enum MetadataKey: Hashable, Sendable {
    case info
    case created
    case modified
    case tags
    case comment
    case whereFrom
    case quarantine
    /// XMP-style path such as `exif:FNumber` or `dc:subject`.
    case embedded(String)
    /// A `ContainerMetadata.Block` id, e.g. `caBX` or `zTXt:Raw profile type APP1`.
    case container(String)
    case xattr(String)
    case spotlight(String)
}

struct MetadataItem: Sendable {
    let key: MetadataKey
    let label: String
    let value: String
    var editable = false
    var removable = false
    var hint: String?
    var detail: String?
}

struct MetadataGroup: Sendable {
    let kind: MetadataGroupKind
    let title: String
    var items: [MetadataItem]
    var note: String?

    /// Items a section-wide Clear removes. Orientation is kept so photos never turn sideways.
    var clearableItems: [MetadataItem] {
        items.filter { $0.removable && $0.key != .embedded("tiff:Orientation") }
    }
}

struct MetadataReport: Sendable {
    let path: String
    let groups: [MetadataGroup]
}

/// Reads and edits a single item's metadata: file dates, Finder tags/comment/download info,
/// embedded image metadata (EXIF, GPS, TIFF, IPTC, XMP via ImageIO), extended attributes, and the
/// read-only Spotlight record. Nothing is cached; each call reads what it needs and lets it go.
enum MetadataService {
    static let dateFormat = "yyyy-MM-dd HH:mm:ss"

    private static let tagsXattr = "com.apple.metadata:_kMDItemUserTags"
    private static let commentXattr = "com.apple.metadata:kMDItemFinderComment"
    private static let whereFromXattr = "com.apple.metadata:kMDItemWhereFroms"
    private static let quarantineXattr = "com.apple.quarantine"
    /// Shown in the Finder section, so the raw attribute list skips them.
    private static let finderXattrs: Set<String> = [tagsXattr, commentXattr, whereFromXattr, quarantineXattr]
    /// Larger attribute values (resource forks, caches) are summarized, never loaded.
    private static let maxXattrRead = 64 * 1024
    private static let maxValueLength = 600
    /// Fields that describe the pixel layout; image writers regenerate them, so they're read-only.
    private static let structuralTags: Set<String> = [
        "exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace", "tiff:ImageWidth", "tiff:ImageLength",
        "tiff:TileWidth", "tiff:TileLength", "tiff:Compression", "tiff:PhotometricInterpretation",
        "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:PlanarConfiguration",
        "tiff:ResolutionUnit", "tiff:XResolution", "tiff:YResolution",
    ]

    // MARK: - Reading

    static func read(_ path: String) -> MetadataReport? {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        var groups = [fileGroup(path, info)]
        let xattrs = listXattrs(path)
        groups.append(finderGroup(path, xattrs: xattrs))
        if info.st_mode & S_IFMT == S_IFREG {
            groups.append(contentsOf: embeddedGroups(path))
        }
        groups.append(extendedGroup(path, xattrs: xattrs))
        groups.append(spotlightGroup(path))
        return MetadataReport(path: path, groups: groups)
    }

    private static func fileGroup(_ path: String, _ info: stat) -> MetadataGroup {
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let hint = "\(dateFormat) (local time)"
        var items = [
            MetadataItem(key: .info, label: "Name", value: PathTools.basename(path)),
            MetadataItem(key: .info, label: "Location", value: PathTools.dirname(path)),
        ]
        if !isDirectory {
            items.append(MetadataItem(key: .info, label: "Size", value: "\(FormatTools.bytes(Int64(info.st_size))) (\(Int64(info.st_size).formatted()) bytes)"))
        }
        items += [
            MetadataItem(key: .created, label: "Created", value: format(date(info.st_birthtimespec)), editable: true, hint: hint),
            MetadataItem(key: .modified, label: "Modified", value: format(date(info.st_mtimespec)), editable: true, hint: hint),
            MetadataItem(key: .info, label: "Last accessed", value: format(date(info.st_atimespec))),
            MetadataItem(key: .info, label: "Status changed", value: format(date(info.st_ctimespec))),
        ]
        return MetadataGroup(kind: .file, title: "File", items: items, note: "Dates can be edited; they can’t be removed.")
    }

    private static func finderGroup(_ path: String, xattrs: [String]) -> MetadataGroup {
        let present = Set(xattrs)
        let tags = ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
        var items = [
            MetadataItem(key: .tags, label: "Tags", value: tags.joined(separator: ", "), editable: true, removable: !tags.isEmpty, hint: "Comma-separated, e.g. Red, Work"),
        ]
        let comment = present.contains(commentXattr) ? (plistValue(readXattr(path, commentXattr)) as? String) ?? "" : ""
        items.append(MetadataItem(key: .comment, label: "Comment", value: comment, editable: true, removable: !comment.isEmpty, hint: "Spotlight comment"))
        if present.contains(whereFromXattr) {
            let sources = (plistValue(readXattr(path, whereFromXattr)) as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
            items.append(MetadataItem(key: .whereFrom, label: "Where from", value: sources.joined(separator: "  ·  "), removable: true))
        }
        if present.contains(quarantineXattr), let data = readXattr(path, quarantineXattr),
           let raw = String(data: data, encoding: .utf8) {
            items.append(MetadataItem(key: .quarantine, label: "Quarantine", value: describeQuarantine(raw), removable: true, detail: raw))
        }
        return MetadataGroup(kind: .finder, title: "Finder & download info", items: items)
    }

    private static func embeddedGroups(_ path: String) -> [MetadataGroup] {
        imageIOGroups(path) + containerGroups(path)
    }

    private static func containerGroups(_ path: String) -> [MetadataGroup] {
        let blocks = ContainerMetadata.scan(path)
        guard !blocks.isEmpty else { return [] }
        let items = blocks.map { block in
            MetadataItem(
                key: .container(block.id),
                label: block.label,
                value: FormatTools.bytes(Int64(block.size)) + (block.count > 1 ? " in \(block.count) blocks" : ""),
                removable: true,
                detail: block.id
            )
        }
        return [MetadataGroup(
            kind: .embedded(.container),
            title: EmbeddedSection.container.rawValue,
            items: items,
            note: "Blocks stored beside the picture, e.g. AI content credentials. Removing them leaves the pixels untouched."
        )]
    }

    private static func imageIOGroups(_ path: String) -> [MetadataGroup] {
        let url = URL(fileURLWithPath: path) as CFURL
        // Header-only read: no pixels are decoded or cached.
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        var buckets: [EmbeddedSection: [MetadataItem]] = [:]
        for tag in tags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            // `iio:` flags are ImageIO bookkeeping, not data stored in the file.
            guard prefix != "iio" else { continue }
            let path = "\(prefix):\(name)"
            let type = CGImageMetadataTagGetType(tag)
            let structural = structuralTags.contains(path)
            let editable = !structural && (type == .string || ((type == .arrayOrdered || type == .arrayUnordered) && isStringArray(tag)))
            let item = MetadataItem(
                key: .embedded(path),
                label: humanize(name),
                value: clip(describe(tag)),
                editable: editable,
                removable: !structural,
                hint: editable && type != .string ? "Comma-separated values" : nil,
                detail: path
            )
            buckets[section(prefix: prefix, name: name), default: []].append(item)
        }
        return EmbeddedSection.allCases.filter { $0 != .container }.compactMap { section in
            guard let items = buckets[section], !items.isEmpty else { return nil }
            var group = MetadataGroup(kind: .embedded(section), title: section.rawValue, items: items.sorted { $0.label < $1.label })
            if section == .tiff, items.contains(where: { $0.key == .embedded("tiff:Orientation") }) {
                group.note = "Clear keeps Orientation so the image isn’t shown sideways."
            }
            return group
        }
    }

    private static func extendedGroup(_ path: String, xattrs: [String]) -> MetadataGroup {
        var items: [MetadataItem] = []
        var hasProtected = false
        for name in xattrs where !finderXattrs.contains(name) {
            let size = xattrSize(path, name)
            guard size >= 0 else { continue }
            if isProtected(name) {
                hasProtected = true
                let data = size <= maxXattrRead ? readXattr(path, name) ?? Data() : Data()
                items.append(MetadataItem(key: .xattr(name), label: name, value: "Managed by macOS · " + hexPreview(data), detail: name))
                continue
            }
            if size > maxXattrRead {
                items.append(MetadataItem(key: .xattr(name), label: name, value: "\(FormatTools.bytes(Int64(size))) of data", removable: true))
                continue
            }
            let data = readXattr(path, name) ?? Data()
            var editable = false
            let value: String
            if let decoded = plistValue(data) {
                value = describePlist(decoded)
                editable = decoded is String
            } else if let text = String(data: data, encoding: .utf8), text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) {
                value = text
                editable = true
            } else {
                value = hexPreview(data)
            }
            items.append(MetadataItem(key: .xattr(name), label: name, value: clip(value), editable: editable && value.count <= maxValueLength, removable: true))
        }
        let note = items.isEmpty
            ? "No other extended attributes."
            : hasProtected ? "Attributes managed by macOS (provenance, privacy access list) are re-added by the system, so they can’t be removed." : nil
        return MetadataGroup(kind: .extended, title: "Extended attributes", items: items, note: note)
    }

    private static func spotlightGroup(_ path: String) -> MetadataGroup {
        var items: [MetadataItem] = []
        if let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
           let names = MDItemCopyAttributeNames(item) as? [String] {
            for name in names.sorted(by: { humanize(spotlightName($0)) < humanize(spotlightName($1)) }) {
                guard let value = MDItemCopyAttribute(item, name as CFString) else { continue }
                let text = describePlist(value)
                guard !text.isEmpty else { continue }
                items.append(MetadataItem(key: .spotlight(name), label: humanize(spotlightName(name)), value: clip(text), detail: name))
            }
        }
        let note = items.isEmpty
            ? "This item isn’t in the Spotlight index."
            : "Read-only. Spotlight rebuilds this from the file and the sections above."
        return MetadataGroup(kind: .spotlight, title: "Spotlight", items: items, note: note)
    }

    // MARK: - Bulk clear

    struct ClearOptions: OptionSet, Sendable {
        let rawValue: Int
        /// Finder tags and Spotlight comment.
        static let finder = ClearOptions(rawValue: 1)
        /// "Where from" URLs and the quarantine flag.
        static let download = ClearOptions(rawValue: 2)
        /// EXIF, GPS, TIFF, IPTC, and XMP inside image files (orientation and layout are kept).
        static let embedded = ClearOptions(rawValue: 4)
        /// Every other extended attribute, except ones macOS protects.
        static let extended = ClearOptions(rawValue: 8)
    }

    struct BulkResult: Sendable {
        var scanned = 0
        var changed = 0
        var failed = 0
        var firstError: String?
        var cancelled = false
    }

    /// Attributes macOS manages itself; removing them fails or is undone, so bulk clear skips them.
    private static let protectedXattrs: Set<String> = ["com.apple.provenance", "com.apple.macl", "com.apple.rootless"]

    /// Clears the chosen kinds of metadata from `paths` and, with `recursive`, from everything
    /// inside selected folders. Items are visited one at a time through a lazy enumerator, so
    /// memory stays flat for any tree size. Symlinks are never followed, and the contents of
    /// packages (apps, bundles, libraries) are skipped so their code signatures stay intact.
    static func clear(
        paths: [String],
        options: ClearOptions,
        recursive: Bool,
        progress: @Sendable (BulkResult) -> Void,
        isCancelled: () -> Bool
    ) -> BulkResult {
        var result = BulkResult()
        var lastReport = Date.distantPast
        func visit(_ path: String) {
            result.scanned += 1
            switch clearOne(path, options: options) {
            case .changed: result.changed += 1
            case .unchanged: break
            case .failed(let error):
                result.failed += 1
                if result.firstError == nil { result.firstError = error }
            }
            if Date().timeIntervalSince(lastReport) > 0.15 {
                lastReport = Date()
                progress(result)
            }
        }
        for path in paths {
            if isCancelled() { result.cancelled = true; break }
            visit(path)
            var info = stat()
            guard recursive, path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [],
                options: [.skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if isCancelled() { result.cancelled = true; break }
                autoreleasepool { visit(url.path) }
            }
            if result.cancelled { break }
        }
        return result
    }

    private enum ClearOutcome { case changed, unchanged, failed(String) }

    private static func clearOne(_ path: String, options: ClearOptions) -> ClearOutcome {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return .failed(errorText(path, errno)) }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return .unchanged }
        let present = Set(listXattrs(path))
        var keys: [MetadataKey] = []
        if options.contains(.finder) {
            if present.contains(tagsXattr) { keys.append(.tags) }
            if present.contains(commentXattr) { keys.append(.comment) }
        }
        if options.contains(.download) {
            if present.contains(whereFromXattr) { keys.append(.whereFrom) }
            if present.contains(quarantineXattr) { keys.append(.quarantine) }
        }
        if options.contains(.extended) {
            keys += present
                .filter { !finderXattrs.contains($0) && !isProtected($0) }
                .sorted()
                .map { .xattr($0) }
        }
        if options.contains(.embedded), type == S_IFREG, isImageFile(path) {
            keys += embeddedGroups(path).flatMap { $0.clearableItems.map(\.key) }
        }
        guard !keys.isEmpty else { return .unchanged }
        if let error = remove(keys, path: path) {
            let name = PathTools.basename(path)
            return .failed(error.contains(name) ? error : "“\(name)”: \(error)")
        }
        return .changed
    }

    private static func isProtected(_ name: String) -> Bool {
        protectedXattrs.contains(name) || name.hasPrefix("com.apple.system.")
    }

    /// Cheap extension check first, so non-images are never opened.
    private static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: - Writing

    /// Sets one value. Returns an error message, or nil on success.
    static func set(_ key: MetadataKey, value: String, path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        switch key {
        case .created, .modified:
            guard let date = parseDate(value) else { return "Enter a date as \(dateFormat), e.g. 2024-05-01 09:30:00." }
            let attribute: FileAttributeKey = key == .created ? .creationDate : .modificationDate
            return attempt { try FileManager.default.setAttributes([attribute: date], ofItemAtPath: path) }
        case .tags:
            let tags = splitList(value)
            return attempt { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        case .comment:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return removeXattr(path, commentXattr) }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: trimmed, format: .binary, options: 0) else {
                return "Couldn’t encode the comment."
            }
            return writeXattr(path, commentXattr, data)
        case .xattr(let name):
            // Keep the original encoding: property-list strings stay property lists.
            let isPlist = plistValue(readXattr(path, name)) != nil
            let data = isPlist
                ? (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
                : Data(value.utf8)
            return writeXattr(path, name, data)
        case .embedded(let tagPath):
            var expected = ""
            return rewriteImage(path, excludeGPS: false, mutate: { metadata in
                guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, tagPath as CFString),
                      let namespace = CGImageMetadataTagCopyNamespace(tag),
                      let prefix = CGImageMetadataTagCopyPrefix(tag),
                      let name = CGImageMetadataTagCopyName(tag) else { return false }
                let type = CGImageMetadataTagGetType(tag)
                let newValue: CFTypeRef = type == .string ? value as CFString : splitList(value) as CFArray
                guard let replacement = CGImageMetadataTagCreate(namespace, prefix, name, type, newValue) else { return false }
                expected = describe(replacement)
                return CGImageMetadataSetTagWithPath(metadata, nil, tagPath as CFString, replacement)
            }, verify: { written in
                let tag = written.flatMap { CGImageMetadataCopyTagWithPath($0, nil, tagPath as CFString) }
                return tag.map(describe) == expected ? [] : [tagPath]
            })
        case .info, .whereFrom, .quarantine, .spotlight, .container:
            return "This value can’t be edited."
        }
    }

    /// Removes the given keys. Embedded keys are removed in one rewrite of the file.
    static func remove(_ keys: [MetadataKey], path: String) -> String? {
        var firstError: String?
        var embedded: [String] = []
        var blocks: Set<String> = []
        for key in keys {
            var error: String?
            switch key {
            case .tags:
                error = attempt { try (URL(fileURLWithPath: path) as NSURL).setResourceValue([String](), forKey: .tagNamesKey) }
            case .comment: error = removeXattr(path, commentXattr)
            case .whereFrom: error = removeXattr(path, whereFromXattr)
            case .quarantine: error = removeXattr(path, quarantineXattr)
            case .xattr(let name): error = removeXattr(path, name)
            case .embedded(let tagPath): embedded.append(tagPath)
            case .container(let id): blocks.insert(id)
            case .info, .created, .modified, .spotlight: error = "This value can’t be removed."
            }
            if firstError == nil { firstError = error }
        }
        if !embedded.isEmpty {
            let gps = embedded.contains { $0.hasPrefix("exif:GPS") }
            let error = rewriteImage(path, excludeGPS: gps, mutate: { metadata in
                for tagPath in embedded { CGImageMetadataRemoveTagWithPath(metadata, nil, tagPath as CFString) }
                return true
            }, verify: { written in
                guard let written else { return [] }
                return embedded.filter { CGImageMetadataCopyTagWithPath(written, nil, $0 as CFString) != nil }
            })
            if firstError == nil { firstError = error }
        }
        // After the ImageIO pass, which may itself have dropped some of these blocks.
        if !blocks.isEmpty {
            let present = Set(ContainerMetadata.scan(path).map(\.id)).intersection(blocks)
            if !present.isEmpty, let error = ContainerMetadata.strip(path, ids: present), firstError == nil {
                firstError = error
            }
        }
        return firstError
    }

    /// Rewrites the file's embedded metadata through a temp file in the same folder that then
    /// replaces the original atomically. The image data is copied, not re-encoded; only lossless
    /// single-image formats that refuse a metadata-only copy (PNG, TIFF, BMP) are decoded once and
    /// written back pixel-for-pixel. `verify` inspects the temp file before it replaces the
    /// original and returns the fields that didn't take; then nothing is changed.
    private static func rewriteImage(
        _ path: String,
        excludeGPS: Bool,
        mutate: (CGMutableImageMetadata) -> Bool,
        verify: (CGImageMetadata?) -> [String]
    ) -> String? {
        let url = URL(fileURLWithPath: path)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).metadata-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(url.pathExtension)
        defer { try? FileManager.default.removeItem(at: temp) }

        let outcome: String? = {
            let unshared = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, unshared),
                  let type = CGImageSourceGetType(source) else { return "This file’s embedded metadata can’t be read." }
            let metadata: CGMutableImageMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
                .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            guard mutate(metadata) else { return "Couldn’t change that field." }

            func writtenMetadata() -> CGImageMetadata? {
                CGImageSourceCreateWithURL(temp as CFURL, unshared).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
            }

            var copied = false
            if let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, CGImageSourceGetCount(source), nil) {
                var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
                if excludeGPS { options[kCGImageMetadataShouldExcludeGPS] = true }
                copied = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
            }
            var missed = copied ? verify(writtenMetadata()) : []

            let lossless = [UTType.png, .tiff, .bmp].contains { UTType(type as String)?.conforms(to: $0) == true }
            if (!copied || !missed.isEmpty), lossless, CGImageSourceGetCount(source) == 1 {
                try? FileManager.default.removeItem(at: temp)
                if let image = CGImageSourceCreateImageAtIndex(source, 0, unshared),
                   let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) {
                    CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
                    copied = CGImageDestinationFinalize(destination)
                    missed = copied ? verify(writtenMetadata()) : []
                }
            }
            guard copied else {
                return "This image format can’t be updated without re-encoding the picture, so its embedded metadata is read-only."
            }
            guard missed.isEmpty else {
                let list = missed.prefix(3).joined(separator: ", ") + (missed.count > 3 ? ", …" : "")
                return "This file format doesn’t allow changing \(missed.count == 1 ? "that field" : "\(missed.count) of those fields") (\(list)), so nothing was changed."
            }
            return nil
        }()
        if let outcome { return outcome }
        return replace(url, with: temp)
    }

    /// Swaps a verified temp copy in for the original. Changing metadata isn't a content edit,
    /// so the file keeps its created/modified dates.
    static func replace(_ url: URL, with temp: URL) -> String? {
        let dates = (try? FileManager.default.attributesOfItem(atPath: url.path))?
            .filter { $0.key == .creationDate || $0.key == .modificationDate } ?? [:]
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            if !dates.isEmpty { try? FileManager.default.setAttributes(dates, ofItemAtPath: url.path) }
            return nil
        } catch {
            return "Couldn’t save “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    // MARK: - Extended attributes

    static func listXattrs(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard read > 0 else { return [] }
        return buffer.prefix(read).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
    }

    private static func xattrSize(_ path: String, _ name: String) -> Int {
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
    }

    static func readXattr(_ path: String, _ name: String) -> Data? {
        let size = xattrSize(path, name)
        guard size >= 0, size <= maxXattrRead else { return nil }
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read >= 0 ? data.prefix(read) : nil
    }

    private static func writeXattr(_ path: String, _ name: String, _ data: Data) -> String? {
        let result = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        return result == 0 ? nil : errorText(path, errno)
    }

    private static func removeXattr(_ path: String, _ name: String) -> String? {
        if removexattr(path, name, XATTR_NOFOLLOW) == 0 || errno == ENOATTR { return nil }
        return errorText(path, errno)
    }

    // MARK: - Formatting

    private static func section(prefix: String, name: String) -> EmbeddedSection {
        switch prefix {
        case "exif" where name.hasPrefix("GPS"): .gps
        case "exif", "exifEX", "aux": .exif
        case "tiff": .tiff
        case "Iptc4xmpCore", "Iptc4xmpExt", "photoshop", "iptc": .iptc
        default: .xmp
        }
    }

    private static func isStringArray(_ tag: CGImageMetadataTag) -> Bool {
        guard let children = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return false }
        return children.allSatisfy { CGImageMetadataTagGetType($0) == .string }
    }

    private static func describe(_ tag: CGImageMetadataTag) -> String {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return "" }
        switch CGImageMetadataTagGetType(tag) {
        case .arrayOrdered, .arrayUnordered, .alternateArray, .alternateText:
            return (value as? [CGImageMetadataTag])?.map(describe).joined(separator: ", ") ?? ""
        case .structure:
            guard let fields = value as? [String: CGImageMetadataTag] else { return "" }
            return fields.keys.sorted().map { "\($0): \(describe(fields[$0]!))" }.joined(separator: "; ")
        default:
            return describePlist(value)
        }
    }

    private static func describePlist(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let date as Date: return format(date)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "No") : number.stringValue
        case let array as [Any]:
            let shown = array.prefix(30).map(describePlist)
            return shown.joined(separator: ", ") + (array.count > 30 ? ", … (\(array.count) total)" : "")
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().map { "\($0): \(describePlist(dictionary[$0]!))" }.joined(separator: "; ")
        case let data as Data: return hexPreview(data)
        default: return String(describing: value)
        }
    }

    private static func plistValue(_ data: Data?) -> Any? {
        guard let data, data.starts(with: Array("bplist".utf8)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    private static func hexPreview(_ data: Data) -> String {
        let hex = data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
        return data.count > 24 ? "\(hex) … (\(data.count) bytes)" : hex
    }

    /// `0083;65a1b2c3;Safari;UUID` → "Downloaded by Safari · 2024-01-12 10:00:00".
    private static func describeQuarantine(_ raw: String) -> String {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var text = parts.count > 2 && !parts[2].isEmpty ? "Downloaded by \(parts[2])" : "Marked as downloaded"
        if parts.count > 1, let seconds = UInt64(parts[1], radix: 16) {
            text += " · \(format(Date(timeIntervalSince1970: TimeInterval(seconds))))"
        }
        return text
    }

    private static func spotlightName(_ name: String) -> String {
        for prefix in ["_kMDItem", "kMDItem", "kMD"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    /// "FNumber" → "F Number", "PixelXDimension" → "Pixel X Dimension", "GPSLatitude" → "GPS Latitude".
    static func humanize(_ name: String) -> String {
        let characters = Array(name)
        var result = ""
        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) { result.append(" ") }
            } else if index > 0, character.isNumber, characters[index - 1].isLetter {
                result.append(" ")
            }
            result.append(character == "_" ? " " : character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > maxValueLength ? String(flat.prefix(maxValueLength)) + "…" : flat
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = dateFormat
        return formatter
    }

    static func format(_ date: Date) -> String { formatter().string(from: date) }

    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = formatter().date(from: trimmed) { return date }
        let dateOnly = formatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: trimmed)
    }

    private static func attempt(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func errorText(_ path: String, _ code: Int32) -> String {
        code == EPERM || code == EACCES
            ? "You don’t have permission to change “\(PathTools.basename(path))”."
            : "“\(PathTools.basename(path))”: \(String(cString: strerror(code)))"
    }
}
