import Foundation

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

        print("")
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
