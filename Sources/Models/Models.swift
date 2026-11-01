import Foundation

enum FileKind: String, Codable, Sendable, CaseIterable {
    case folder
    case app
    case image
    case video
    case audio
    case pdf
    case word
    case excel
    case powerpoint
    case archive
    case code
    case text
    case font
    case disk
    case file
}

struct FileEntry: Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let kind: FileKind
    let hidden: Bool
}

struct SpecialFolder: Hashable, Sendable {
    let key: String
    let label: String
    let path: String
}

struct Volume: Hashable, Sendable {
    let name: String
    let path: String
    let total: Int64
    let free: Int64
}

struct SystemInfo: Sendable {
    let home: String
    let username: String
    let hostname: String
    let trashPath: String
    let specialFolders: [SpecialFolder]
    let volumes: [Volume]

    var picturesPath: String {
        specialFolders.first(where: { $0.key == "pictures" })?.path ?? home + "/Pictures"
    }
}

struct DirListing: Sendable {
    let path: String
    let parent: String?
    let entries: [FileEntry]
}

struct SearchResponse: Sendable {
    let root: String
    let entries: [FileEntry]
    let truncated: Bool
}

struct GalleryResponse: Sendable {
    let root: String
    let entries: [FileEntry]
    let truncated: Bool
}

struct OpResult: Sendable {
    var ok: Bool
    var error: String?
    var path: String?
    var paths: [String]?
    var count: Int?

    static func success(path: String? = nil, paths: [String]? = nil, count: Int? = nil) -> OpResult {
        OpResult(ok: true, error: nil, path: path, paths: paths, count: count)
    }

    static func failure(_ message: String) -> OpResult {
        OpResult(ok: false, error: message, path: nil, paths: nil, count: nil)
    }
}

struct ClipboardInfo: Sendable {
    var paths: [String]
    var cut: Bool

    static let empty = ClipboardInfo(paths: [], cut: false)
}

struct PropertiesResult: Sendable {
    var ok: Bool
    var error: String?
    var name: String
    var type: String
    var location: String
    var size: Int64
    var sizeOnDisk: Int64
    var files: Int
    var folders: Int
    var created: Date
    var modified: Date
    var isDirectory: Bool
    var isSymlink: Bool
    var path: String
    var multiple: Bool
}

enum ViewMode: String, Codable, Sendable, CaseIterable {
    case large
    case medium
    case list
    case details
    case tiles

    var label: String {
        switch self {
        case .large: return "Large icons"
        case .medium: return "Medium icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        }
    }

    var isGrid: Bool { self == .large || self == .medium }
}

enum SortKey: String, Codable, Sendable, CaseIterable {
    case name
    case modified
    case type
    case size

    var label: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

enum SortDir: String, Codable, Sendable {
    case asc
    case desc
}

enum ThemePreference: String, Codable, Sendable {
    case light
    case dark
    case system
}

enum Location: Hashable, Sendable {
    case home
    case gallery
    case network
    case fs(path: String)
    case archive(archivePath: String, extractRoot: String, path: String)

    var readPath: String? {
        switch self {
        case .fs(let path), .archive(_, _, let path): return path
        default: return nil
        }
    }

    var writePath: String? {
        if case .fs(let path) = self { return path }
        return nil
    }

    var archivePath: String? {
        if case .archive(let archivePath, _, _) = self { return archivePath }
        return nil
    }

    var isArchive: Bool {
        if case .archive = self { return true }
        return false
    }

