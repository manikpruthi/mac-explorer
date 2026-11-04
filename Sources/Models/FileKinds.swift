import Foundation

enum FileKinds {
    nonisolated(unsafe) private static var kindByExtension: [String: FileKind] = [:]
    nonisolated(unsafe) private static var labelByExtension: [String: String] = [:]

    private static func register(_ kind: FileKind, _ label: String, _ extensions: [String]) {
        for ext in extensions {
            kindByExtension[ext] = kind
            labelByExtension[ext] = label
        }
    }

    private static let registered: Bool = {
        register(.image, "Image", [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg", "avif",
            "raw", "cr2", "nef", "dng", "ico",
        ])
        register(.video, "Video", ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpg", "mpeg", "3gp"])
        register(.audio, "Audio", ["mp3", "wav", "aiff", "aif", "m4a", "flac", "ogg", "oga", "wma", "aac", "opus"])
        register(.pdf, "PDF document", ["pdf"])
        register(.word, "Microsoft Word document", ["doc", "docx", "rtf", "odt", "pages", "dot", "dotx"])
        register(.excel, "Microsoft Excel worksheet", ["xls", "xlsx", "csv", "ods", "numbers", "tsv"])
        register(.powerpoint, "Microsoft PowerPoint presentation", ["ppt", "pptx", "odp", "key"])
        register(.archive, "Compressed archive", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "pkg", "xip"])
        register(.code, "Source file", [
            "js", "mjs", "cjs", "jsx", "ts", "tsx", "json", "jsonc", "html", "htm", "css", "scss", "sass", "less",
            "py", "rb", "go", "rs", "java", "kt", "swift", "m", "mm", "c", "h", "cpp", "hpp", "cs", "php", "sh",
            "bash", "zsh", "fish", "sql", "yml", "yaml", "toml", "xml", "graphql", "gql", "vue", "svelte", "astro",
            "lua", "pl", "r", "dart", "scala", "clj", "ex", "exs", "erl", "hs",
        ])
        register(.text, "Text document", ["txt", "md", "markdown", "log", "ini", "cfg", "conf", "env", "properties", "tex", "rst"])
        register(.font, "Font file", ["ttf", "otf", "woff", "woff2", "eot"])
        register(.disk, "Disk image", ["dmg", "iso", "img", "vhd", "vmdk"])
        register(.app, "Application", ["app", "exe", "msi", "appimage"])
        return true
    }()

    private static let browsableArchives: Set<String> = [
        "zip", "zipx", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "jar", "war", "whl",
    ]

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "pkg", "photoslibrary", "logicx", "band", "fcpbundle", "xcodeproj", "xcworkspace",
    ]

    static func extensionOf(_ name: String) -> String {
        _ = registered
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        return ext
    }

    static func baseName(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    static func kind(_ name: String, isDirectory: Bool) -> FileKind {
        _ = registered
        if isDirectory { return extensionOf(name) == "app" ? .app : .folder }
        return kindByExtension[extensionOf(name)] ?? .file
    }

    static func typeLabel(_ name: String, _ isDirectory: Bool) -> String {
        _ = registered
        if isDirectory { return extensionOf(name) == "app" ? "Application" : "File folder" }
        let ext = extensionOf(name)
        if ext.isEmpty { return "File" }
        if let label = labelByExtension[ext] { return label }
        return "\(ext.uppercased()) file"
    }

    static func isBrowsableArchive(_ name: String) -> Bool {
        _ = registered
        return browsableArchives.contains(extensionOf(name))
    }

    static func archiveFolderName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tar.xz") || lower.hasSuffix(".tar.zst") {
            return baseName(baseName(name))
        }
        return baseName(name)
    }

    /// Extensions that are always shown, so "invoice.pdf.exe" can't masquerade as "invoice.pdf".
    private static let alwaysVisibleExtensions: Set<String> = [
        "app", "exe", "msi", "appimage", "command", "tool", "sh", "bat", "cmd", "com", "scr", "pkg", "dmg",
    ]

    static func shouldHideExtension(_ name: String) -> Bool {
        _ = registered
        let ext = extensionOf(name)
        guard !ext.isEmpty, kindByExtension[ext] != nil, !alwaysVisibleExtensions.contains(ext) else { return false }
        // Never hide the last extension when another one is in front of it (double extension).
        return extensionOf(baseName(name)).isEmpty
    }

    static func isPackageDirectory(_ name: String) -> Bool {
        _ = registered
        return packageExtensions.contains(extensionOf(name))
    }

    /// Directory names skipped by name at any depth.
    static let searchSkip: Set<String> = [
        "node_modules", ".git", ".hg", ".svn", ".cache", ".npm", ".Trash",
    ]

    /// System locations skipped by absolute path only, so a project folder named
    /// "Library" is still searched.
    private static let skippedSystemPaths: Set<String> = [
        NSHomeDirectory() + "/Library", "/Library", "/System", "/private",
    ]

    static func isSkippedSystemPath(_ path: String) -> Bool {
        skippedSystemPaths.contains(path)
    }
}
