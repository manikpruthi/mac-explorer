import CryptoKit
import Foundation

struct DuplicateGroup: Sendable, Hashable {
    let size: Int64
    /// Sorted so the shortest (usually the "original") path comes first.
    let paths: [String]

    var wastedBytes: Int64 { size * Int64(max(0, paths.count - 1)) }
}

struct DuplicateScanResult: Sendable {
    let root: String
    let groups: [DuplicateGroup]
    let scannedFiles: Int
    let truncated: Bool

    var wastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
}

enum DuplicateFinder {
    enum Phase: Sendable {
        case scanning(files: Int)
        case comparing(done: Int, total: Int)
    }

    /// Finds files with identical contents under `root`.
    ///
    /// Memory stays bounded: only (path, size) pairs are kept, files are bucketed by size, and only
    /// same-size candidates are read — first a 16 KB head hash, then a full SHA-256 streamed through
    /// one reused 1 MB buffer. Hard links to the same inode are not reported as duplicates.
    static func scan(
        root: String,
        showHidden: Bool,
        minSize: Int64 = 1,
        maxFiles: Int = 200_000,
        deadline: TimeInterval = 120,
        progress: (@Sendable (Phase) -> Void)? = nil
    ) -> DuplicateScanResult {
        let start = URL(fileURLWithPath: root).standardizedFileURL.path
        let stopAt = Date().addingTimeInterval(deadline)
        var truncated = false
        var scanned = 0
        var bySize: [Int64: [String]] = [:]
        var seenInodes = Set<UInt64>()
        var stack = [start]

        walk: while let current = stack.popLast() {
            if Task.isCancelled || Date() >= stopAt {
                truncated = true
                break
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for name in names {
                if Task.isCancelled || Date() > stopAt || scanned >= maxFiles {
                    truncated = true
                    break walk
                }
                if !showHidden && name.hasPrefix(".") { continue }
                let path = (current as NSString).appendingPathComponent(name)
                var info = stat()
                guard path.withCString({ lstat($0, &info) }) == 0 else { continue }
                let type = info.st_mode & S_IFMT
                if type == S_IFDIR {
                    if FileKinds.isPackageDirectory(name) || FileKinds.isSkippedSystemPath(path)
                        || FileKinds.searchSkip.contains(name) {
                        continue
                    }
                    stack.append(path)
                } else if type == S_IFREG {
                    scanned += 1
                    if scanned & 1023 == 0 { progress?(.scanning(files: scanned)) }
                    let size = Int64(info.st_size)
                    guard size >= minSize else { continue }
                    if info.st_nlink > 1 {
                        let key = UInt64(UInt32(bitPattern: info.st_dev)) << 40 ^ UInt64(info.st_ino)
                        if !seenInodes.insert(key).inserted { continue }
                    }
                    bySize[size, default: []].append(path)
                }
            }
        }
        if !stack.isEmpty { truncated = true }

        let candidates = bySize.filter { $0.value.count > 1 }
        bySize = [:]
        let total = candidates.reduce(0) { $0 + $1.value.count }
        var done = 0
        var groups: [DuplicateGroup] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 20)

        compare: for (size, paths) in candidates.sorted(by: { $0.key > $1.key }) {
            if Task.isCancelled || Date() >= stopAt {
                truncated = true
                break
            }
            var byHead: [Data: [String]] = [:]
            for path in paths {
                if Task.isCancelled || Date() >= stopAt {
                    truncated = true
                    break compare
                }
                let digest = hash(path, limit: 16 * 1024, stopAt: stopAt, buffer: &buffer)
                if Task.isCancelled || Date() >= stopAt {
                    truncated = true
                    break compare
                }
                if let digest {
                    byHead[digest, default: []].append(path)
                }
                done += 1
                if done & 63 == 0 { progress?(.comparing(done: done, total: total)) }
            }
            for (_, sameHead) in byHead where sameHead.count > 1 {
                if Task.isCancelled || Date() >= stopAt {
                    truncated = true
                    break compare
                }
                // Small files were read completely by the head hash.
                if size <= 16 * 1024 {
                    groups.append(DuplicateGroup(size: size, paths: ordered(sameHead)))
                    continue
                }
                var byFull: [Data: [String]] = [:]
                for path in sameHead {
                    if Task.isCancelled || Date() >= stopAt {
                        truncated = true
                        break compare
                    }
                    let digest = hash(path, limit: nil, stopAt: stopAt, buffer: &buffer)
                    if Task.isCancelled || Date() >= stopAt {
                        truncated = true
                        break compare
                    }
                    if let digest {
                        byFull[digest, default: []].append(path)
                    }
                }
                for (_, same) in byFull where same.count > 1 {
                    if Task.isCancelled || Date() >= stopAt {
                        truncated = true
                        break compare
                    }
                    groups.append(DuplicateGroup(size: size, paths: ordered(same)))
                }
            }
        }
        groups.sort { $0.wastedBytes == $1.wastedBytes ? $0.paths[0] < $1.paths[0] : $0.wastedBytes > $1.wastedBytes }
        truncated = truncated || Task.isCancelled || Date() >= stopAt
        return DuplicateScanResult(root: start, groups: groups, scannedFiles: scanned, truncated: truncated)
    }

    private static func ordered(_ paths: [String]) -> [String] {
        paths.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
    }

    private static func hash(_ path: String, limit: Int?, stopAt: Date, buffer: inout [UInt8]) -> Data? {
        guard !Task.isCancelled, Date() < stopAt else { return nil }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            guard !Task.isCancelled, Date() < stopAt else { return nil }
            let want = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            guard !Task.isCancelled, Date() < stopAt else { return nil }
            if count < 0 { return nil }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            remaining -= count
        }
        // Never publish a partial digest when a read or hash crossed the deadline.
        guard !Task.isCancelled, Date() < stopAt else { return nil }
        return Data(hasher.finalize())
    }
}
