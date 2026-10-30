import AppKit
import Foundation

private struct PersistedState: Codable {
    var preferences: Preferences
    var pinned: [String]?
    var recent: [RecentItem]
    var session: PersistedSession?

    init(preferences: Preferences, pinned: [String]?, recent: [RecentItem], session: PersistedSession?) {
        self.preferences = preferences
        self.pinned = pinned
        self.recent = recent
        self.session = session
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferences = (try? container.decode(Preferences.self, forKey: .preferences)) ?? Preferences()
        pinned = try? container.decode([String].self, forKey: .pinned)
        recent = (try? container.decode([RecentItem].self, forKey: .recent)) ?? []
        session = try? container.decode(PersistedSession.self, forKey: .session)
    }
}

@MainActor
final class AppStore {
    static let shared = AppStore()

    var preferences = Preferences()
    var pinned: [String]?
    var recent: [RecentItem] = []
    var session: PersistedSession?

    private let stateURL: URL

    private init() {
        let transient = CommandLine.arguments.contains {
            ["--ui-test", "--self-test", "--screenshot", "--screenshot-exit"].contains($0)
        }
        let directory: URL
        if transient {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacExplorerState-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            directory = support.appendingPathComponent("Mac Explorer", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("state.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        preferences = state.preferences
        pinned = state.pinned
        recent = state.recent
        session = state.session
    }

    func save() {
        writeNow()
    }

    func flush() {
        writeNow()
    }

    private func writeNow() {
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let state = PersistedState(
            preferences: preferences,
            pinned: pinned,
            recent: recent,
            session: session
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func saveSession(_ snapshot: PersistedSession) {
        guard session != snapshot else { return }
        session = snapshot
        writeNow()
    }

    func ensureDefaults(system: SystemInfo) {
        guard pinned == nil else { return }
        let keys = ["desktop", "downloads", "documents", "pictures", "music", "videos", "applications"]
        pinned = system.specialFolders.filter { keys.contains($0.key) }.map { $0.path }
        save()
    }

    var pinnedPaths: [String] {
        pinned ?? []
    }

    func togglePin(_ paths: [String]) -> Bool {
        let unique = Array(Set(paths)).sorted()
        guard !unique.isEmpty else { return false }
        var current = pinned ?? []
        let allPinned = unique.allSatisfy { current.contains($0) }
        if allPinned {
            current.removeAll { unique.contains($0) }
        } else {
            for path in unique where !current.contains(path) {
                current.append(path)
            }
            preferences.quickAccessOpen = true
        }
        pinned = current
        save()
        return !allPinned
    }

    func isPinned(_ path: String) -> Bool {
        pinned?.contains(path) ?? false
    }

    func addRecent(_ entry: FileEntry) {
        guard !entry.isDirectory else { return }
        let item = RecentItem(
            path: entry.path,
            name: entry.name,
            kind: entry.kind,
            modified: entry.modified,
            parent: PathTools.dirname(entry.path)
        )
        recent.removeAll { $0.path == item.path }
        recent.insert(item, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
        save()
    }

    func removeRecent(_ path: String) {
        recent.removeAll { $0.path == path }
        save()
    }

    func clearRecent() {
        recent = []
        save()
    }
}
