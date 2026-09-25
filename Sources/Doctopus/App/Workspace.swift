import Foundation
import AppKit
import Observation

/// What the windows share: the model backends, the app-wide half of the
/// settings, and which window shows which library.
///
/// A window shows at most one library, and a library is open in at most one
/// window — its `Store` has to stay the only connection to its database. So
/// opening a library that is already open brings its window forward instead.
@MainActor
@Observable
final class Workspace {
    static let shared = Workspace()

    let intelligence = Intelligence()

    /// The window last in front. The menus, Settings, and whatever reaches the
    /// app as a whole rather than a window — Quick Look, ⌥ — act on this one.
    var current: AppModel?

    /// What the menus and Settings act on while no window has registered yet.
    var frontmost: AppModel {
        if let current { return current }
        if let spare { return spare }
        let made = AppModel()
        spare = made
        return made
    }

    @ObservationIgnored private var spare: AppModel?
    @ObservationIgnored private var models: [WeakModel] = []
    @ObservationIgnored var opening: Set<LibraryID> = []
    /// Only a view can open a window, so the first one hands this over.
    @ObservationIgnored var openWindow: ((URL) -> Void)?
    @ObservationIgnored var terminating = false
    @ObservationIgnored private var restored = false
    /// Libraries being reopened from last time, which open without a toast
    /// and stay on the list of open libraries until their window has them.
    @ObservationIgnored private var reopening: [(container: URL, bookmark: Data)] = []
    /// Finder opens that arrive before the first window is up.
    @ObservationIgnored private var pending: [URL] = []

    private struct WeakModel { weak var model: AppModel? }

    var windows: [AppModel] { models.compactMap(\.model) }

    func register(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakModel(model: model))
        if current == nil { current = model }
    }

    func unregister(_ model: AppModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        if current === model { current = windows.last }
    }

    func window(showing id: LibraryID) -> AppModel? {
        windows.first { $0.library?.id == id }
    }

    /// The window holding the lock on the library in `container`, however
    /// that library was reached.
    func window(holdingLockIn container: URL) -> AppModel? {
        guard let identity = LibraryLock.identity(in: container) else { return nil }
        return windows.first { $0.library?.store.lock?.identity == identity }
    }

    func window(owning path: String) -> AppModel? {
        windows.first { $0.library?.owns(path: path) == true }
    }

    static func existingContainer(in folder: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .first { $0.lastPathComponent.hasSuffix(".doctopus") }
    }

    /// A `.doctopus` library, a folder holding one, or a folder to start one in.
    static func container(for url: URL) -> URL {
        if url.lastPathComponent.hasSuffix(".doctopus") { return url }
        return existingContainer(in: url)
            ?? url.appendingPathComponent(Preferences.libraryFolderName, isDirectory: true)
    }

    func open(folderOrLibrary url: URL, from requester: AppModel? = nil) {
        guard restored else {
            pending.append(url)
            return
        }
        open(Self.container(for: url), from: requester)
    }

    /// Brings forward the window already showing the library, or else opens it
    /// in `requester` while that window is still empty, or in a window of its own.
    func open(_ container: URL, from requester: AppModel? = nil) {
        let container = container.standardizedFileURL
        if let showing = windows.first(where: { $0.library?.container.standardizedFileURL == container }) {
            showing.bringToFront()
            return
        }
        if let empty = [requester, current].compactMap({ $0 }).first(where: { $0.isEmpty })
            ?? windows.first(where: { $0.isEmpty }) {
            empty.bringToFront()
            Task { await empty.openLibrary(container: container) }
            return
        }
        openWindow?(container)
    }

    func isReopening(_ container: URL) -> Bool {
        let container = container.standardizedFileURL
        return reopening.contains { $0.container == container }
    }

    /// Called once the reopened library is in its window, or has failed to open.
    func doneReopening(_ container: URL) {
        let container = container.standardizedFileURL
        reopening.removeAll { $0.container == container }
    }

    /// Launch opens a single empty window. It takes the first library that was
    /// open last time, and each of the others gets a window of its own. None is
    /// waited for: the first one's indexing must not hold up the rest.
    func restore(into first: AppModel) {
        guard !restored else { return }
        var containers: [(container: URL, bookmark: Data)] = []
        for bookmark in Preferences.libraryBookmarks {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: bookmark,
                                      relativeTo: nil, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: root.path) else { continue }
            // Someone who deleted a folder's `library.doctopus` meant to stop
            // indexing it; quietly writing a new one at launch would undo
            // that. The library is dropped from the list instead.
            guard let container = Self.existingContainer(in: root) else { continue }
            containers.append((container.standardizedFileURL, bookmark))
        }
        reopening = containers
        restored = true
        if let head = containers.first {
            // Held until the task runs, so a Finder open waiting below does
            // not take this window first.
            first.isOpening = true
            Task {
                first.isOpening = false
                await first.openLibrary(container: head.container, rootBookmark: head.bookmark)
            }
        }
        for rest in containers.dropFirst() { openWindow?(rest.container) }
        let waiting = pending
        pending = []
        for url in waiting { open(folderOrLibrary: url) }
    }

    func persistOpenLibraries() {
        guard !terminating else { return }
        let shown = windows.compactMap { $0.library }
        let waiting = reopening.filter { entry in
            !shown.contains { $0.container.standardizedFileURL == entry.container }
        }
        Preferences.libraryBookmarks = shown.compactMap { $0.bookmark } + waiting.map(\.bookmark)
    }

    /// A change to the app-wide half in one window reaches every other one.
    func share(_ appWide: AppWideSettings, from source: AppModel) async {
        for other in windows where other !== source {
            await other.adoptAppWide(appWide)
        }
    }

    /// A scan belongs to the library it was sent into, or else to the window
    /// that asked for it.
    func scanTarget(for destination: URL?) -> AppModel? {
        destination.flatMap { window(owning: $0.path) }
            ?? windows.first { $0.scanSession != nil }
            ?? current
    }
}
