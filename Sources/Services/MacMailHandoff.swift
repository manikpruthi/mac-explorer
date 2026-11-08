import AppKit
import Foundation

/// "Email with Mac Mail": hands the selected files to Mac Mail, which opens a new message with them attached.
/// Folders are zipped by Mac Mail before attaching.
enum MacMailHandoff {
    static let bundleIdentifier = "com.manikpruthi.macmail"

    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Opens Mac Mail with the files. Calls back on the main queue with an error message, or nil on success.
    static func send(_ urls: [URL], completion: @escaping @MainActor (String?) -> Void) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else {
            Task { @MainActor in completion("Select files to email") }
            return
        }
        guard let app = applicationURL else {
            Task { @MainActor in completion("Install Mac Mail to email files") }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: config) { _, error in
            let message = error.map { "Could not open Mac Mail: \($0.localizedDescription)" }
            Task { @MainActor in completion(message) }
        }
    }
}
