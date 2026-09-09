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
    let llm = LLMService()

    /// Every open library. Phase 1 keeps exactly one open at a time; the array
    /// makes room for several without another reshape later.
    private(set) var libraries: [Library] = []
    var activeLibrary: Library? { libraries.first }
    func library(_ id: LibraryID) -> Library? { libraries.first { $0.id == id } }

    /// The active library's database and pipeline. Implicitly unwrapped because
    /// every path that reaches them is gated on a library being open (the views
    /// show `WelcomeView` until one is).
    var store: Store! { activeLibrary?.store }
    var indexer: Indexer! { activeLibrary?.indexer }
    var roots: [Library] { libraries }

    // Persisted configuration of the active library.
    var settings = AppSettings() {
        didSet {
            guard settings != oldValue, !applyingSettings else { return }
            activeLibrary?.settings = settings
            saveSettings()
        }
    }

    /// True while `settings` is being replaced from a library rather than by the
    /// user, so the didSet does not write it straight back.
    private var applyingSettings = false
    private var settingsSave: Task<Void, Never>?
    private var savedSettings: AppSettings?

    /// Saves are chained rather than each spawning its own task, so a burst of
    /// changes — the thumbnail slider does dozens — cannot reach the store out
    /// of order.
    private func saveSettings() {
        guard let lib = activeLibrary else { return }
        let previous = settingsSave
        settingsSave = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, self.activeLibrary === lib, self.settings != self.savedSettings else { return }
            let current = self.settings
            self.savedSettings = current
            lib.settings = current
            await current.save(to: lib.store)
            await lib.indexer.update(settings: current)
        }
    }

    // Sidebar data
    var folders: [FolderNode] = []
    var tags: [Tag] = []
    /// The Finder's own tags across the library. Distinct from `tags`, which
    /// are Doctopus's — the two systems are deliberately kept apart.
    var finderTags: [Facet] = []
    var fields: [Field] = []
    /// Facet values per field key, for the sidebar and search completions.
    var facets: [String: [Facet]] = [:]
    var queue: [ProcessingEntry] = []
    var stats = Store.Stats()

    // Center pane
    var documents: [DocumentRow] = []
    var selection: Selection = .all { didSet { if selection != oldValue { reloadDocuments() } } }
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
            var updated = field
            updated.showInList = shown
            Task { try? await store?.updateField(updated); refreshAll() }
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
    var selectedIDs: Set<Int64> = [] { didSet { if selectedIDs != oldValue { reloadDetail() } } }
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
    var modelStatus: LLMService.Status = .unsupported("Checking…")
    var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

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

        modelStatus = await llm.probe()

        if let explicit = explicitLibrary {
            await openLibrary(container: explicit, persist: false)
        } else {
            for bookmark in Preferences.libraryBookmarks {
                var stale = false
                guard let root = try? URL(resolvingBookmarkData: bookmark,
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                      FileManager.default.fileExists(atPath: root.path) else { continue }
                let container = existingContainer(in: root)
                    ?? root.appendingPathComponent(Preferences.libraryFolderName, isDirectory: true)
                await openLibrary(container: container, rootBookmark: bookmark, persist: false)
            }
        }
        persistOpenLibraries()
    }

    // MARK: - Libraries

    /// A `*.doctopus` directory sitting directly inside `folder`, if any.
    func existingContainer(in folder: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .first { $0.lastPathComponent.hasSuffix(".doctopus") }
    }

    /// Opens — creating it if needed — the library whose container is at
    /// `container`. Phase 1 keeps a single library open, so this replaces any
    /// currently-open one.
    private func openLibrary(container: URL, rootBookmark: Data? = nil,
                             persist: Bool = true, index: Bool = true) async {
        let root = container.deletingLastPathComponent()
        // The app is not sandboxed, so a plain bookmark is enough to survive the
        // folder being moved between launches.
        let bookmark = rootBookmark ?? (try? root.bookmarkData(
            includingResourceValuesForKeys: nil, relativeTo: nil))

        guard let store = try? Store(directory: container) else {
            errorMessage = "Could not open a library at \(root.lastPathComponent)."
            return
        }

        let lib = Library(store: store, bookmark: bookmark)
        lib.settings = await AppSettings.load(from: store)
        lib.attachIndexer(
            llm: llm,
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onDataChanged: { [weak self] in Task { @MainActor in self?.refreshAll() } })

        if (try? await store.rules())?.isEmpty ?? true {
            for rule in Router.starterRules { _ = try? await store.upsertRule(rule) }
        }

        for existing in libraries { existing.watcher?.stop() }
        libraries = [lib]

        applyingSettings = true
        settings = lib.settings
        applyingSettings = false
        savedSettings = lib.settings
        viewMode = settings.viewMode

        startWatching()
        refreshAll()
        if persist { persistOpenLibraries() }
        if index { await lib.indexer.indexAll() }
    }

    /// Choose a folder to index; its index lives in a `library.doctopus` inside.
    func addLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder to index in place. Doctopus keeps its index in a “\(Preferences.libraryFolderName)” folder inside it — nothing else is moved or renamed."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        openLibrary(at: folder)
    }

    func openLibraryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Library"
        panel.message = "Choose a “\(Preferences.libraryFolderName)” folder, or a folder that contains one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLibrary(at: url)
    }

    /// Open an existing library, given either its `library.doctopus` directory
    /// or the folder that contains one.
    func openLibrary(at url: URL) {
        let container: URL
        if url.lastPathComponent.hasSuffix(".doctopus") {
            container = url
        } else if let existing = existingContainer(in: url) {
            container = existing
        } else {
            container = url.appendingPathComponent(Preferences.libraryFolderName, isDirectory: true)
        }
        Task { await openLibrary(container: container) }
    }

    /// Stops watching and forgets a library. The `library.doctopus` directory is
    /// left on disk untouched.
    func closeLibrary(_ lib: Library) {
        lib.watcher?.stop()
        libraries.removeAll { $0 === lib }
        if selectionBelongs(to: lib) { selection = .all }
        persistOpenLibraries()
        applyingSettings = true
        settings = activeLibrary?.settings ?? AppSettings()
        applyingSettings = false
        startWatching()
        refreshAll()
    }

    private func selectionBelongs(to lib: Library) -> Bool {
        switch selection {
        case .tag(let libID, _): return libID == lib.id
        case .folder(let path): return lib.owns(path: path)
        default: return false
        }
    }

    private func persistOpenLibraries() {
        Preferences.libraryBookmarks = libraries.compactMap(\.bookmark)
    }

    // MARK: - Refresh

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let raw = Preferences.uiState(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func refreshAll() {
        reloadTask?.cancel()
        let libs = libraries
        reloadTask = Task { [weak self] in
            guard let self else { return }

            var folders: [FolderNode] = []
            var tags: [Tag] = []
            var fields: [Field] = []
            var finderTags: [Facet] = []
            var facets: [String: [Facet]] = [:]
            var queue: [ProcessingEntry] = []
            var stats = Store.Stats()
            var finderLabels: [String: Int] = [:]

            for lib in libs {
                let store = lib.store
                async let tree = (try? await store.folderTree()) ?? []
                async let tagList = (try? await store.tags()) ?? []
                async let fieldList = (try? await store.fields()) ?? []
                async let finder = (try? await store.finderTags()) ?? []
                async let labels = (try? await store.finderTagLabels()) ?? [:]
                async let q = (try? await store.processingQueue()) ?? []
                async let s = (try? await store.stats()) ?? Store.Stats()

                let (t, tg, fs, ftg, lbl, qq, ss) = await (tree, tagList, fieldList, finder, labels, q, s)
                var facetMap: [String: [Facet]] = [:]
                for field in fs { facetMap[field.key] = (try? await store.facets(field: field)) ?? [] }

                let libID = lib.id
                let stampedTags = tg.map { var x = $0; x.library = libID; return x }
                let stampedFields = fs.map { var x = $0; x.library = libID; return x }
                lib.folders = t
                lib.tags = stampedTags
                lib.fields = stampedFields
                lib.finderTags = ftg
                lib.facets = facetMap
                lib.stats = ss

                folders += t
                tags += stampedTags
                fields += stampedFields
                finderTags = Self.mergeFacets(finderTags, ftg)
                for (k, v) in facetMap { facets[k] = Self.mergeFacets(facets[k] ?? [], v) }
                queue += qq
                stats = stats + ss
                finderLabels.merge(lbl) { max($0, $1) }
            }

            FinderTags.learn(finderLabels)
            queue.sort { $0.at > $1.at }

            guard !Task.isCancelled else { return }
            self.folders = folders
            self.tags = tags
            self.finderTags = finderTags
            self.fields = fields
            self.facets = facets
            self.queue = queue
            self.stats = stats
            self.reloadDocuments()
        }
    }

    /// Sums facet counts by value, so a doc-type value spanning two libraries
    /// shows as one row.
    private static func mergeFacets(_ a: [Facet], _ b: [Facet]) -> [Facet] {
        guard !a.isEmpty else { return b }
        var byValue: [String: Facet] = [:]
        for f in a + b {
            if var existing = byValue[f.value] {
                existing.count += f.count
                existing.icon = existing.icon ?? f.icon
                byValue[f.value] = existing
            } else {
                byValue[f.value] = f
            }
        }
        return byValue.values.sorted { $0.count > $1.count || ($0.count == $1.count && $0.value < $1.value) }
    }

    func reloadDocuments() {
        let sel = selection, text = searchText, sortField = sort, asc = sortAscending
        let keys = Set(fields.map(\.key))
        guard let lib = activeLibrary else { documents = []; return }
        reloadDocsTask?.cancel()
        reloadDocsTask = Task { [weak self] in
            guard let self else { return }
            let query = SearchQuery(text, fieldKeys: keys)
            let rows = (try? await lib.store.listDocuments(selection: sel, query: query,
                                                           sort: sortField, ascending: asc)) ?? []
            guard !Task.isCancelled else { return }
            self.documents = rows
            // Drop selections that no longer exist so the inspector cannot go stale.
            let live = Set(rows.map(\.id))
            let kept = self.selectedIDs.intersection(live)
            if kept != self.selectedIDs { self.selectedIDs = kept }
            if self.selectedIDs.isEmpty { self.detail = nil }
        }
    }
    private var reloadDocsTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.reloadDocuments()
        }
    }

    private func reloadDetail() {
        detailTask?.cancel()
        guard selectedIDs.count == 1, let id = selectedIDs.first, let lib = activeLibrary else {
            if selectedIDs.isEmpty { detail = nil }
            return
        }
        detailTask = Task { [weak self] in
            guard let self else { return }
            let d = try? await lib.store.detail(id)
            guard !Task.isCancelled else { return }
            self.detail = d
        }
    }

    // MARK: - Watching

    private func startWatching() {
        for lib in libraries {
            lib.watcher?.stop()
            let indexer = lib.indexer!
            let watcher = FileWatcher { changed in
                Task { await indexer.handleChanges(paths: changed) }
            }
            watcher.start(paths: [lib.root.path])
            lib.watcher = watcher
        }
    }

    func reindex() { Task { for lib in libraries { await lib.indexer.indexAll() } } }
    func cancelIndexing() { Task { for lib in libraries { await lib.indexer.cancel() } } }

    // MARK: - Document actions

    /// Space, the Document menu and double-click all land here.
    func quickLook(startingAt row: DocumentRow? = nil) {
        let rows = selectedRows.isEmpty ? documents : selectedRows
        guard !rows.isEmpty else { return }
        QuickLookController.shared.toggle(urls: rows.map(\.url),
                                          startingAt: row?.url ?? lastSelected?.url)
    }

    func reveal(_ rows: [DocumentRow]) {
        NSWorkspace.shared.activateFileViewerSelecting(rows.map(\.url))
    }

    func open(_ rows: [DocumentRow]) {
        for row in rows { NSWorkspace.shared.open(row.url) }
    }

    func reprocess(_ rows: [DocumentRow]) {
        Task { await indexer.reprocess(ids: rows.map(\.id)) }
    }

    func optimize(_ rows: [DocumentRow]) {
        Task {
            let (count, saved) = await indexer.optimize(ids: rows.map(\.id))
            if count == 0 { errorMessage = "Nothing to optimize — these files are already compact." }
            else { errorMessage = "Optimized \(count) file\(count == 1 ? "" : "s"), saved \(ByteFormat.string(saved))." }
        }
    }

    func rename(_ rows: [DocumentRow], template: String) {
        Task {
            let n = await indexer.rename(ids: rows.map(\.id), template: template)
            errorMessage = n == 0 ? "No files needed renaming." : "Renamed \(n) file\(n == 1 ? "" : "s")."
        }
    }

    func move(_ rows: [DocumentRow], to destination: URL) {
        Task { _ = await indexer.move(ids: rows.map(\.id), to: destination) }
    }

    func moveToFolderPicker(_ rows: [DocumentRow]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Move Here"
        panel.directoryURL = rows.first?.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        move(rows, to: url)
    }

    func moveToTrash(_ rows: [DocumentRow]) {
        Task {
            for row in rows {
                try? FileManager.default.trashItem(at: row.url, resultingItemURL: nil)
                try? await store.deleteDocument(row.id)
            }
            refreshAll()
        }
    }

    /// Files documents into a second folder as Finder aliases, leaving the
    /// master where it is. This is what a plain drag onto a folder does.
    func createAliases(_ rows: [DocumentRow], in folder: URL) {
        Task {
            var made = 0
            for row in rows {
                guard row.url.deletingLastPathComponent().path != folder.path else { continue }
                guard let created = try? AliasManager.createAlias(to: row.url, in: folder) else { continue }
                try? await store.recordAlias(docID: row.id, tagID: nil, path: created.path)
                try? await store.logProcessing(docID: row.id, action: "aliased",
                                               detail: "Also filed under \(folder.lastPathComponent)",
                                               confidence: nil, rule: nil, from: row.path,
                                               to: created.path, approved: true)
                made += 1
            }
            refreshAll()
            if made == 0 { errorMessage = "Those documents are already in that folder." }
        }
    }

    /// Removes an alias placement without touching the master file.
    func removeAlias(_ row: DocumentRow, inFolder folder: String) {
        Task {
            for alias in ((try? await store.aliases(for: row.id)) ?? [])
            where alias.path.hasPrefix(folder + "/") {
                AliasManager.removeAlias(at: alias.path)
                try? await store.deleteAlias(id: alias.id)
            }
            refreshAll()
        }
    }

    // MARK: - Tags

    func addTag(_ name: String, to rows: [DocumentRow]) {
        Task {
            guard let id = try? await store.tagID(named: name), id > 0 else { return }
            for row in rows {
                try? await store.assign(tag: id, to: row.id)
                await indexer.syncAliases(docID: row.id, target: row.url)
            }
            refreshAll()
            reloadDetail()
        }
    }

    func removeTag(_ tag: Tag, from rows: [DocumentRow]) {
        Task {
            for row in rows {
                try? await store.unassign(tag: tag.id, from: row.id)
                await indexer.syncAliases(docID: row.id, target: row.url)
            }
            refreshAll()
            reloadDetail()
        }
    }

    func setTagMirroring(_ tag: Tag, enabled: Bool) {
        Task {
            try? await store.setTagMirroring(tag.id, enabled, folder: tag.folder)
            // Re-sync every document carrying the tag so disk matches immediately.
            let rows = (try? await store.listDocuments(selection: .tag(tag.library, tag.id), query: SearchQuery(""),
                                                       sort: .added, ascending: false, limit: 5000)) ?? []
            for row in rows { await indexer.syncAliases(docID: row.id, target: row.url) }
            refreshAll()
        }
    }

    func createTag(named name: String) {
        Task { _ = try? await store.tagID(named: name); refreshAll() }
    }

    func renameTag(_ tag: Tag, to name: String) {
        Task {
            let survivor = (try? await store.renameTag(tag.id, to: name)) ?? tag.id
            if selection == .tag(tag.library, tag.id) { selection = .tag(tag.library, survivor) }
            refreshAll()
            reloadDetail()
        }
    }

    func setTagColor(_ tag: Tag, _ color: Int64) {
        Task { try? await store.setTagColor(tag.id, color); refreshAll(); reloadDetail() }
    }

    // MARK: - Finder tags

    /// Writing one changes the file's extended attributes, so it only ever
    /// happens on an explicit action, and the index is refreshed from whatever
    /// the disk ends up saying rather than from what we asked for.
    func addFinderTag(_ name: String, to rows: [DocumentRow]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        Task {
            for row in rows where FinderTags.add(clean, to: row.url) {
                try? await store.indexFinderTags(docID: row.id, entries: FinderTags.entries(row.url))
            }
            refreshAll()
            reloadDetail()
        }
    }

    func removeFinderTag(_ name: String, from rows: [DocumentRow]) {
        Task {
            for row in rows where FinderTags.remove(name, from: row.url) {
                try? await store.indexFinderTags(docID: row.id, entries: FinderTags.entries(row.url))
            }
            if selection == .finderTag(name) { selection = .all }
            refreshAll()
            reloadDetail()
        }
    }

    // MARK: - Value icons

    func setValueIcon(_ field: Field, value: String, icon: String?) {
        Task { try? await store.setValueIcon(field: field, value: value, icon: icon); refreshAll() }
    }

    func deleteTag(_ tag: Tag) {
        Task {
            try? await store.deleteTag(tag.id)
            if selection == .tag(tag.library, tag.id) { selection = .all }
            refreshAll()
        }
    }

    // MARK: - Fields

    func setFieldValue(_ rows: [DocumentRow], field: Field, value: String?) {
        Task {
            for row in rows {
                try? await store.setFieldValue(docID: row.id, field: field, value: value)
            }
            reloadDetail()
            refreshAll()
        }
    }

    func setFieldValue(_ docID: Int64, field: Field, value: String?) {
        Task {
            try? await store.setFieldValue(docID: docID, field: field, value: value)
            reloadDetail()
            refreshAll()
        }
    }

    /// Renaming a value onto an existing one merges every matching document.
    func renameFieldValue(_ field: Field, from old: String, to new: String) {
        Task {
            let n = (try? await store.renameFieldValue(field: field, from: old, to: new)) ?? 0
            if case .field(let key, let value) = selection, key == field.key, value == old {
                selection = .field(field.key, new)
            }
            refreshAll()
            if n > 0 { errorMessage = "Renamed “\(old)” to “\(new)” on \(n) document\(n == 1 ? "" : "s")." }
        }
    }

    func deleteFieldValue(_ field: Field, value: String) {
        Task {
            try? await store.deleteFieldValue(field: field, value: value)
            if selection == .field(field.key, value) { selection = .all }
            refreshAll()
        }
    }

    func updateField(_ field: Field) {
        // An explicit choice in Settings supersedes one made in the list header.
        listColumns[visibility: "field.\(field.key)"] = .automatic
        Task { try? await store.updateField(field); refreshAll() }
    }

    func addCustomField(named name: String) {
        Task { _ = try? await store.addCustomField(name: name); refreshAll() }
    }

    func deleteField(_ field: Field) {
        Task {
            try? await store.deleteField(field.id)
            if case .field(let key, _) = selection, key == field.key { selection = .all }
            refreshAll()
        }
    }

    // MARK: - Metadata editing

    func editMetadata(_ docID: Int64, column: String, value: String?) {
        Task {
            try? await store.overwriteMetadataField(docID, column: column, value: value?.nilIfBlank)
            reloadDetail()
            reloadDocuments()
        }
    }

    func setDocumentDate(_ docID: Int64, _ date: Date?) {
        Task {
            try? await store.setDocumentDate(docID, date)
            reloadDetail()
            reloadDocuments()
        }
    }

    // MARK: - Queue

    func approveAll() {
        Task {
            for entry in queue where !entry.approved {
                try? await store.setProcessingApproved(entry.id, true)
            }
            refreshAll()
        }
    }

    func setApproved(_ rows: [DocumentRow], _ approved: Bool) {
        Task {
            for row in rows {
                guard let entry = row.queue else { continue }
                try? await store.setProcessingApproved(entry.entryID, approved)
            }
            refreshAll()
        }
    }

    // MARK: - Import

    var defaultImportDirectory: URL? {
        guard let lib = activeLibrary else { return nil }
        return lib.root.appendingPathComponent(settings.scanDestination, isDirectory: true)
    }

    /// Where a scan or import triggered from the center pane should land: the
    /// folder currently selected in the sidebar, if any, else the inbox.
    var contextImportDirectory: URL? {
        if case .folder(let path) = selection { return URL(fileURLWithPath: path) }
        return defaultImportDirectory
    }

    func importFiles(_ urls: [URL], into destination: URL?, movingSource: Bool = false) {
        guard let lib = activeLibrary else {
            errorMessage = "Open a library before importing."
            return
        }
        // A scan started from the menu bar has no explicit destination; follow
        // whatever the sidebar has selected, then fall back to the inbox.
        let dest = destination ?? contextImportDirectory ?? lib.root
        Task { await lib.indexer.importFiles(urls, into: dest, movingSource: movingSource) }
    }

    /// Writes scanner output into a folder and runs it through the pipeline.
    func importScanned(_ items: [ScannedItem], into destination: URL?) {
        guard !items.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var urls: [URL] = []
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        for (i, item) in items.enumerated() {
            let name = items.count == 1 ? "Scan \(stamp).\(item.ext)" : "Scan \(stamp) \(i + 1).\(item.ext)"
            let url = tmp.appendingPathComponent(name)
            if (try? item.data.write(to: url)) != nil { urls.append(url) }
        }
        // The scan was staged in the temporary directory by this app, so it is
        // ours to move rather than copy.
        importFiles(urls, into: destination, movingSource: true)
    }
}

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
    static func string(_ bytes: Int64) -> String { formatter.string(fromByteCount: bytes) }
}

extension ISO8601DateFormatter {
    static let filenameSafe: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

extension JSONEncoder {
    /// Small helper for the bits of UI state that live in the settings table.
    static func string<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
