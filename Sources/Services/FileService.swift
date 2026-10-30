import AppKit
import Foundation

private final class EntryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileEntry?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(_ entry: FileEntry?, at index: Int) {
        lock.lock()
        values[index] = entry
        lock.unlock()
    }

    func all() -> [FileEntry] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }
    }
}

struct PasteOutcome: Sendable {
    var result: OpResult
    var remainingSources: [String]
}

enum FileService {
    static let batchSize = 48

    // MARK: - Stat helpers

    struct StatInfo {
        var isDirectory: Bool
        var size: Int64
        var modified: Date
        var created: Date
    }

    static func statInfo(_ path: String) -> StatInfo? {
        var info = stat()
        let status = path.withCString { stat($0, &info) }
        guard status == 0 else { return nil }
        let modified = Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let created = Date(
            timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000
        )
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let size = isDirectory ? 0 : Int64(info.st_size)
        return StatInfo(isDirectory: isDirectory, size: size, modified: modified, created: created)
    }

    static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        let status = path.withCString { lstat($0, &info) }
        return status == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isSameFile(_ first: String, _ second: String) -> Bool {
        var a = stat()
        var b = stat()
        let firstStatus = first.withCString { stat($0, &a) }
        let secondStatus = second.withCString { stat($0, &b) }
        guard firstStatus == 0, secondStatus == 0 else { return false }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    static func entry(name: String, path: String) -> FileEntry? {
        guard let info = statInfo(path) else { return nil }
        return FileEntry(
            name: name,
            path: path,
            isDirectory: info.isDirectory,
            isSymlink: isSymlink(path),
            size: info.size,
            modified: info.modified,
            created: info.created,
            kind: FileKinds.kind(name, isDirectory: info.isDirectory),
            hidden: name.hasPrefix(".")
        )
    }

    // MARK: - Listing

    static func readDirectory(_ target: String) throws -> DirListing {
        let resolved = URL(fileURLWithPath: target).standardizedFileURL.path
        let names = try FileManager.default.contentsOfDirectory(atPath: resolved)
        let collector = EntryCollector(count: names.count)

        var index = 0
        while index < names.count {
            let start = index
            let end = min(index + batchSize, names.count)
            DispatchQueue.concurrentPerform(iterations: end - start) { offset in
                let i = start + offset
                let name = names[i]
                let fullPath = (resolved as NSString).appendingPathComponent(name)
                collector.set(entry(name: name, path: fullPath), at: i)
            }
            index = end
        }

        let parent = resolved == "/" ? nil : PathTools.dirname(resolved)
        return DirListing(path: resolved, parent: parent, entries: collector.all())
    }

    // MARK: - Search

    static func search(
        root: String,
        query: String,
        showHidden: Bool,
        limit: Int = 250
    ) -> SearchResponse {
        let start = URL(fileURLWithPath: root).standardizedFileURL.path
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let deadline = Date().addingTimeInterval(6)
        var stack: [(path: String, depth: Int)] = [(start, 0)]
        var results: [FileEntry] = []
        var truncated = false

        while let current = stack.popLast(), results.count < limit {
            if Date() > deadline {
                truncated = true
                break
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { continue }
            for name in names {
                if Date() > deadline {
                    truncated = true
                    break
                }
                if !showHidden && name.hasPrefix(".") { continue }
                let fullPath = (current.path as NSString).appendingPathComponent(name)
                guard let info = statInfo(fullPath) else { continue }
                if needle.isEmpty || name.lowercased().contains(needle) {
                    if let entry = entry(name: name, path: fullPath) {
                        results.append(entry)
                        if results.count >= limit {
                            truncated = true
                            break
                        }
                    }
                }
                if info.isDirectory,
                   !isSymlink(fullPath),
                   current.depth < 10,
                   !shouldSkipDirectory(name, showHidden: showHidden, isRoot: current.depth == 0) {
                    stack.append((fullPath, current.depth + 1))
                }
            }
        }
        if !stack.isEmpty { truncated = true }
        return SearchResponse(root: start, entries: results, truncated: truncated)
    }

    private static func shouldSkipDirectory(_ name: String, showHidden: Bool, isRoot: Bool) -> Bool {
        if FileKinds.isPackageDirectory(name) { return true }
        if isRoot { return false }
        if !showHidden && name.hasPrefix(".") { return true }
        return FileKinds.searchSkip.contains(name)
    }

    static func gallery(root: String, limit: Int = 160) -> GalleryResponse {
        let start = URL(fileURLWithPath: root).standardizedFileURL.path
        let deadline = Date().addingTimeInterval(6)
        var stack: [(path: String, depth: Int)] = [(start, 0)]
        var images: [FileEntry] = []
        var truncated = false

        while let current = stack.popLast(), images.count < limit {
            if Date() > deadline {
                truncated = true
                break
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { continue }
            for name in names {
                if Date() > deadline {
                    truncated = true
                    break
                }
                if name.hasPrefix(".") { continue }
                let fullPath = (current.path as NSString).appendingPathComponent(name)
                guard let info = statInfo(fullPath) else { continue }
                if info.isDirectory {
                    if current.depth < 6,
                       !FileKinds.searchSkip.contains(name),
                       !FileKinds.isPackageDirectory(name),
                       !isSymlink(fullPath) {
                        stack.append((fullPath, current.depth + 1))
                    }
                    continue
                }
                guard FileKinds.kind(name, isDirectory: false) == .image else { continue }
                if let entry = entry(name: name, path: fullPath) {
                    images.append(entry)
                    if images.count >= limit {
                        truncated = true
                        break
                    }
                }
            }
        }
        if !stack.isEmpty { truncated = true }
        images.sort { $0.modified > $1.modified }
        return GalleryResponse(root: start, entries: images, truncated: truncated)
    }

    // MARK: - Open / reveal / terminal

    static func openPath(_ path: String) -> OpResult {
        let url = URL(fileURLWithPath: path)
        if NSWorkspace.shared.open(url) { return .success(path: path) }
        return .failure("Could not open “\(PathTools.basename(path))”.")
    }

    static func defaultApplication(toOpen path: String) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path))
    }

