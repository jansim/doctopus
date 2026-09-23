import Foundation
import SwiftUI
import Observation
import AppKit

/// Main-actor coordinator between the SwiftUI views and the background actors.
///
/// Views only ever read this; every mutation funnels through an action here so
/// there is exactly one place where "disk changed" turns into "UI changed".
@MainActor
@Observable
final class AppModel {
    let intelligence = Intelligence()

    var libraries: [Library] = []
    func library(_ id: LibraryID) -> Library? { libraries.first { $0.id == id } }

    var activeLibrary: Library? {
        switch selection {
        case .tag(let ref): return library(ref.library) ?? libraries.first
        case .outliers(let id, _): return library(id) ?? libraries.first
        case .folder(let path): return libraries.first { $0.owns(path: path) } ?? libraries.first
        default: return libraries.first
        }
    }

    var settingsLibraryID: LibraryID? {
        didSet {
            guard settingsLibraryID != oldValue else { return }
            adoptSettings(of: settingsLibrary)
        }
    }
    var settingsLibrary: Library? {
        settingsLibraryID.flatMap(library) ?? activeLibrary
    }

    var settings = AppSettings() {
        didSet {
            guard settings != oldValue, !applyingSettings else { return }
            settingsLibrary?.settings = settings
            saveSettings()
        }
    }

    private var applyingSettings = false
    private var settingsSave: Task<Void, Never>?
    private var savedSettings: AppSettings?

    func adoptSettings(of lib: Library?) {
        let next = lib?.settings ?? AppSettings()
        guard next != settings else { return }
        applyingSettings = true
        settings = next
        applyingSettings = false
        savedSettings = next
    }

