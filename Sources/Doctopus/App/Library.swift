import Foundation
import Observation

/// One indexed folder and everything Doctopus keeps about it: the database (in
/// `library.doctopus/index.sqlite`), the OCR pipeline and the file watcher.
///
/// `AppModel` owns the open libraries and aggregates their sidebar data and
/// documents; a `Library` never talks to the UI directly.
@MainActor
@Observable
final class Library: Identifiable {
    nonisolated let id: LibraryID
    let store: Store
    /// The `library.doctopus` directory.
    nonisolated let container: URL
    /// The folder that contains `library.doctopus`.
    nonisolated let root: URL
    var bookmark: Data?

    private(set) var indexer: Indexer!
    var watcher: FileWatcher?

    /// Per-library ingest settings, loaded from this library's own database.
    var settings = AppSettings()

    // Sidebar data for this library, refreshed by `AppModel`.
    var folders: [FolderNode] = []
    var tags: [Tag] = []
    var finderTags: [Facet] = []
    var fields: [Field] = []
    var facets: [String: [Facet]] = [:]
    var stats = Store.Stats()

    var displayName: String { root.lastPathComponent }

    init(store: Store, bookmark: Data?) {
        self.store = store
        self.id = store.libraryID
        self.container = store.containerURL
        self.root = store.root
        self.bookmark = bookmark
    }

    func attachIndexer(llm: LLMService,
                       onProgress: @escaping @Sendable (IndexProgress) -> Void,
                       onDataChanged: @escaping @Sendable () -> Void) {
        indexer = Indexer(store: store, llm: llm, settings: settings,
                          onProgress: onProgress, onDataChanged: onDataChanged)
    }

    /// True when `path` is inside this library's root.
    nonisolated func owns(path: String) -> Bool {
        path == root.path || path.hasPrefix(root.path + "/")
    }
}
