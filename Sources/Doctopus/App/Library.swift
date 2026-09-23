import Foundation
import Observation

@MainActor
@Observable
final class Library: Identifiable {
    nonisolated let id: LibraryID
    let store: Store
    nonisolated let container: URL
    nonisolated let root: URL
    var bookmark: Data?

    private(set) var indexer: Indexer!
    var watcher: FileWatcher?

    var settings = AppSettings()

    var folders: [FolderNode] = []
    var tags: [Tag] = []
    var finderTags: [Facet] = []
    var fields: [Field] = []
    var savedViews: [SavedView] = []
    var facets: [String: [Facet]] = [:]
    var queue: [ProcessingEntry] = []
    var stats = Store.Stats()
    var ruleMatches: [Int64: [RuleMatch]] = [:]
    var outlierRevision = 0

    var displayName: String { root.lastPathComponent }

    init(store: Store, bookmark: Data?) {
        self.store = store
        self.id = store.libraryID
        self.container = store.containerURL
        self.root = store.root
        self.bookmark = bookmark
    }

    func attachIndexer(intelligence: Intelligence,
                       onProgress: @escaping @Sendable (IndexProgress) -> Void,
                       onDataChanged: @escaping @Sendable () -> Void) {
        indexer = Indexer(store: store, intelligence: intelligence, settings: settings,
                          onProgress: onProgress, onDataChanged: onDataChanged)
    }

    nonisolated func owns(path: String) -> Bool {
        path == root.path || path.hasPrefix(root.path + "/")
    }
}