    static func applications(toOpen path: String) -> [(name: String, url: URL)] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: path))
        var seen = Set<String>()
        var result: [(String, URL)] = []
        for url in urls {
            guard url.pathExtension.lowercased() == "app" else { continue }
            let standardized = url.standardizedFileURL.path
            guard !seen.contains(standardized) else { continue }
            seen.insert(standardized)
            let name = (Bundle(url: url)?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            result.append((name, url))
        }
        return result.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    static func open(_ path: String, withApplicationAt applicationURL: URL) -> OpResult {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
        return .success(path: path)
    }

    static func reveal(_ path: String) -> OpResult {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return .success(path: path)
    }

    static func openTerminal(_ path: String) -> OpResult {
        guard let info = statInfo(path) else { return .failure("This item no longer exists.") }
        let directory = info.isDirectory ? path : PathTools.dirname(path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: terminal, configuration: configuration)
        return .success(path: directory)
    }

    // MARK: - Unique names

    static func uniqueNewPath(dir: String, baseName: String, extension ext: String = "") -> String {
        var candidate = (dir as NSString).appendingPathComponent(baseName + ext)
        var counter = 2
        while exists(candidate) {
            candidate = (dir as NSString).appendingPathComponent("\(baseName) (\(counter))\(ext)")
            counter += 1
        }
        return candidate
    }

    static func uniquePastePath(dir: String, sourceName: String, sourceIsDirectory: Bool) -> String {
        let direct = (dir as NSString).appendingPathComponent(sourceName)
        if !exists(direct) { return direct }
        let ext = sourceIsDirectory ? "" : (sourceName as NSString).pathExtension
        let base = ext.isEmpty ? sourceName : String(sourceName.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = (dir as NSString).appendingPathComponent("\(base) - Copy\(suffix)")
        var counter = 2
        while exists(candidate) {
            candidate = (dir as NSString).appendingPathComponent("\(base) - Copy (\(counter))\(suffix)")
            counter += 1
        }
        return candidate
    }

    // MARK: - Create / rename

    static func createFolder(dir: String, name: String? = nil) -> OpResult {
        let target = uniqueNewPath(dir: dir, baseName: (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "New folder" : name!.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
            return .success(path: target)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func createTextFile(dir: String, name: String? = nil) -> OpResult {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmed.isEmpty
            ? uniqueNewPath(dir: dir, baseName: "New Text Document", extension: ".txt")
            : uniqueNewPath(dir: dir, baseName: trimmed)
        do {
            guard FileManager.default.createFile(atPath: target, contents: Data()) else {
                return .failure("Could not create the file.")
            }
            return .success(path: target)
        }
    }

    static func rename(_ target: String, to newName: String) -> OpResult {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return .failure("Enter a valid name.")
        }
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            return .failure("A name can’t contain a slash.")
        }
        let parent = PathTools.dirname(target)
        let destination = (parent as NSString).appendingPathComponent(trimmed)
        if destination == target { return .success(path: target) }
        let caseOnlyChange = destination.lowercased() == target.lowercased()
        if exists(destination), !isSameFile(target, destination) {
            return .failure("There is already a file with the same name in this location.")
        }
        do {
            if caseOnlyChange {
                let temp = (parent as NSString).appendingPathComponent(".macexplorer-rename-\(UUID().uuidString)")
                try FileManager.default.moveItem(atPath: target, toPath: temp)
                do {
                    try FileManager.default.moveItem(atPath: temp, toPath: destination)
                } catch {
                    try? FileManager.default.moveItem(atPath: temp, toPath: target)
                    throw error
                }
            } else {
                try FileManager.default.moveItem(atPath: target, toPath: destination)
            }
            return .success(path: destination)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Trash / delete

    static func trash(_ targets: [String]) -> OpResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var count = 0
        var errors: [String] = []
        for target in targets {
            let resolved = URL(fileURLWithPath: target).standardizedFileURL.path
            let components = resolved.split(separator: "/")
            if resolved == "/" || resolved == home || components.count < 2 {
                errors.append("\(PathTools.basename(target)): refusing to move this location to the Trash")
                continue
            }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: &resulting)
                count += 1
            } catch {
                errors.append("\(PathTools.basename(target)): \(error.localizedDescription)")
            }
        }
        return OpResult(ok: errors.isEmpty, error: errors.isEmpty ? nil : errors.joined(separator: " · "),
                        path: nil, paths: nil, count: count)
    }

    static func remove(_ targets: [String]) -> OpResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var count = 0
        var errors: [String] = []
        for target in targets {
            let resolved = URL(fileURLWithPath: target).standardizedFileURL.path
            let components = resolved.split(separator: "/")
            if resolved == "/" || resolved == home || components.count < 2 {
                errors.append("\(PathTools.basename(target)): refusing to permanently delete this location")
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: resolved)
                count += 1
            } catch {
                errors.append("\(PathTools.basename(target)): \(error.localizedDescription)")
            }
        }
        return OpResult(ok: errors.isEmpty, error: errors.isEmpty ? nil : errors.joined(separator: " · "),
                        path: nil, paths: nil, count: count)
    }

    // MARK: - Copy / move

    private static func isCrossDevice(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EXDEV) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EXDEV)
        }
        return false
    }

    private static func copyItem(from source: String, to destination: String) throws {
        try FileManager.default.copyItem(atPath: source, toPath: destination)
    }

    private static func moveItem(from source: String, to destination: String) throws {
        do {
            try FileManager.default.moveItem(atPath: source, toPath: destination)
        } catch {
            guard isCrossDevice(error) else { throw error }
            try copyItem(from: source, to: destination)
            do {
                try FileManager.default.removeItem(atPath: source)
            } catch {
                try? FileManager.default.removeItem(atPath: destination)
                throw error
            }
        }
    }

    struct PastePlan: Sendable {
        var sources: [String]
        var cut: Bool
        var internalSource: Bool
    }

    static func paste(plan: PastePlan, into dir: String) -> PasteOutcome {
        let targetRoot = URL(fileURLWithPath: dir).standardizedFileURL.path
        var created: [String] = []
        var errors: [String] = []
        var remaining: [String] = []

        for source in plan.sources {
            let resolved = URL(fileURLWithPath: source).standardizedFileURL.path
            guard exists(resolved) else {
                errors.append("\(PathTools.basename(source)): no longer exists")
                continue
            }
            let isDirectory = statInfo(resolved)?.isDirectory ?? false
            if isDirectory && targetRoot.hasPrefix(resolved + "/") {
                errors.append("\(PathTools.basename(source)): can’t paste a folder into itself")
                remaining.append(source)
                continue
            }
            let destination = uniquePastePath(dir: targetRoot, sourceName: PathTools.basename(resolved), sourceIsDirectory: isDirectory)
            do {
                if plan.cut {
                    try moveItem(from: source, to: destination)
                } else {
                    try copyItem(from: source, to: destination)
                }
                created.append(destination)
            } catch {
                errors.append("\(PathTools.basename(source)): \(error.localizedDescription)")
                remaining.append(source)
            }
        }

        let result = OpResult(
            ok: errors.isEmpty,
            error: errors.isEmpty ? nil : errors.joined(separator: " · "),
            path: nil,
            paths: created,
            count: created.count
        )
        return PasteOutcome(result: result, remainingSources: remaining)
    }

    static func transfer(_ sources: [String], to destination: String, copy: Bool) -> OpResult {
        let destinationRoot = URL(fileURLWithPath: destination).standardizedFileURL.path
        guard let destinationInfo = statInfo(destinationRoot), destinationInfo.isDirectory else {
            return .failure("The destination folder no longer exists.")
        }

        var created: [String] = []
        var errors: [String] = []

        for source in sources {
            let resolved = URL(fileURLWithPath: source).standardizedFileURL.path
            if resolved == destinationRoot { continue }
            if !copy && PathTools.dirname(resolved) == destinationRoot { continue }
            guard let info = statInfo(resolved) else {
                errors.append("\(PathTools.basename(source)): no longer exists")
                continue
            }
            if info.isDirectory && destinationRoot.hasPrefix(resolved + "/") {
                errors.append("\(PathTools.basename(source)): can’t move a folder into itself")
                continue
            }
            let target = uniquePastePath(
                dir: destinationRoot,
                sourceName: PathTools.basename(resolved),
                sourceIsDirectory: info.isDirectory
            )
            do {
                if copy {
                    try copyItem(from: resolved, to: target)
                } else {
                    try moveItem(from: resolved, to: target)
                }
                created.append(target)
            } catch {
                errors.append("\(PathTools.basename(source)): \(error.localizedDescription)")
            }
        }

        return OpResult(ok: errors.isEmpty, error: errors.isEmpty ? nil : errors.joined(separator: " · "),
                        path: nil, paths: created, count: created.count)
    }

    // MARK: - Properties

    private static func folderTotals(_ target: String) -> (size: Int64, files: Int, folders: Int) {
        let deadline = Date().addingTimeInterval(2.5)
        var stack = [target]
        var size: Int64 = 0
        var files = 0
        var folders = 0
        var inspected = 0

        while let current = stack.popLast(), Date() < deadline, inspected < 20_000 {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for name in names {
                inspected += 1
                if inspected >= 20_000 { break }
                let fullPath = (current as NSString).appendingPathComponent(name)
                if isSymlink(fullPath) { continue }
                guard let info = statInfo(fullPath) else { continue }
                if info.isDirectory {
                    folders += 1
                    stack.append(fullPath)
                } else {
                    size += info.size
                    files += 1
                }
            }
        }
        return (size, files, folders)
    }

    static func properties(_ targets: [String]) -> PropertiesResult {
        let empty = PropertiesResult(
            ok: false, error: "No selection.", name: "", type: "", location: "", size: 0, sizeOnDisk: 0,
            files: 0, folders: 0, created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            isDirectory: false, isSymlink: false, path: "", multiple: false
        )
        guard !targets.isEmpty else { return empty }

        let multiple = targets.count > 1
        var totalSize: Int64 = 0
        var files = 0
        var folders = 0
        var created = Date.distantFuture
        var modified = Date(timeIntervalSince1970: 0)
        var hasDirectory = false
        var hasSymlink = false

        for target in targets {
            guard let info = statInfo(target) else {
                var failure = empty
                failure.error = "This item no longer exists."
                failure.path = target
                failure.multiple = multiple
                return failure
            }
            hasDirectory = hasDirectory || info.isDirectory
            hasSymlink = hasSymlink || isSymlink(target)
            created = min(created, info.created)
            modified = max(modified, info.modified)
            if info.isDirectory {
                let totals = folderTotals(target)
                totalSize += totals.size
                files += totals.files
                folders += totals.folders + 1
            } else {
                totalSize += info.size
                files += 1
            }
        }

        if multiple {
            let parents = Set(targets.map { PathTools.dirname($0) })
            return PropertiesResult(
                ok: true, error: nil, name: "\(targets.count) items", type: "Multiple items",
                location: parents.count == 1 ? parents.first! : "Multiple locations",
                size: totalSize, sizeOnDisk: totalSize, files: files, folders: folders,
                created: created == .distantFuture ? Date(timeIntervalSince1970: 0) : created,
                modified: modified, isDirectory: hasDirectory, isSymlink: hasSymlink,
                path: targets[0], multiple: true
            )
        }

        let target = targets[0]
        let name = PathTools.basename(target)
        return PropertiesResult(
            ok: true, error: nil, name: name.isEmpty ? target : name,
            type: FileKinds.typeLabel(name, hasDirectory), location: PathTools.dirname(target),
            size: totalSize, sizeOnDisk: totalSize, files: files, folders: hasDirectory ? folders : 0,
            created: created == .distantFuture ? Date(timeIntervalSince1970: 0) : created,
            modified: modified, isDirectory: hasDirectory, isSymlink: hasSymlink,
            path: target, multiple: false
        )
    }

    // MARK: - System info

    private static func volumeInfo(path: String, name: String) -> Volume? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path) else { return nil }
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return Volume(name: name, path: path, total: total, free: free)
    }

    private static func localHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return "localhost"
    }

    static func systemInfo() -> SystemInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [SpecialFolder] = [
            SpecialFolder(key: "desktop", label: "Desktop", path: home + "/Desktop"),
            SpecialFolder(key: "downloads", label: "Downloads", path: home + "/Downloads"),
            SpecialFolder(key: "documents", label: "Documents", path: home + "/Documents"),
            SpecialFolder(key: "pictures", label: "Pictures", path: home + "/Pictures"),
            SpecialFolder(key: "music", label: "Music", path: home + "/Music"),
            SpecialFolder(key: "videos", label: "Movies", path: home + "/Movies"),
            SpecialFolder(key: "applications", label: "Applications", path: "/Applications"),
            SpecialFolder(key: "trash", label: "Trash", path: home + "/.Trash"),
        ]

        return SystemInfo(
            home: home,
            username: NSUserName(),
            hostname: localHostName(),
            trashPath: home + "/.Trash",
            specialFolders: candidates.filter { exists($0.path) },
            volumes: volumeList()
        )
    }

    static func volumeList() -> [Volume] {
        var volumes: [Volume] = []
        let rootName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        if let root = volumeInfo(path: "/", name: rootName) { volumes.append(root) }

        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                if name.hasPrefix(".") { continue }
                let volumePath = "/Volumes/" + name
                guard let info = statInfo(volumePath), info.isDirectory else { continue }
                let resolved = URL(fileURLWithPath: volumePath).resolvingSymlinksInPath().path
                if resolved == "/" { continue }
                if let volume = volumeInfo(path: volumePath, name: name) { volumes.append(volume) }
            }
        }
        return volumes.filter { $0.name.caseInsensitiveCompare("Recovery") != .orderedSame }
    }

    static func isEjectableVolume(path: String) -> Bool {
        guard path != "/" else { return false }
        var unmountable: ObjCBool = false
        if NSWorkspace.shared.getFileSystemInfo(
            forPath: path,
            isRemovable: nil,
            isWritable: nil,
            isUnmountable: &unmountable,
            description: nil,
            type: nil
        ) {
            return unmountable.boolValue
        }
        return path.hasPrefix("/Volumes/")
    }

    static func ejectVolume(at path: String) -> OpResult {
        guard path != "/" else { return .failure("The startup disk can’t be ejected.") }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
            return .success(path: path)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
