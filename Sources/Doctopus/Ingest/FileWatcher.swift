import Foundation
import CoreServices

/// FSEvents watcher over the indexed roots.
///
/// The disk is the source of truth, so anything that happens in Finder — a move,
/// a rename, a delete, a file dropped in — arrives here and is reconciled
/// silently. Events are coalesced by the stream latency and then debounced again
/// so a bulk copy triggers one pass, not a thousand.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "io.doctopus.fsevents")
    private let onChange: @Sendable ([String]) -> Void
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func start(paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.enqueue(Array(paths.prefix(count)))
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
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

    /// Suppresses events caused by our own writes (optimization, renames).
    private var muted = 0
    func mute() { queue.sync { muted += 1 } }
    func unmute() { queue.asyncAfter(deadline: .now() + 1.0) { self.muted = max(0, self.muted - 1) } }

    private func enqueue(_ paths: [String]) {
        pending.formUnion(paths)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pending
            self.pending.removeAll(keepingCapacity: true)
            guard self.muted == 0, !batch.isEmpty else { return }
            self.onChange(Array(batch))
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
