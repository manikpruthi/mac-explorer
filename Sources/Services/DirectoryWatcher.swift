import CoreServices
import Foundation

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

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
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

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard let watchedPath else { return }
        var changed = false
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                || flag & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                || flag & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 {
                changed = true
                break
            }
            let eventPath = URL(fileURLWithPath: path).standardizedFileURL.path
            if eventPath == watchedPath || PathTools.dirname(eventPath) == watchedPath {
                changed = true
                break
            }
        }
        guard changed else { return }
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

private func directoryWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, numEvents > 0 else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    Task { @MainActor in
        watcher.handle(paths: paths, flags: flags)
    }
}
