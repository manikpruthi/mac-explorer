import CryptoKit
import Foundation

enum ArchiveError: LocalizedError {
    case unsupported
    case missing
    case tooManyEntries
    case unsafePaths
    case tooLarge
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This archive format can’t be browsed."
        case .missing: return "The archive no longer exists."
        case .tooManyEntries: return "This archive has too many entries to browse."
        case .unsafePaths: return "This archive contains unsafe paths."
        case .tooLarge: return "This archive is too large to browse."
        case .tool(let message): return message
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum ArchiveService {
    static let maxEntries = 50_000
    static let maxUncompressedSize: Int64 = 8 * 1024 * 1024 * 1024

    private static func cacheRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mac-explorer-archives", isDirectory: true)
    }

    private static func directorySize(_ root: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
            if total > maxUncompressedSize { return total }
        }
        return total
    }

    private static func cacheKey(_ archivePath: String, size: Int64, modified: Date) -> String {
        let seed = "\(archivePath)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = Insecure.SHA1.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = OutputBuffer()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            buffer.append(fileHandle.availableData)
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            throw ArchiveError.tool(error.localizedDescription)
        }

        let killer = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()

        handle.readabilityHandler = nil
        buffer.append(handle.readDataToEndOfFile())

        let output = String(data: buffer.take(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.tool(trimmed.isEmpty ? "Could not read this archive." : trimmed)
        }
        return output
    }

    static func openArchive(_ archivePath: String) -> ArchiveResult {
        let resolved = URL(fileURLWithPath: archivePath).standardizedFileURL.path
        do {
            let root = try extractToCache(resolved)
            return ArchiveResult(ok: true, archivePath: resolved, extractRoot: root, error: nil)
        } catch {
            return ArchiveResult(
                ok: false,
                archivePath: resolved,
                extractRoot: nil,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private static func extractToCache(_ archivePath: String) throws -> String {
        guard FileKinds.isBrowsableArchive(PathTools.basename(archivePath)) else {
            throw ArchiveError.unsupported
        }
        guard let info = FileService.statInfo(archivePath), !info.isDirectory else {
            throw ArchiveError.missing
        }

        let key = cacheKey(archivePath, size: info.size, modified: info.modified)
        let root = cacheRoot()
        let destination = root.appendingPathComponent(key, isDirectory: true)

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let working = root.appendingPathComponent(
            "\(key).tmp-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 1000))",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: working)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)

        do {
            let listing = try run("/usr/bin/bsdtar", ["-tf", archivePath], timeout: 60)
            let entries = listing
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard entries.count <= maxEntries else { throw ArchiveError.tooManyEntries }
            for entry in entries {
                var normalized = entry.replacingOccurrences(of: "\\", with: "/")
                while normalized.hasPrefix("./") { normalized.removeFirst(2) }
                if normalized.hasPrefix("/") { throw ArchiveError.unsafePaths }
                if normalized.count >= 2,
                   normalized[normalized.index(normalized.startIndex, offsetBy: 1)] == ":",
                   normalized.first?.isLetter == true {
                    throw ArchiveError.unsafePaths
                }
                if normalized.split(separator: "/").contains("..") {
                    throw ArchiveError.unsafePaths
                }
            }

            let verbose = try run("/usr/bin/bsdtar", ["-tvf", archivePath], timeout: 60)
            var uncompressed: Int64 = 0
            for line in verbose.split(separator: "\n", omittingEmptySubsequences: false) {
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard tokens.count >= 5 else { continue }
                if let size = Int64(tokens[4]) {
                    uncompressed += size
                    if uncompressed > maxUncompressedSize { throw ArchiveError.tooLarge }
                }
            }

            _ = try run(
                "/usr/bin/bsdtar",
                ["-xf", archivePath, "-C", working.path, "--no-same-owner", "--no-same-permissions"],
                timeout: 120
            )

            if let extracted = directorySize(working), extracted > maxUncompressedSize {
                throw ArchiveError.tooLarge
            }

            do {
                try FileManager.default.moveItem(at: working, to: destination)
            } catch {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: working)
                    return destination.path
                }
                throw error
            }
            return destination.path
        } catch {
            try? FileManager.default.removeItem(at: working)
            throw error
        }
    }

    static func extractAll(_ archivePath: String, destinationParent: String) -> OpResult {
        let opened = openArchive(archivePath)
        guard opened.ok, let extractRoot = opened.extractRoot else {
            return .failure(opened.error ?? "Could not read this archive.")
        }
        guard let parentInfo = FileService.statInfo(destinationParent), parentInfo.isDirectory else {
            return .failure("The destination is not a folder.")
        }
        let name = FileKinds.archiveFolderName(PathTools.basename(archivePath))
        let target = FileService.uniqueNewPath(dir: destinationParent, baseName: name.isEmpty ? "Extracted archive" : name)
        do {
            try FileManager.default.copyItem(atPath: extractRoot, toPath: target)
            return .success(path: target)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func cleanup(maxAge: TimeInterval = 7 * 24 * 60 * 60) {
        let root = cacheRoot()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for name in names {
            let target = root.appendingPathComponent(name)
            guard let values = try? target.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: target)
        }
    }
}
