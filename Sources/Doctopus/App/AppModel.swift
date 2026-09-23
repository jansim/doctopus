import Foundation
import SwiftUI
import Observation
import AppKit

/// Main-actor coordinator between the SwiftUI views and the background actors.
///
/// Views only ever read this; every mutation funnels through an action here so
/// there is exactly one place where "disk changed" turns into "UI changed".
enum DocumentSheet: Identifiable {
    case rename, addTag, quickOpen
    case file(DocumentRow)

    var id: String {
        switch self {
        case .rename: return "rename"
        case .addTag: return "addTag"
        case .quickOpen: return "quickOpen"
        case .file(let row): return "file \(row.id)"
        }
    }
}

/// One per window, and so one per library: a window starts empty, at the
/// welcome screen, and shows at most one library until it closes.
@MainActor
@Observable
final class AppModel {
    let intelligence: Intelligence

    var library: Library?
    /// While a library is on its way into this window.
    var isOpening = false
    /// Free to take a library.
    var isEmpty: Bool { library == nil && !isOpening }

    var settings = AppSettings() {
        didSet {
            guard settings != oldValue, !applyingSettings else { return }
            library?.settings = settings
            saveSettings()
        }
    }

    private var applyingSettings = false
    private var settingsSave: Task<Void, Never>?
    private var savedSettings: AppSettings?

    func adoptSettings(of lib: Library?) {
        let next = lib?.settings ?? AppSettings(appWide: Preferences.appWide)
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
        guard let lib = library else { return }
        let previous = settingsSave
        settingsSave = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.library === lib, self.settings != self.savedSettings else { return }
            let current = self.settings
            let renamesChanged = current.namingOptions != self.savedSettings?.namingOptions
            let appWideChanged = current.appWide != self.savedSettings?.appWide
            self.savedSettings = current
            lib.settings = current
            await current.save(to: lib.store)
            await lib.indexer.update(settings: current)
            if renamesChanged { self.refreshRuleMatches() }
            if appWideChanged { await Workspace.shared.share(current.appWide, from: self) }
        }
    }

    /// Another window's change to the app-wide half, which that window has
    /// already saved.
    func adoptAppWide(_ appWide: AppWideSettings) async {
        guard settings.appWide != appWide else { return }
        applyingSettings = true
        settings.appWide = appWide
        applyingSettings = false
        savedSettings?.appWide = appWide
        guard let lib = library else { return }
        lib.settings.appWide = appWide
        await lib.indexer?.update(settings: lib.settings)
    }

    var folders: [FolderNode] { library?.folders ?? [] }
    var tags: [Tag] { library?.tags ?? [] }
    var savedViews: [SavedView] { library?.savedViews ?? [] }
    var finderTags: [Facet] { library?.finderTags ?? [] }
    var fields: [Field] { library?.fields ?? [] }
    var distinctTags: [Tag] {
        var seen = Set<String>()
        return tags
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.name.lowercased()).inserted }
    }
    var tagNames: [String] { distinctTags.map(\.name) }
    var facets: [String: [Facet]] { library?.facets ?? [:] }
    var queue: [ProcessingEntry] { library?.queue ?? [] }
    var stats: Store.Stats { library?.stats ?? Store.Stats() }

    var documents: [DocumentRow] = []
    var selection: Selection = .all {
        didSet {
            guard selection != oldValue else { return }
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
            guard let lib = library else { continue }
            var updated = field
            updated.showInList = shown
            Task {
                try? await lib.store.updateField(updated)
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
    var selectedIDs: Set<Int64> = [] {
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
    var sheet: DocumentSheet?

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
    /// Kept to bring the window forward and to close it; see `WindowReader`.
    @ObservationIgnored weak var window: NSWindow?

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

    /// `url` is for the headless checks, which host panes without a window.
    init(openingLibraryAt url: URL? = nil) {
        self.intelligence = Workspace.shared.intelligence
        self.explicitLibrary = url
        self.settings = AppSettings(appWide: Preferences.appWide)
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

        if let explicit = explicitLibrary {
            await openLibrary(container: explicit, quietly: true)
        }
    }
}
