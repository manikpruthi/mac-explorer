import CoreServices
import Foundation

/// Shared between the main-actor watcher and the FSEvents queue. FSEvents retains it
/// through the stream context, so an in-flight callback can never see a freed object.
private final class WatcherContext: @unchecked Sendable {
    let watchedPath: String
    weak var watcher: DirectoryWatcher?

    init(watchedPath: String, watcher: DirectoryWatcher) {
        self.watchedPath = watchedPath
        self.watcher = watcher
    }

    /// Runs on the FSEvents queue, so unrelated events never reach the main thread.
    func isRelevant(paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) -> Bool {
        let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
            | UInt32(kFSEventStreamEventFlagRootChanged)
            | UInt32(kFSEventStreamEventFlagUserDropped)
            | UInt32(kFSEventStreamEventFlagKernelDropped)
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & rescan != 0 { return true }
            var eventPath = path
            while eventPath.count > 1, eventPath.hasSuffix("/") { eventPath.removeLast() }
            if eventPath == watchedPath { return true }
        }
        return false
    }
}

@MainActor
final class DirectoryWatcher {
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "tools.macexplorer.directory-watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var pendingChange: DispatchWorkItem?

    func watch(path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if watchedPath == standardized, stream != nil { return }
        stop()
        guard FileManager.default.fileExists(atPath: standardized) else { return }
        watchedPath = standardized

        let box = WatcherContext(watchedPath: standardized, watcher: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: watcherContextRetain,
            release: watcherContextRelease,
            copyDescription: nil
        )
        // Directory-level events only (no kFSEventStreamCreateFlagFileEvents): the listing
        // only changes when the watched directory itself changes, and per-file events from
        // the whole subtree (e.g. a build under ~) would otherwise flood the app.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            directoryWatcherCallback,
            &context,
            [standardized] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            watchedPath = nil
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            watchedPath = nil
            return
        }
        self.stream = stream
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        watchedPath = nil
    }

    isolated deinit {
        pendingChange?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    fileprivate func scheduleChange(for path: String) {
        guard watchedPath == path else { return }
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil
            self.onChange?()
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

// File-level (nonisolated) on purpose: FSEvents invokes these on its own queue, including
// when the stream is deallocated. Closures written inside the @MainActor class would
// inherit main-actor isolation and trap at runtime.
private func watcherContextRetain(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let info else { return nil }
    _ = Unmanaged<WatcherContext>.fromOpaque(info).retain()
    return info
}

private func watcherContextRelease(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<WatcherContext>.fromOpaque(info).release()
}

private func directoryWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, numEvents > 0 else { return }
    let context = Unmanaged<WatcherContext>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
    guard context.isRelevant(paths: paths, flags: flags) else { return }
    let path = context.watchedPath
    Task { @MainActor [weak context] in
        context?.watcher?.scheduleChange(for: path)
    }
}
