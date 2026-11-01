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
    // MARK: - Trash restore origins

    private static let restoreOriginsLock = NSLock()
    private nonisolated(unsafe) static var restoreOriginsCache: [String: String]?

    private static func restoreOriginsURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = support.appendingPathComponent("Mac Explorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("trash-origins.json")
    }

    private static func loadRestoreOrigins() -> [String: String] {
        restoreOriginsLock.lock()
        defer { restoreOriginsLock.unlock() }
        if let cache = restoreOriginsCache { return cache }
        let url = restoreOriginsURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            restoreOriginsCache = [:]
            return [:]
        }
        // Drop entries for items that left the Trash outside this app (e.g. emptied in Finder).
        let pruned = decoded.filter { FileManager.default.fileExists(atPath: $0.key) }
        if pruned.count != decoded.count, let encoded = try? JSONEncoder().encode(pruned) {
            try? encoded.write(to: url, options: .atomic)
        }
        restoreOriginsCache = pruned
        return pruned
    }

    private static func saveRestoreOrigins(_ map: [String: String]) {
        restoreOriginsLock.lock()
        restoreOriginsCache = map
        restoreOriginsLock.unlock()
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: restoreOriginsURL(), options: .atomic)
        }
    }

    // MARK: - Stat helpers

    struct StatInfo {
        var isDirectory: Bool
        var size: Int64
        var modified: Date
        var created: Date
        var isSymlink: Bool = false
        var allocated: Int64 = 0
        var linkCount: Int = 1
        var device: Int64 = 0
        var inode: UInt64 = 0
    }

    /// `followSymlinks: false` uses lstat, so a symlink reports itself (isSymlink == true).
    static func statInfo(_ path: String, followSymlinks: Bool = true) -> StatInfo? {
        var info = stat()
        let status: Int32 = path.withCString { cPath in
            if followSymlinks { return stat(cPath, &info) }
            return lstat(cPath, &info)
        }
        guard status == 0 else { return nil }
        let modified = Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let created = Date(
            timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000
        )
        let type = info.st_mode & S_IFMT
        let isDirectory = type == S_IFDIR
        return StatInfo(
            isDirectory: isDirectory,
            size: isDirectory ? 0 : Int64(info.st_size),
            modified: modified,
            created: created,
            isSymlink: type == S_IFLNK,
            allocated: Int64(info.st_blocks) * 512,
            linkCount: Int(info.st_nlink),
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    static func isSymlink(_ path: String) -> Bool {
        statInfo(path, followSymlinks: false)?.isSymlink ?? false
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
        guard let link = statInfo(path, followSymlinks: false) else { return nil }
        return makeEntry(name: name, path: path, link: link)
    }

    /// Builds an entry from an lstat result; only symlinks pay for a second (following) stat.
    private static func makeEntry(name: String, path: String, link: StatInfo) -> FileEntry {
        let info = link.isSymlink ? (statInfo(path) ?? link) : link
        return FileEntry(
            name: name,
            path: path,
            isDirectory: info.isDirectory,
            isSymlink: link.isSymlink,
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

        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            let name = names[i]
            let fullPath = (resolved as NSString).appendingPathComponent(name)
            collector.set(entry(name: name, path: fullPath), at: i)
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
        // Breadth-first so shallow matches are found before the result limit is hit.
        var queue: [(path: String, depth: Int)] = [(start, 0)]
        var head = 0
        var results: [FileEntry] = []
        var truncated = false

        scan: while head < queue.count, results.count < limit {
            if Task.isCancelled || Date() > deadline {
                truncated = true
                break
            }
            let current = queue[head]
            head += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { continue }
            for (offset, name) in names.enumerated() {
                if offset & 63 == 63, Task.isCancelled || Date() > deadline {
                    truncated = true
                    break scan
                }
                if !showHidden && name.hasPrefix(".") { continue }
                let fullPath = (current.path as NSString).appendingPathComponent(name)
                guard let link = statInfo(fullPath, followSymlinks: false) else { continue }
                if needle.isEmpty || name.lowercased().contains(needle) {
                    results.append(makeEntry(name: name, path: fullPath, link: link))
                    if results.count >= limit {
                        truncated = true
                        break scan
                    }
                }
                // lstat: symlinked directories report isDirectory == false and are not followed.
                if link.isDirectory,
                   current.depth < 10,
                   !shouldSkipDirectory(name, path: fullPath, showHidden: showHidden, isRoot: current.depth == 0) {
                    queue.append((fullPath, current.depth + 1))
                }
            }
        }
        if head < queue.count { truncated = true }
        return SearchResponse(root: start, entries: results, truncated: truncated)
    }

    private static func shouldSkipDirectory(_ name: String, path: String, showHidden: Bool, isRoot: Bool) -> Bool {
        if FileKinds.isPackageDirectory(name) { return true }
        if FileKinds.isSkippedSystemPath(path) { return true }
        if isRoot { return false }
        if !showHidden && name.hasPrefix(".") { return true }
        return FileKinds.searchSkip.contains(name)
    }

    static func gallery(root: String, limit: Int = 160) -> GalleryResponse {
        let start = URL(fileURLWithPath: root).standardizedFileURL.path
        let deadline = Date().addingTimeInterval(6)
        var queue: [(path: String, depth: Int)] = [(start, 0)]
        var head = 0
        var images: [FileEntry] = []
        var truncated = false

        scan: while head < queue.count, images.count < limit {
            if Task.isCancelled || Date() > deadline {
                truncated = true
                break
            }
            let current = queue[head]
            head += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { continue }
            for (offset, name) in names.enumerated() {
                if offset & 63 == 63, Task.isCancelled || Date() > deadline {
                    truncated = true
                    break scan
                }
                if name.hasPrefix(".") { continue }
                let fullPath = (current.path as NSString).appendingPathComponent(name)
                guard let link = statInfo(fullPath, followSymlinks: false) else { continue }
                if link.isDirectory {
                    if current.depth < 6,
                       !FileKinds.searchSkip.contains(name),
                       !FileKinds.isPackageDirectory(name),
                       !FileKinds.isSkippedSystemPath(fullPath) {
                        queue.append((fullPath, current.depth + 1))
                    }
                    continue
                }
                guard FileKinds.kind(name, isDirectory: false) == .image else { continue }
                let entry = makeEntry(name: name, path: fullPath, link: link)
                guard !entry.isDirectory else { continue }
                images.append(entry)
                if images.count >= limit {
                    truncated = true
                    break scan
                }
            }
        }
        if head < queue.count { truncated = true }
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

    struct TrashReceipt: Sendable {
        var result: OpResult
        var items: [DeletedItem]
    }

    static func trash(_ targets: [String]) -> OpResult {
        trashWithReceipt(targets).result
    }

    static func trashWithReceipt(_ targets: [String]) -> TrashReceipt {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var count = 0
        var errors: [String] = []
        var deleted: [DeletedItem] = []
        var origins = loadRestoreOrigins()
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
                let destination = resulting?.path ?? (home + "/.Trash/" + PathTools.basename(resolved))
                origins[destination] = PathTools.dirname(resolved)
                deleted.append(
                    DeletedItem(
                        trashPath: destination,
                        originDir: PathTools.dirname(resolved),
                        name: PathTools.basename(resolved),
                        date: Date()
                    )
                )
                count += 1
            } catch {
                errors.append("\(PathTools.basename(target)): \(error.localizedDescription)")
            }
        }
        if !deleted.isEmpty { saveRestoreOrigins(origins) }
        let result = OpResult(
            ok: errors.isEmpty,
            error: errors.isEmpty ? nil : errors.joined(separator: " · "),
            path: nil,
            paths: deleted.map(\.trashPath),
            count: count
        )
        return TrashReceipt(result: result, items: deleted)
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
            if plan.cut && (resolved == targetRoot || PathTools.dirname(resolved) == targetRoot) {
                continue
            }
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

    private struct FolderTotals {
        var size: Int64 = 0
        var allocated: Int64 = 0
        var files = 0
        var folders = 0
        var truncated = false
    }

    private static func folderTotals(_ target: String) -> FolderTotals {
        let deadline = Date().addingTimeInterval(2.5)
        let maxItems = 20_000
        var stack = [target]
        var totals = FolderTotals()
        var inspected = 0
        var seenHardLinks = Set<String>()

        walk: while let current = stack.popLast() {
            if Date() >= deadline || inspected >= maxItems {
                totals.truncated = true
                break
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for name in names {
                inspected += 1
                if inspected >= maxItems {
                    totals.truncated = true
                    break walk
                }
                let fullPath = (current as NSString).appendingPathComponent(name)
                guard let info = statInfo(fullPath, followSymlinks: false), !info.isSymlink else { continue }
                if info.isDirectory {
                    totals.folders += 1
                    stack.append(fullPath)
                } else {
                    totals.files += 1
                    if info.linkCount > 1 {
                        let key = "\(info.device):\(info.inode)"
                        if !seenHardLinks.insert(key).inserted { continue }
                    }
                    totals.size += info.size
                    totals.allocated += info.allocated
                }
            }
        }
        if !stack.isEmpty { totals.truncated = true }
        return totals
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
        var totalAllocated: Int64 = 0
        var truncated = false
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
            if !info.isDirectory { totalAllocated += info.allocated }
            created = min(created, info.created)
            modified = max(modified, info.modified)
            if info.isDirectory {
                let totals = folderTotals(target)
                totalSize += totals.size
                totalAllocated += totals.allocated
                truncated = truncated || totals.truncated
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
                size: totalSize, sizeOnDisk: totalAllocated, files: files, folders: folders,
                created: created == .distantFuture ? Date(timeIntervalSince1970: 0) : created,
                modified: modified, isDirectory: hasDirectory, isSymlink: hasSymlink,
                path: targets[0], multiple: true, truncated: truncated
            )
        }

        let target = targets[0]
        let name = PathTools.basename(target)
        return PropertiesResult(
            ok: true, error: nil, name: name.isEmpty ? target : name,
            type: FileKinds.typeLabel(name, hasDirectory), location: PathTools.dirname(target),
            size: totalSize, sizeOnDisk: totalAllocated, files: files, folders: hasDirectory ? folders : 0,
            created: created == .distantFuture ? Date(timeIntervalSince1970: 0) : created,
            modified: modified, isDirectory: hasDirectory, isSymlink: hasSymlink,
            path: target, multiple: false, truncated: truncated
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

    // MARK: - Trash restore / empty

    static func restoreItems(_ targets: [String]) -> OpResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var count = 0
        var errors: [String] = []
        var origins = loadRestoreOrigins()
        for target in targets {
            let resolved = URL(fileURLWithPath: target).standardizedFileURL.path
            guard FileService.exists(resolved) else {
                errors.append("\(PathTools.basename(target)): no longer exists")
                continue
            }
            let origin = origins[resolved] ?? home
            let destinationParent = (origin.isEmpty || origin == (home + "/.Trash")) ? home : origin
            guard let info = statInfo(destinationParent), info.isDirectory else {
                errors.append("\(PathTools.basename(target)): original location unavailable")
                continue
            }
            let isDirectory = statInfo(resolved)?.isDirectory ?? false
            let destination = uniquePastePath(dir: destinationParent, sourceName: PathTools.basename(resolved), sourceIsDirectory: isDirectory)
            do {
                try moveItem(from: resolved, to: destination)
                origins.removeValue(forKey: resolved)
                count += 1
            } catch {
                errors.append("\(PathTools.basename(target)): \(error.localizedDescription)")
            }
        }
        saveRestoreOrigins(origins)
        return OpResult(ok: errors.isEmpty, error: errors.isEmpty ? nil : errors.joined(separator: " · "),
                        path: nil, paths: nil, count: count)
    }

    static func emptyTrashBin(at trashPath: String? = nil) -> OpResult {
        let path = trashPath ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return .failure("Could not read the Trash.")
        }
        var count = 0
        var errors: [String] = []
        var origins = loadRestoreOrigins()
        for name in names {
            let target = (path as NSString).appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(atPath: target)
                origins.removeValue(forKey: target)
                count += 1
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        saveRestoreOrigins(origins)
        return OpResult(ok: errors.isEmpty, error: errors.isEmpty ? nil : errors.joined(separator: " · "),
                        path: nil, paths: nil, count: count)
    }

    // MARK: - Compress

    private static func commonAncestor(_ paths: [String]) -> String {
        var common = paths[0].split(separator: "/").map(String.init)
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            var count = 0
            while count < min(common.count, parts.count), common[count] == parts[count] { count += 1 }
            common = Array(common.prefix(count))
        }
        return "/" + common.joined(separator: "/")
    }

    static func compressToArchive(_ sources: [String], destinationParent: String? = nil) -> OpResult {
        let resolvedSources = sources.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard !resolvedSources.isEmpty else { return .failure("Nothing to compress.") }
        let parents = resolvedSources.map { PathTools.dirname($0) }
        let allSameParent = parents.allSatisfy { $0 == parents[0] }
        let parent = destinationParent ?? (allSameParent ? parents[0] : PathTools.dirname(resolvedSources[0]))
        guard let parentInfo = statInfo(parent), parentInfo.isDirectory else {
            return .failure("The destination folder no longer exists.")
        }

        let baseName: String
        if resolvedSources.count == 1 {
            let name = PathTools.basename(resolvedSources[0])
            let ext = (name as NSString).pathExtension
            baseName = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        } else {
            baseName = "Archive"
        }
        let archivePath = uniqueNewPath(dir: parent, baseName: baseName.isEmpty ? "Archive" : baseName, extension: ".zip")

        let process = Process()
        if resolvedSources.count == 1 {
            // Same as Finder's Compress: keeps extended attributes and resource forks.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", resolvedSources[0], archivePath]
        } else {
            // Store paths relative to the shared ancestor rather than absolute paths,
            // and keep symlinks as links (-y) instead of following them.
            let base = allSameParent ? parents[0] : commonAncestor(parents)
            let relative = resolvedSources.map { path -> String in
                base == "/" ? String(path.dropFirst()) : String(path.dropFirst(base.count + 1))
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = URL(fileURLWithPath: base)
            process.arguments = ["-r", "-y", "-q", archivePath] + relative
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }
        // Read to EOF before waiting so a chatty tool can't block on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            try? FileManager.default.removeItem(atPath: archivePath)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(trimmed.isEmpty ? "Could not create the archive." : trimmed)
        }
        return .success(path: archivePath)
    }

}
