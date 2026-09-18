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
    // Backing services
    let intelligence = Intelligence()

    /// Every open library, in the order they were opened. Several can be open
    /// at once and the centre pane merges across all of them.
    var libraries: [Library] = []
    func library(_ id: LibraryID) -> Library? { libraries.first { $0.id == id } }

    /// The library an action with no row of its own belongs to: the one the
    /// current selection names, else the first open library. Imports, new tags
    /// and "rescan everything" all land here.
    var activeLibrary: Library? {
        switch selection {
        case .tag(let ref): return library(ref.library) ?? libraries.first
        case .folder(let path): return libraries.first { $0.owns(path: path) } ?? libraries.first
        default: return libraries.first
        }
    }

    /// Which library the Settings window is configuring. `nil` follows the
    /// selection; the picker in Settings pins it to one.
    var settingsLibraryID: LibraryID? {
        didSet {
            guard settingsLibraryID != oldValue else { return }
            adoptSettings(of: settingsLibrary)
        }
    }
    var settingsLibrary: Library? {
        settingsLibraryID.flatMap(library) ?? activeLibrary
    }

    /// The settings library's configuration. Editing it writes back to that
    /// library (and, for the app-wide half, to `Preferences`).
    var settings = AppSettings() {
        didSet {
            guard settings != oldValue, !applyingSettings else { return }
            settingsLibrary?.settings = settings
            saveSettings()
        }
    }

    /// True while `settings` is being replaced from a library rather than by the
    /// user, so the didSet does not write it straight back.
    private var applyingSettings = false
    private var settingsSave: Task<Void, Never>?
    private var savedSettings: AppSettings?

    /// Shows a library's settings without treating the swap as an edit.
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
            // The app-wide half is the same everywhere, so every other open
            // library takes it without its own ingest settings being touched.
            for other in self.libraries where other !== lib {
                other.settings.appWide = current.appWide
                await other.indexer?.update(settings: other.settings)
            }
        }
    }

    // Sidebar data
    var folders: [FolderNode] = []
    var tags: [Tag] = []
    /// Pinned smart folders / saved queries.
    var savedViews: [SavedView] = []
    /// The Finder's own tags across the library. Distinct from `tags`, which
    /// are Doctopus's — the two systems are deliberately kept apart.
    var finderTags: [Facet] = []
    var fields: [Field] = []
    /// One tag per name across the open libraries. Tagging works by name — each
    /// library gets or makes its own tag of that name — so a name held by two
    /// libraries is one thing to pick, coloured by whichever holds it first.
    var distinctTags: [Tag] {
        var seen = Set<String>()
        return tags
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.name.lowercased()).inserted }
    }
    var tagNames: [String] { distinctTags.map(\.name) }
    /// Facet values per field key, for the sidebar and search completions.
    var facets: [String: [Facet]] = [:]
    var queue: [ProcessingEntry] = []
    var stats = Store.Stats()

    // Center pane
    var documents: [DocumentRow] = []
    var selection: Selection = .all {
        didSet {
            guard selection != oldValue else { return }
            // Settings follow the selection unless the Settings window has
            // pinned a library of its own.
            if settingsLibraryID == nil { adoptSettings(of: activeLibrary) }
            // A smart folder *is* its query, and the sidebar's List binding
            // assigns `selection` directly, so adopting the query has to happen
            // here — anywhere else and only the callers that remember to route
            // through it would filter at all.
            if case .savedView(let id, let query) = selection {
                searchText = query
                if let sv = savedViews.first(where: { $0.id == id }) { adoptSavedViewSettings(sv) }
            } else if case .savedView = oldValue {
                // The text was put there by the smart folder, not typed, so it
                // leaves with it rather than silently filtering the next place.
                searchText = ""
            }
            reloadDocuments()
        }
    }
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    /// Which columns the list shows, and in what order. Persisted, so a chosen
    /// layout survives a relaunch. A field column toggled here writes back to
    /// the field itself, and `updateField` clears the entry again, so Settings
    /// and the header menu can never disagree about a field.
    var listColumns = TableColumnCustomization<DocumentRow>() {
        didSet {
            guard listColumns != oldValue else { return }
            adoptColumnVisibility()
            persist(UIState.columns, JSONEncoder.string(listColumns))
        }
    }

    /// Folders the user has collapsed. Stored as the exceptions rather than the
    /// expansions, so the tree starts fully open and a folder that appears
    /// later is open too.
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

    /// `SortField` carries an associated value, so it is written by its stable
    /// storage key rather than by a synthesized encoding.
    private struct StoredSort: Codable {
        var field: String
        var ascending: Bool
    }

    /// How the library is being looked at — column layout, collapsed folders,
    /// sort — is app-wide UI state rather than library data, so it lives in
    /// `UserDefaults` and survives switching libraries.
    private func persist(_ key: String, _ value: String?) {
        guard let value else { return }
        Preferences.setUIState(key, value)
    }

    /// Mirrors a header-menu show/hide onto the field, which is what the rest
    /// of the app (and Settings) reads.
    private func adoptColumnVisibility() {
        for field in fields {
            let visibility = listColumns[visibility: "field.\(field.key)"]
            guard visibility != .automatic else { continue }
            let shown = visibility == .visible
            guard shown != field.showInList else { continue }
            // Written straight to each library rather than through
            // `updateField`, which clears the header's own choice — the choice
            // being adopted here.
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

    /// Document date rather than added date, so the default order is the one
    /// the Date column shows — and its header carries the sort arrow.
    var sort: SortField = .docDate { didSet { if !batchingSort { sortChanged() } } }
    var sortAscending = false { didSet { if !batchingSort { sortChanged() } } }
    private var batchingSort = false

    /// Field and direction together, so a header click runs one query.
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
    var selectedIDs: Set<DocumentRef> = [] { didSet { if selectedIDs != oldValue { reloadDetail() } } }
    var viewMode: ViewMode = .list {
        didSet {
            guard viewMode != oldValue else { return }
            settings.viewMode = viewMode
        }
    }

    // Inspector
    var detail: DocumentDetail?

    // Transient UI state
    var progress = IndexProgress()
    var modelStatus: LLMStatus = .unsupported("Checking…")
    /// Something that went wrong and needs acknowledging. Shown as an alert, so
    /// it is kept for real problems; a routine result goes to `notify` instead.
    var errorMessage: String?
    /// The toast currently on screen, if any. Set through `notify`.
    private(set) var notice: Notice?
    private var noticeDismissal: Task<Void, Never>?

    /// Reports that something finished, as a toast that dismisses itself. A
    /// newer notice replaces an older one rather than queueing behind it: the
    /// latest result is the one worth reading.
    func notify(_ text: String, _ kind: Notice.Kind = .success) {
        let next = Notice(text: text, kind: kind)
        notice = next
        noticeDismissal?.cancel()
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: kind.duration)
            guard !Task.isCancelled, self?.notice?.id == next.id else { return }
            self?.notice = nil
        }
        // A toast is easy to miss for anyone not looking at the screen, and
        // invisible to VoiceOver unless it is announced.
        if let app = NSApp {
            NSAccessibility.post(element: app.mainWindow ?? app, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            // A long run that finishes while another app is in front gets one
            // Dock bounce, the Mac's own way of saying "done, when you're ready".
            if !app.isActive { app.requestUserAttention(.informationalRequest) }
        }
    }

    func dismissNotice() {
        noticeDismissal?.cancel()
        notice = nil
    }

    // Stored state for the work the extensions below drive. Swift keeps stored
    // properties in the class body, so these sit here rather than beside the
    // code that uses them; each one names the file it belongs to.

    // AppModel+Refresh
    var searchTask: Task<Void, Never>?
    var reloadTask: Task<Void, Never>?
    var detailTask: Task<Void, Never>?
    var reloadDocsTask: Task<Void, Never>?
    /// How much of the merged list is loaded — see `pageBatchSize`.
    var currentLimit = 500
    var hasMoreDocuments = false

    // AppModel+Import, continuous scanning
    /// The run under way, if any: one capture after another from the same
    /// device, so a stack of documents is scanned without coming back to the
    /// Mac in between.
    var scanSession: ScanSession?
    /// Both halves of a round: the pause before asking for the next capture,
    /// and the wait for it to arrive. One task, since only one of the two is
    /// ever outstanding and stopping means dropping whichever it is.
    var scanRound: Task<Void, Never>?
    /// Confirms a loss of focus before acting on it — see `appResignedActive`.
    var scanFocusCheck: Task<Void, Never>?

    var lastSelected: DocumentRow? {
        guard let id = selectedIDs.first else { return nil }
        return documents.first { $0.id == id }
    }
    var selectedRows: [DocumentRow] { documents.filter { selectedIDs.contains($0.id) } }

    // MARK: - Lifecycle

    /// `openingLibraryAt` (a `library.doctopus` directory) is for the headless
    /// checks, which drive a real model against a throwaway library.
    private let explicitLibrary: URL?

    init(openingLibraryAt url: URL? = nil) {
        self.explicitLibrary = url
    }

    func bootstrap() async {
        // App-wide UI state is restored before any library opens.
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

    /// Set while `bootstrap` restores the libraries open last time. Until it is
    /// done the saved list is the only record of the ones still to come, so a
    /// library opened from Finder meanwhile must not overwrite it.
    var restoring = false
    /// Libraries part-way through opening. A restore at launch and a
    /// double-click in Finder can race to open the same one, and both would
    /// otherwise get past the check for an open copy while the other loads.
    var opening: Set<LibraryID> = []

    // MARK: - Per-library dispatch

    /// The library a row came from. Rows always carry their library, so a miss
    /// means the library was closed between the fetch and the action.
    func library(of row: DocumentRow) -> Library? { library(row.library) }

    /// Rows grouped by owning library, for the actions that run as one batch
    /// inside a single `Indexer` or `Store`.
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
