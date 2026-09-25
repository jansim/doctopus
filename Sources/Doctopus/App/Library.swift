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
    var backups: Task<Void, Never>?
    /// Said once per open, not on every hourly look.
    var damageReported = false

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
    /// Empty unless the naming setting points mismatches out.
    var namingMismatches: [Int64: NamingMismatch] = [:]
    var outlierRevision = 0

    var displayName: String { root.lastPathComponent }

    /// Documents a rule would still change, which wait in Needs Review.
    var ruleMatchedDocs: Set<Int64> { Self.ruleMatchedDocs(in: ruleMatches) }

    static func ruleMatchedDocs(in matches: [Int64: [RuleMatch]]) -> Set<Int64> {
        Set(matches.lazy.filter { $0.value.contains(where: \.isPending) }.map { $0.key })
    }

    init(store: Store, bookmark: Data?) {
        self.store = store
        self.id = store.libraryID
        self.container = store.containerURL
        self.root = store.root
        self.bookmark = bookmark
    }

    func attachIndexer(intelligence: Intelligence,
                       onProgress: @escaping @Sendable (IndexProgress) -> Void,
                       onDataChanged: @escaping @Sendable () -> Void,
                       onProblem: @escaping @Sendable (String) -> Void = { _ in }) {
        indexer = Indexer(store: store, intelligence: intelligence, settings: settings,
                          onProgress: onProgress, onDataChanged: onDataChanged, onProblem: onProblem)
    }

    nonisolated func owns(path: String) -> Bool {
        path == root.path || path.hasPrefix(root.path + "/")
    }
}
