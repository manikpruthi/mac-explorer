import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
        if condition() {
            passes += 1
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name) \(detail.isEmpty ? "" : "— \(detail)")")
        }
    }

    private static func runProcess(_ tool: String, _ arguments: [String], cwd: URL? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func run() -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mac-explorer-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let alpha = root.appendingPathComponent("Alpha")
        try? fm.createDirectory(at: alpha, withIntermediateDirectories: true)
        try? Data("hello".utf8).write(to: root.appendingPathComponent("note.txt"))
        try? fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? Data("beta".utf8).write(to: root.appendingPathComponent("sub/Beta.txt"))
        try? fm.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try? Data().write(to: root.appendingPathComponent("node_modules/Hidden.txt"))
        try? fm.createDirectory(at: root.appendingPathComponent("sub/node_modules"), withIntermediateDirectories: true)
        try? Data().write(to: root.appendingPathComponent("sub/node_modules/Deep.txt"))

        if let listing = try? FileService.readDirectory(root.path) {
            check("readDirectory returns all entries", listing.entries.count == 4, "\(listing.entries.count)")
            check("readDirectory classifies folders", listing.entries.first(where: { $0.name == "Alpha" })?.isDirectory == true)
            check("readDirectory classifies text", listing.entries.first(where: { $0.name == "note.txt" })?.kind == .text)
            check("readDirectory parent", listing.parent == PathTools.dirname(root.path))
        } else {
            check("readDirectory returns listing", false)
        }

        let sorted = sortEntries(
            [
                FileEntry(name: "b.txt", path: "/tmp/b.txt", isDirectory: false, isSymlink: false, size: 20,
                          modified: Date(), created: Date(), kind: .text, hidden: false),
                FileEntry(name: "A", path: "/tmp/A", isDirectory: true, isSymlink: false, size: 0,
                          modified: Date(), created: Date(), kind: .folder, hidden: false),
                FileEntry(name: "a.txt", path: "/tmp/a.txt", isDirectory: false, isSymlink: false, size: 10,
                          modified: Date(), created: Date(), kind: .text, hidden: false),
            ],
            key: .name,
            dir: .asc,
            showExtensions: true
        )
        check("sort is folder-first and numeric-aware", sorted.map(\.name) == ["A", "a.txt", "b.txt"], "\(sorted.map(\.name))")

        let search = FileService.search(root: root.path, query: "beta", showHidden: false)
        check("search finds nested files", search.entries.contains(where: { $0.name == "Beta.txt" }))
        let skipped = FileService.search(root: root.path, query: "deep", showHidden: false)
        check("search skips nested node_modules", skipped.entries.isEmpty, "\(skipped.entries.map(\.name))")
        let direct = FileService.search(root: root.path, query: "hidden", showHidden: false)
        check("search traverses root-level children", direct.entries.contains(where: { $0.name == "Hidden.txt" }))

        let folder1 = FileService.createFolder(dir: root.path)
        let folder2 = FileService.createFolder(dir: root.path)
        check("unique folder names", PathTools.basename(folder1.path ?? "") == "New folder"
              && PathTools.basename(folder2.path ?? "") == "New folder (2)",
              "\(folder1.path ?? "nil") / \(folder2.path ?? "nil")")

        let text = FileService.createTextFile(dir: root.path)
        check("new text document", PathTools.basename(text.path ?? "") == "New Text Document.txt")

        let renamed = FileService.rename(root.appendingPathComponent("note.txt").path, to: "renamed.txt")
        check("rename", renamed.ok && FileService.exists(root.appendingPathComponent("renamed.txt").path))

        let blockedRename = FileService.rename(root.appendingPathComponent("renamed.txt").path, to: "sub")
        check("rename refuses collision", !blockedRename.ok)

        try? Data("case".utf8).write(to: root.appendingPathComponent("casecheck.txt"))
        let caseRename = FileService.rename(root.appendingPathComponent("casecheck.txt").path, to: "CaseCheck.txt")
        check("case-only rename", caseRename.ok && FileService.exists(root.appendingPathComponent("CaseCheck.txt").path))

        let copied = FileService.transfer([root.appendingPathComponent("renamed.txt").path], to: alpha.path, copy: true)
        check("copy into folder", copied.ok && FileService.exists(alpha.appendingPathComponent("renamed.txt").path))

        let copiedAgain = FileService.transfer([root.appendingPathComponent("renamed.txt").path], to: alpha.path, copy: true)
        check("copy conflict uses unique name", copiedAgain.ok
              && FileService.exists(alpha.appendingPathComponent("renamed - Copy.txt").path))

        let movedSource = root.appendingPathComponent("moved.txt")
        try? Data("move".utf8).write(to: movedSource)
        let pasteOutcome = FileService.paste(
            plan: FileService.PastePlan(sources: [movedSource.path], cut: true, internalSource: true),
            into: alpha.path
        )
        check("cut paste moves", pasteOutcome.result.ok
              && !FileService.exists(movedSource.path)
              && FileService.exists(alpha.appendingPathComponent("moved.txt").path))

        let properties = FileService.properties([alpha.path])
        check("properties counts", properties.ok && properties.files >= 2 && properties.isDirectory,
              "\(properties.files) files")

        check("double extension stays visible", !FileKinds.shouldHideExtension("invoice.pdf.exe")
              && !FileKinds.shouldHideExtension("invoice.pdf.png") && FileKinds.shouldHideExtension("photo.png"))
        check("project Library folders are searched", !FileKinds.isSkippedSystemPath(root.appendingPathComponent("Library").path))

        let samePlace = root.appendingPathComponent("stay.txt")
        try? Data("stay".utf8).write(to: samePlace)
        let sameFolderCut = FileService.paste(
            plan: FileService.PastePlan(sources: [samePlace.path], cut: true, internalSource: true),
            into: root.path
        )
        check("cut paste into same folder is a no-op", sameFolderCut.result.ok
              && FileService.exists(samePlace.path)
              && !FileService.exists(root.appendingPathComponent("stay - Copy.txt").path))

        let missingRestore = FileService.restoreItems([root.appendingPathComponent("does-not-exist").path])
        check("restore errors name the file", missingRestore.error?.hasPrefix("does-not-exist") == true,
              missingRestore.error ?? "nil")

        let zipped = FileService.compressToArchive([alpha.path, root.appendingPathComponent("sub/Beta.txt").path])
        check("multi-folder zip succeeds", zipped.ok && FileService.exists(zipped.path ?? ""), zipped.error ?? "")

        let refused = FileService.remove(["/"])
        check("permanent delete refuses root", !refused.ok && (refused.count ?? 0) == 0)

        let system = FileService.systemInfo()
        check("system info has home and volumes", !system.home.isEmpty && !system.volumes.isEmpty)
        check("pictures path", system.picturesPath.hasSuffix("Pictures"))

        let volumes = FileService.volumeList()
        check("volume list includes boot disk", volumes.contains(where: { $0.path == "/" }))
        check("volume list reports capacity", volumes.contains(where: { $0.total > 0 }))
        check("boot disk is not ejectable", !FileService.isEjectableVolume(path: "/"))
        check("eject refuses boot disk", !FileService.ejectVolume(at: "/").ok)

        let tar = root.appendingPathComponent("bundle.tar")
        let created = runProcess("/usr/bin/bsdtar", ["-cf", tar.path, "-C", root.path, "Alpha"])
        check("create test archive", created)
        if created {
            let opened = ArchiveService.openArchive(tar.path)
            check("archive opens", opened.ok && opened.extractRoot != nil, opened.error ?? "")
            if let extractRoot = opened.extractRoot {
                check("archive extracts contents", FileService.exists(extractRoot + "/Alpha/renamed.txt"))
                let destination = root.appendingPathComponent("out")
                try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let extracted = ArchiveService.extractAll(tar.path, destinationParent: destination.path)
                check("extract all", extracted.ok && FileService.exists(extracted.path ?? ""))
            }
        }

        let unsafeArchive = root.appendingPathComponent("unsafe.tar")
        let staging = root.appendingPathComponent("staging")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: staging.appendingPathComponent("evil.txt"))
        let unsafeCreated = runProcess(
            "/usr/bin/bsdtar",
            ["-cf", unsafeArchive.path, "-s", "../evil.txt", "evil.txt"],
            cwd: staging
        )
        if unsafeCreated {
            let opened = ArchiveService.openArchive(unsafeArchive.path)
            check("archive rejects traversal", !opened.ok, opened.error ?? "")
        }

        let linkStaging = root.appendingPathComponent("link-staging")
        try? fm.createDirectory(at: linkStaging.appendingPathComponent("pkg/bin"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: linkStaging.appendingPathComponent("pkg/lib"), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: linkStaging.appendingPathComponent("pkg/lib/tool.js"))
        try? fm.createSymbolicLink(atPath: linkStaging.appendingPathComponent("pkg/bin/tool").path,
                                   withDestinationPath: "../lib/tool.js")
        let linkArchive = root.appendingPathComponent("links.tar")
        if runProcess("/usr/bin/bsdtar", ["-cf", linkArchive.path, "pkg"], cwd: linkStaging) {
            let opened = ArchiveService.openArchive(linkArchive.path)
            check("archive allows in-archive relative symlink", opened.ok, opened.error ?? "")
        }
        check("symlink target escaping root is rejected",
              (try? ArchiveService.checkSymlinkTarget("../../etc/passwd", link: "pkg/link")) == nil
              && (try? ArchiveService.checkSymlinkTarget("/etc/passwd", link: "link")) == nil
              && (try? ArchiveService.checkSymlinkTarget("../lib/x", link: "pkg/bin/x")) != nil)

        check("extension hiding", displayName("report.txt", false) == "report"
              && displayName("archive.unknownext", false) == "archive.unknownext")
        check("type labels", FileKinds.typeLabel("a.png", false) == "Image"
              && FileKinds.typeLabel("folder", true) == "File folder")

        let handoffFile = root.appendingPathComponent("note.txt")
        if let link = QuickShareHandoff.deepLink(for: [handoffFile]),
           let components = URLComponents(url: link, resolvingAgainstBaseURL: false) {
            check("quick share deep link", components.scheme == "quickshare" && components.host == "send")
            if let handoffPath = components.queryItems?.first(where: { $0.name == "handoff" })?.value,
               let data = FileManager.default.contents(atPath: handoffPath),
               let payload = try? JSONDecoder().decode(QuickShareHandoff.Payload.self, from: data) {
                check("quick share handoff carries paths",
                      payload.paths == [handoffFile.standardizedFileURL.path])
                try? FileManager.default.removeItem(atPath: handoffPath)
            } else {
                check("quick share handoff carries paths", false)
            }
        } else {
            check("quick share deep link", false)
            check("quick share handoff carries paths", false)
        }

        runSearchQueryTests(root: root)
        runDuplicateTests(root: root)
        runPermissionTests(root: root)
        runDefaultAppTests(root: root)
        runMetadataTests(root: root)

        print("")
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func runSearchQueryTests(root: URL) {
        let parsed = SearchQuery.parse("report kind:pdf size:>1MB modified:today")
        check("query parses filters", parsed.terms == ["report"] && parsed.kinds == [.pdf]
              && parsed.minSize == 1_000_001 && parsed.modifiedAfter != nil, "\(parsed)")
        check("query keeps unknown keys as text", SearchQuery.parse("foo:bar").terms == ["foo:bar"])
        check("query size buckets", SearchQuery.parse("size:small").maxSize == 1_000_000)
        check("quoted phrase is literal", SearchQuery.parse("\"a*b\"").matchesName("xa*by")
              && !SearchQuery.parse("\"a*b\"").matchesName("axxb"))
        let wildcard = SearchQuery.parse("*.TXT")
        check("wildcard matches whole name", wildcard.matchesName("beta.txt") && !wildcard.matchesName("beta.txt.bak"))
        check("accent-insensitive names", SearchQuery.parse("resume").matchesName("Résumé.pdf"))
        check("relevance prefers exact names",
              SearchQuery.parse("beta").relevance("Beta.txt") < SearchQuery.parse("beta").relevance("alphabeta.txt"))
        let literal = SearchQuery.parse("\"a*b\"").spotlightQuery() ?? "nil"
        check("spotlight query escapes literal wildcards", literal == "kMDItemFSName == \"*a\\*b*\"cd", literal)

        let walk = FileService.search(root: root.path, query: "kind:text ext:txt beta", showHidden: false)
        check("filtered search", walk.entries.map(\.name) == ["Beta.txt"], "\(walk.entries.map(\.name))")
        try? Data("the quarterly invoice total".utf8).write(to: root.appendingPathComponent("sub/content.txt"))
        let content = FileService.search(root: root.path, query: "content:invoice", showHidden: false)
        check("content search reads text files", content.entries.map(\.name) == ["content.txt"],
              "\(content.entries.map(\.name))")
    }

    private static func runDuplicateTests(root: URL) {
        let fm = FileManager.default
        let dupes = root.appendingPathComponent("dupes")
        try? fm.createDirectory(at: dupes.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let big = Data((0..<40_000).map { UInt8($0 % 251) })
        var different = big
        different[big.count - 1] ^= 0xFF
        try? big.write(to: dupes.appendingPathComponent("a.bin"))
        try? big.write(to: dupes.appendingPathComponent("nested/a copy.bin"))
        try? different.write(to: dupes.appendingPathComponent("same-size-different-tail.bin"))
        try? Data("small".utf8).write(to: dupes.appendingPathComponent("s1.txt"))
        try? Data("small".utf8).write(to: dupes.appendingPathComponent("s2.txt"))
        try? Data().write(to: dupes.appendingPathComponent("empty1"))
        try? Data().write(to: dupes.appendingPathComponent("empty2"))
        try? fm.linkItem(atPath: dupes.appendingPathComponent("s1.txt").path,
                         toPath: dupes.appendingPathComponent("hardlink.txt").path)

        let result = DuplicateFinder.scan(root: dupes.path, showHidden: false)
        let sets = result.groups.map { Set($0.paths.map(PathTools.basename)) }
        check("duplicates found by content", sets.contains(["a.bin", "a copy.bin"]), "\(sets)")
        check("same size, different tail is not a duplicate",
              !sets.contains { $0.contains("same-size-different-tail.bin") })
        check("small duplicates found", sets.contains { $0.isSuperset(of: ["s2.txt"]) && $0.count == 2 }, "\(sets)")
        check("hard links and empty files are skipped", !sets.contains { $0.contains("empty1") }
              && !sets.contains { $0.isSuperset(of: ["s1.txt", "hardlink.txt"]) }, "\(sets)")
        check("duplicate wasted bytes", result.wastedBytes == 40_005, "\(result.wastedBytes)")
    }

    private static func runPermissionTests(root: URL) {
        let fm = FileManager.default
        let file = root.appendingPathComponent("perm.txt")
        let folder = root.appendingPathComponent("permdir")
        try? Data("p".utf8).write(to: file)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("child".utf8).write(to: folder.appendingPathComponent("child.txt"))
        try? Data("#!/bin/sh".utf8).write(to: folder.appendingPathComponent("tool.sh"))
        chmod(folder.appendingPathComponent("tool.sh").path, 0o755)

        check("symbolic permissions", PermissionsService.symbolic(0o4755, isDirectory: false) == "-rwsr-xr-x"
              && PermissionsService.symbolic(0o1777, isDirectory: true) == "drwxrwxrwt")
        check("octal parsing", PermissionsService.parseOctal("644") == 0o644
              && PermissionsService.parseOctal("0755") == 0o755 && PermissionsService.parseOctal("98") == nil)

        let single = PermissionsService.apply(paths: [file.path], mode: 0o600, locked: false, recursive: false)
        check("chmod applies", single.ok && PermissionsService.read(file.path)?.mode == 0o600, single.error ?? "")

        let locked = PermissionsService.apply(paths: [file.path], mode: 0o640, locked: true, recursive: false)
        let lockedInfo = PermissionsService.read(file.path)
        check("lock applies with mode", locked.ok && lockedInfo?.locked == true && lockedInfo?.mode == 0o640)
        check("locked file refuses deletion", (try? fm.removeItem(at: file)) == nil)
        let unlocked = PermissionsService.apply(paths: [file.path], mode: nil, locked: false, recursive: false)
        check("unlock applies", unlocked.ok && PermissionsService.read(file.path)?.locked == false)

        let recursive = PermissionsService.apply(paths: [folder.path], mode: 0o750, locked: false, recursive: true)
        let child = PermissionsService.read(folder.appendingPathComponent("child.txt").path)?.mode
        let tool = PermissionsService.read(folder.appendingPathComponent("tool.sh").path)?.mode
        check("recursive keeps file execute bits", recursive.ok && PermissionsService.read(folder.path)?.mode == 0o750
              && child == 0o640 && tool == 0o750,
              "dir \(String(PermissionsService.read(folder.path)?.mode ?? 0, radix: 8)) child \(String(child ?? 0, radix: 8)) tool \(String(tool ?? 0, radix: 8))")
    }

    private static func runMetadataTests(root: URL) {
        let dir = root.appendingPathComponent("metadata")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("note.txt").path
        FileManager.default.createFile(atPath: text, contents: Data("x".utf8))
        func item(_ path: String, _ key: MetadataKey) -> MetadataItem? {
            MetadataService.read(path)?.groups.flatMap(\.items).first { $0.key == key }
        }
        let edits = [
            MetadataService.set(.tags, value: "Red, Work", path: text),
            MetadataService.set(.comment, value: "hello", path: text),
            MetadataService.set(.created, value: "2020-01-02 03:04:05", path: text),
        ]
        _ = setxattr(text, "com.example.note", "plain", 5, 0, 0)
        check("metadata edits apply", edits.allSatisfy { $0 == nil } && item(text, .tags)?.value == "Red, Work"
              && item(text, .comment)?.value == "hello" && item(text, .created)?.value == "2020-01-02 03:04:05"
              && item(text, .xattr("com.example.note"))?.value == "plain", edits.compactMap { $0 }.joined())
        _ = setxattr(text, "com.apple.macl", "\u{1}", 1, 0, 0)
        if let macl = item(text, .xattr("com.apple.macl")) {
            check("macOS-managed attributes are read-only", !macl.removable && !macl.editable)
        } else {
            check("macOS-managed attributes are read-only", item(text, .xattr("com.apple.provenance")).map { !$0.removable } ?? true)
        }
        check("metadata rejects bad date", MetadataService.set(.modified, value: "yesterday", path: text) != nil)
        let removed = MetadataService.remove([.tags, .comment, .xattr("com.example.note")], path: text)
        check("metadata removes values", removed == nil && item(text, .tags)?.value == "" && item(text, .comment)?.value == ""
              && item(text, .xattr("com.example.note")) == nil)

        // A JPEG with GPS and camera fields: GPS clears without touching the rest.
        let photo = dir.appendingPathComponent("photo.jpg")
        if let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
           let image = context.makeImage(),
           let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            let properties: [CFString: Any] = [
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.3, kCGImagePropertyGPSLatitudeRef: "N"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme"],
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        let gps = MetadataService.read(photo.path)?.groups.first { $0.kind == .embedded(.gps) }?.clearableItems.map(\.key) ?? []
        let gpsError = MetadataService.remove(gps, path: photo.path)
        let after = MetadataService.read(photo.path)
        check("metadata clears GPS only", !gps.isEmpty && gpsError == nil && after?.groups.contains { $0.kind == .embedded(.gps) } == false
              && item(photo.path, .embedded("tiff:Make"))?.value == "Acme", gpsError ?? "")
        let makeError = MetadataService.set(.embedded("tiff:Make"), value: "Other", path: photo.path)
        check("metadata edits embedded field", makeError == nil && item(photo.path, .embedded("tiff:Make"))?.value == "Other", makeError ?? "")

        // Bulk clear: nested files and folders are cleared, package contents are left alone.
        let tree = dir.appendingPathComponent("tree")
        let nested = tree.appendingPathComponent("sub")
        let package = tree.appendingPathComponent("Tool.app/Contents")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let deep = nested.appendingPathComponent("deep.txt").path
        let inPackage = package.appendingPathComponent("Info.txt").path
        FileManager.default.createFile(atPath: deep, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: inPackage, contents: Data("x".utf8))
        let nestedPhoto = nested.appendingPathComponent("photo.jpg").path
        try? FileManager.default.copyItem(atPath: photo.path, toPath: nestedPhoto)
        let photoDate = Date(timeIntervalSince1970: 1_600_000_000)
        try? FileManager.default.setAttributes([.modificationDate: photoDate], ofItemAtPath: nestedPhoto)
        for path in [deep, inPackage, nested.path] {
            _ = MetadataService.set(.tags, value: "Blue", path: path)
            _ = setxattr(path, "com.apple.quarantine", "0083;65a1b2c3;Safari;", 21, 0, 0)
        }
        let bulk = MetadataService.clear(paths: [tree.path], options: [.finder, .download, .embedded], recursive: true, progress: { _ in }, isCancelled: { false })
        let bulkPhoto = MetadataService.read(nestedPhoto)?.groups.first { $0.kind == .embedded(.tiff) }?.items.map(\.key) ?? []
        check("bulk clear empties nested items", bulk.failed == 0 && item(deep, .tags)?.value == "" && item(deep, .quarantine) == nil
              && item(nested.path, .tags)?.value == "" && !bulkPhoto.contains(.embedded("tiff:Make")),
              "\(bulk) \(bulkPhoto)")
        check("bulk clear skips package contents", item(inPackage, .tags)?.value == "Blue" && item(inPackage, .quarantine) != nil)
        let keptDate = (try? FileManager.default.attributesOfItem(atPath: nestedPhoto))?[.modificationDate] as? Date
        check("image rewrite keeps modified date", keptDate == photoDate, "\(String(describing: keptDate))")
        let stopped = MetadataService.clear(paths: [tree.path], options: [.finder], recursive: true, progress: { _ in }, isCancelled: { true })
        check("bulk clear stops when cancelled", stopped.cancelled && stopped.changed == 0)
    }

    /// Read-only checks: they never change a real default app.
    private static func runDefaultAppTests(root: URL) {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("defaults")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["photo.JPG", "Makefile", "noext", "custom.mxeunknownext"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let jpeg = FileService.defaultAppContentType(forPath: dir.appendingPathComponent("photo.JPG").path)
        check("default app type for known extension", jpeg == .jpeg, jpeg?.identifier ?? "nil")
        check("default app extensions list the file's own first",
              jpeg.map { FileService.filenameExtensions(of: $0, preferring: "JPG") }?.first == "jpg"
                  && jpeg.map { FileService.filenameExtensions(of: $0, preferring: "jpg").contains("jpeg") } == true)
        check("no default app change for extensionless files",
              FileService.defaultAppContentType(forPath: dir.appendingPathComponent("noext").path) == nil
                  && FileService.defaultAppContentType(forPath: dir.appendingPathComponent("Makefile").path) == nil)
        let unknown = FileService.defaultAppContentType(forPath: dir.appendingPathComponent("custom.mxeunknownext").path)
        check("default app type for unknown extension is dynamic", unknown?.isDynamic == true, unknown?.identifier ?? "nil")
    }
}