    var isNetwork: Bool { self == .network }
}

extension Location: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case archivePath
        case extractRoot
        case entryPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "home":
            self = .home
        case "gallery":
            self = .gallery
        case "network":
            self = .network
        case "fs":
            self = .fs(path: try container.decode(String.self, forKey: .path))
        case "archive":
            self = .archive(
                archivePath: try container.decode(String.self, forKey: .archivePath),
                extractRoot: try container.decode(String.self, forKey: .extractRoot),
                path: try container.decode(String.self, forKey: .entryPath)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown location kind"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home:
            try container.encode("home", forKey: .kind)
        case .gallery:
            try container.encode("gallery", forKey: .kind)
        case .network:
            try container.encode("network", forKey: .kind)
        case .fs(let path):
            try container.encode("fs", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .archive(let archivePath, let extractRoot, let path):
            try container.encode("archive", forKey: .kind)
            try container.encode(archivePath, forKey: .archivePath)
            try container.encode(extractRoot, forKey: .extractRoot)
            try container.encode(path, forKey: .entryPath)
        }
    }
}

struct PersistedTab: Codable, Equatable, Sendable {
    var location: Location
    var view: ViewMode
    var sortKey: SortKey
    var sortDir: SortDir
}

struct PersistedSession: Codable, Equatable, Sendable {
    var tabs: [PersistedTab]
    var activeIndex: Int
}

struct NetworkServer: Sendable, Hashable {
    let name: String
    let host: String
    let port: Int?
}

struct MountedShare: Sendable, Hashable {
    let name: String
    let path: String
    let fsType: String
}

struct NetworkState: Sendable {
    var servers: [NetworkServer]
    var mounted: [MountedShare]
    var error: String?
}

struct ArchiveResult: Sendable {
    var ok: Bool
    var archivePath: String?
    var extractRoot: String?
    var error: String?
}

struct RecentItem: Codable, Hashable, Sendable {
    var path: String
    var name: String
    var kind: FileKind
    var modified: Date
    var parent: String
}

struct DeletedItem: Codable, Hashable, Sendable {
    var trashPath: String
    var originDir: String
    var name: String
    var date: Date
}

struct Preferences: Codable, Sendable {
    var theme: ThemePreference = .system
    var showHidden = false
    var showExtensions = false
    var view: ViewMode = .details
    var detailsOpen = false
    var sidebarVisible = true
    var quickAccessOpen = true
    var thisPcOpen = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? container.decode(ThemePreference.self, forKey: .theme)) ?? .system
        showHidden = (try? container.decode(Bool.self, forKey: .showHidden)) ?? false
        showExtensions = (try? container.decode(Bool.self, forKey: .showExtensions)) ?? false
        view = (try? container.decode(ViewMode.self, forKey: .view)) ?? .details
        detailsOpen = (try? container.decode(Bool.self, forKey: .detailsOpen)) ?? false
        sidebarVisible = (try? container.decode(Bool.self, forKey: .sidebarVisible)) ?? true
        quickAccessOpen = (try? container.decode(Bool.self, forKey: .quickAccessOpen)) ?? true
        thisPcOpen = (try? container.decode(Bool.self, forKey: .thisPcOpen)) ?? true
    }
}

enum LocationTools {
    static func same(_ lhs: Location, _ rhs: Location) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home), (.gallery, .gallery), (.network, .network):
            return true
        case (.fs(let a), .fs(let b)):
            return a == b
        case (.archive(let a1, let e1, let p1), .archive(let a2, let e2, let p2)):
            return a1 == a2 && e1 == e2 && p1 == p2
        default:
            return false
        }
    }

    static func title(_ location: Location, system: SystemInfo?) -> String {
        switch location {
        case .home: return "Home"
        case .gallery: return "Gallery"
        case .network: return "Network"
        case .archive(let archivePath, _, _): return PathTools.basename(archivePath)
        case .fs(let path):
            if let system, path == system.trashPath { return "Trash" }
            if path == "/" {
                return system?.volumes.first(where: { $0.path == "/" })?.name ?? "Macintosh HD"
            }
            let name = PathTools.basename(path)
            return name.isEmpty ? path : name
        }
    }

    static func displayPath(_ location: Location, system: SystemInfo?) -> String {
        switch location {
        case .home: return system?.home ?? "~"
        case .gallery: return system?.picturesPath ?? "Pictures"
        case .network: return "Network"
        case .archive(let archivePath, _, _): return archivePath
        case .fs(let path): return path
        }
    }
}

enum PathTools {
    static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { return "/" }
        return (trimmed as NSString).lastPathComponent
    }

    static func dirname(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed == "/" { return "/" }
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func relative(_ root: String, _ target: String) -> String {
        if target == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return target }
        return String(target.dropFirst(prefix.count))
    }

    static func expand(_ raw: String, home: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "~" { return home }
        if value.hasPrefix("~/") { value = home + String(value.dropFirst(1)) }
        return value
    }
}

enum FormatTools {
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB, .usePB]
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        guard value >= 0 else { return "—" }
        if value < 1000 { return "\(value) bytes" }
        return byteFormatter.string(fromByteCount: value)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MM/dd/yyyy h:mm a"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static func date(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "—" }
        return dateFormatter.string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "—" }
        return shortDateFormatter.string(from: date)
    }

    static func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }
}

func sortEntries(_ entries: [FileEntry], key: SortKey, dir: SortDir, showExtensions: Bool) -> [FileEntry] {
    let direction: Int = dir == .asc ? 1 : -1
    return entries.sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        var result: Int = 0
        switch key {
        case .name:
            result = displayName(lhs.name, showExtensions).localizedStandardCompare(displayName(rhs.name, showExtensions)).rawValue
        case .modified:
            result = lhs.modified.compare(rhs.modified).rawValue
        case .type:
            result = FileKinds.typeLabel(lhs.name, lhs.isDirectory).localizedStandardCompare(FileKinds.typeLabel(rhs.name, rhs.isDirectory)).rawValue
            if result == 0 { result = lhs.name.localizedStandardCompare(rhs.name).rawValue }
        case .size:
            if lhs.size == rhs.size { result = 0 } else { result = lhs.size < rhs.size ? -1 : 1 }
        }
        if result == 0 { result = lhs.name.localizedStandardCompare(rhs.name).rawValue }
        return result * direction < 0
    }
}

func displayName(_ name: String, _ showExtensions: Bool) -> String {
    if showExtensions || !FileKinds.shouldHideExtension(name) { return name }
    return FileKinds.baseName(name)
}