    /// Saves are chained rather than each spawning its own task, so a burst of
    /// changes — the thumbnail slider does dozens — cannot reach the store out
    /// of order.
    private func saveSettings() {
        guard let lib = settingsLibrary else { return }
        let previous = settingsSave
        settingsSave = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.settingsLibrary === lib, self.settings != self.savedSettings else { return }
            let current = self.settings
            self.savedSettings = current
            lib.settings = current
            await current.save(to: lib.store)
            await lib.indexer.update(settings: current)
            for other in self.libraries where other !== lib {
                other.settings.appWide = current.appWide
                await other.indexer?.update(settings: other.settings)
            }
        }
    }

    var folders: [FolderNode] = []
    var tags: [Tag] = []
    var savedViews: [SavedView] = []
    var finderTags: [Facet] = []
    var fields: [Field] = []
    var distinctTags: [Tag] {
        var seen = Set<String>()
        return tags
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.name.lowercased()).inserted }
    }
    var tagNames: [String] { distinctTags.map(\.name) }
    var facets: [String: [Facet]] = [:]
    var queue: [ProcessingEntry] = []
    var stats = Store.Stats()

    var documents: [DocumentRow] = []
    var selection: Selection = .all {
        didSet {
            guard selection != oldValue else { return }
            if settingsLibraryID == nil { adoptSettings(of: activeLibrary) }
            // A smart folder *is* its query, and the sidebar's List binding
            // assigns `selection` directly, so adopting the query has to happen
            // here — anywhere else and only the callers that remember to route
            // through it would filter at all.
            if case .savedView(let id, let query) = selection {
                searchText = query
                if let sv = savedViews.first(where: { $0.id == id }) { adoptSavedViewSettings(sv) }
            } else if case .savedView = oldValue {
                searchText = ""
            }
            reloadDocuments()
        }
    }
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    var listColumns = TableColumnCustomization<DocumentRow>() {
        didSet {
            guard listColumns != oldValue else { return }
            adoptColumnVisibility()
            persist(UIState.columns, JSONEncoder.string(listColumns))
        }
    }

    var collapsedFolders: Set<String> = [] {
        didSet {
            guard collapsedFolders != oldValue else { return }
            persist(UIState.collapsed, JSONEncoder.string(collapsedFolders.sorted()))
        }
    }

    private enum UIState {
        static let columns = "list_columns_v1"
        static let collapsed = "sidebar_collapsed_v1"
        static let sort = "list_sort_v1"
    }

    private struct StoredSort: Codable {
        var field: String
        var ascending: Bool
    }

    private func persist(_ key: String, _ value: String?) {
        guard let value else { return }
        Preferences.setUIState(key, value)
    }

    private func adoptColumnVisibility() {
        for field in fields {
            let visibility = listColumns[visibility: "field.\(field.key)"]
            guard visibility != .automatic else { continue }
            let shown = visibility == .visible
            guard shown != field.showInList else { continue }
            Task {
                for (lib, owned) in librariesDefining(field) {
                    var updated = owned
                    updated.showInList = shown
                    try? await lib.store.updateField(updated)
                }
                refreshAll()
            }
        }
    }

    var sort: SortField = .docDate { didSet { if !batchingSort { sortChanged() } } }
    var sortAscending = false { didSet { if !batchingSort { sortChanged() } } }
    private var batchingSort = false

    func setSort(_ field: SortField, ascending: Bool) {
        guard field != sort || ascending != sortAscending else { return }
        batchingSort = true
        sort = field
        sortAscending = ascending
        batchingSort = false
        sortChanged()
    }

    private func sortChanged() {
        persist(UIState.sort, JSONEncoder.string(
            StoredSort(field: sort.storageKey, ascending: sortAscending)))
        reloadDocuments()
    }
    var selectedIDs: Set<DocumentRef> = [] {
        didSet {
            guard selectedIDs != oldValue else { return }
            reloadDetail()
            if revealingFolders { refreshRevealedFolders() }
        }
    }
    var viewMode: ViewMode = .list {
        didSet {
            guard viewMode != oldValue else { return }
            settings.viewMode = viewMode
        }
    }

    var detail: DocumentDetail?

    var progress = IndexProgress()
    var modelStatus: LLMStatus = .unsupported("Checking…")
    var errorMessage: String?
    private(set) var notice: Notice?
    private var noticeDismissal: Task<Void, Never>?

    func notify(_ text: String, _ kind: Notice.Kind = .success) {
        let next = Notice(text: text, kind: kind)
        notice = next
        noticeDismissal?.cancel()
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: kind.duration)
            guard !Task.isCancelled, self?.notice?.id == next.id else { return }
            self?.notice = nil
        }
        if let app = NSApp {
            NSAccessibility.post(element: app.mainWindow ?? app, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            if !app.isActive { app.requestUserAttention(.informationalRequest) }
        }
    }

    func dismissNotice() {
        noticeDismissal?.cancel()
        notice = nil
    }

    // Stored properties belong in the class body, so the state each extension
    // drives sits here under that extension's name.

    // AppModel+Refresh
    var searchTask: Task<Void, Never>?
    var reloadTask: Task<Void, Never>?
    var detailTask: Task<Void, Never>?
    var reloadDocsTask: Task<Void, Never>?
    var currentLimit = 500
    var hasMoreDocuments = false

    // AppModel+Documents, the folders ⌥ points out
    /// Whether ⌥ is down, and so whether the sidebar is pointing out where the
    /// selection lives.
    var revealingFolders = false { didSet { if revealingFolders != oldValue { refreshRevealedFolders() } } }
    /// Every folder a selected document is in, as its master file or an alias.
    var revealedFolders: Set<String> = []
    var revealTask: Task<Void, Never>?

    // AppModel+Libraries, undo
    /// The window's, so a file change can be taken back with Edit › Undo.
    @ObservationIgnored weak var undoManager: UndoManager?

    // AppModel+Rules
    var ruleMatchTask: Task<Void, Never>?

    // AppModel+Import, continuous scanning
    var scanSession: ScanSession?
    var scanRound: Task<Void, Never>?
    var scanFocusCheck: Task<Void, Never>?

    var lastSelected: DocumentRow? {
        guard let id = selectedIDs.first else { return nil }
        return documents.first { $0.id == id }
    }
    var selectedRows: [DocumentRow] { documents.filter { selectedIDs.contains($0.id) } }

    private let explicitLibrary: URL?

    init(openingLibraryAt url: URL? = nil) {
        self.explicitLibrary = url
    }

    func bootstrap() async {
        if let saved: TableColumnCustomization<DocumentRow> = decode(UIState.columns) {
            listColumns = saved
        }
        if let saved: [String] = decode(UIState.collapsed) {
            collapsedFolders = Set(saved)
        }
        if let saved: StoredSort = decode(UIState.sort),
           let field = SortField(storageKey: saved.field) {
            batchingSort = true
            sort = field
            sortAscending = saved.ascending
            batchingSort = false
        }

        restoring = true
        if let explicit = explicitLibrary {
            await openLibrary(container: explicit, persist: false)
        } else {
            for bookmark in Preferences.libraryBookmarks {
                var stale = false
                guard let root = try? URL(resolvingBookmarkData: bookmark,
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                      FileManager.default.fileExists(atPath: root.path) else { continue }
                // Someone who deleted a folder's `library.doctopus` meant to stop
                // indexing it; quietly writing a new one at launch would undo
                // that. The library is dropped from the list instead.
                guard let container = existingContainer(in: root) else { continue }
                await openLibrary(container: container, rootBookmark: bookmark, persist: false)
            }
        }
        restoring = false
        persistOpenLibraries()
    }

    var restoring = false
    var opening: Set<LibraryID> = []

    func library(of row: DocumentRow) -> Library? { library(row.library) }

    func grouped(_ rows: [DocumentRow]) -> [(library: Library, rows: [DocumentRow])] {
        var order: [LibraryID] = []
        var byLibrary: [LibraryID: [DocumentRow]] = [:]
        for row in rows {
            if byLibrary[row.library] == nil { order.append(row.library) }
            byLibrary[row.library, default: []].append(row)
        }
        return order.compactMap { id in library(id).map { ($0, byLibrary[id] ?? []) } }
    }
}
