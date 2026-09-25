import Foundation
import CoreServices

/// FSEvents watcher over the indexed roots. Events are coalesced and debounced
/// so a bulk copy triggers one pass, not a thousand.
final class FileWatcher {
    /// One debounced burst of events.
    struct Changes: Sendable {
        /// Paths something happened to.
        var paths: [String] = []
        /// Directories whose events FSEvents could not deliver one by one —
        /// it coalesced or dropped them — so only walking them again tells
        /// what changed inside.
        var rescan: [String] = []
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.doctopus.fsevents")
    private let onChange: @Sendable (Changes) -> Void
    private let onRootChanged: @Sendable () -> Void
    private var pending = (paths: Set<String>(), rescan: Set<String>())
    private var debounce: DispatchWorkItem?

    init(onChange: @escaping @Sendable (Changes) -> Void,
         onRootChanged: @escaping @Sendable () -> Void = {}) {
        self.onChange = onChange
        self.onRootChanged = onRootChanged
    }

    deinit { stop() }

    func start(paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            watcher.enqueue(Array(zip(paths, flags)))
        }

        // WatchRoot: the watched folder being moved, renamed or deleted is
        // otherwise silent — every later event is for a path outside it.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot
                           | kFSEventStreamCreateFlagUseCFTypes)

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }

        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    static let mustRescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                    | kFSEventStreamEventFlagUserDropped
                                                    | kFSEventStreamEventFlagKernelDropped)

    private func enqueue(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        for event in events {
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                onRootChanged()
            } else if event.flags & Self.mustRescan != 0 {
                pending.rescan.insert(event.path)
            } else {
                pending.paths.insert(event.path)
            }
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Changes(paths: Array(self.pending.paths), rescan: Array(self.pending.rescan))
            self.pending = ([], [])
            guard !batch.paths.isEmpty || !batch.rescan.isEmpty else { return }
            self.onChange(batch)
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
