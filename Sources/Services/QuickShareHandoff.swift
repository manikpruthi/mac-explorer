import AppKit
import Foundation

enum QuickShareHandoff {
    struct Payload: Codable {
        var paths: [String]
    }

    static let bundleIdentifier = "tools.macexplorer.quickshare"

    static func deepLink(for urls: [URL]) -> URL? {
        let paths = urls.filter(\.isFileURL).map { $0.standardizedFileURL.path }
        guard !paths.isEmpty, let data = try? JSONEncoder().encode(Payload(paths: paths)) else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShare-Handoff", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeStaleHandoffs(in: directory)
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }

        var components = URLComponents()
        components.scheme = "quickshare"
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "handoff", value: file.path)]
        return components.url
    }

    /// Handoff files are read once by the receiving app; drop any older than a day.
    private static func removeStaleHandoffs(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: file) }
        }
    }
}
