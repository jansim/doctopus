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
    private(set) var libraries: [Library] = []
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
    private func adoptSettings(of lib: Library?) {
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
    /// `container`, alongside any already open. Opening one that is already
    /// open is a no-op rather than a second copy.
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

        // Identity is the id in `meta.json`, so the same library reached by two
        // different paths — a bookmark and a Finder open, say — is one library.
        if let already = library(store.libraryID) {
            if let bookmark { already.bookmark = bookmark }
            if persist { persistOpenLibraries() }
            return
        }

        let lib = Library(store: store, bookmark: bookmark)
        lib.settings = await AppSettings.load(from: store)
        // The callbacks hop back to the main actor; the actors themselves stay off it.
        lib.attachIndexer(
            intelligence: intelligence,
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onDataChanged: { [weak self] in Task { @MainActor in self?.refreshAll() } })

        if (try? await store.rules())?.isEmpty ?? true {
            for rule in Router.starterRules { _ = try? await store.upsertRule(rule) }
        }

        libraries.append(lib)
        startWatching(lib)

        // The first library decides what the settings pane and the view mode
        // show; later ones join without disturbing either.
        if libraries.count == 1 {
            adoptSettings(of: lib)
            viewMode = settings.viewMode
            await intelligence.update(settings: settings)
            modelStatus = await intelligence.status()
        }

        refreshAll()
        if persist { persistOpenLibraries() }
        guard index else { return }
        let indexed = await lib.indexer.indexAll()
        // Only a library the user just added or opened reports back; the ones
        // restored at launch catch up quietly.
        if persist, let indexed {
            notify(indexed == 0 ? "Opened \(lib.displayName)."
                                : "Indexed \(indexed) document\(indexed == 1 ? "" : "s") in \(lib.displayName).")
        }
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
        if settingsLibraryID == lib.id { settingsLibraryID = nil }
        if selectionBelongs(to: lib) { selection = .all }
        selectedIDs = selectedIDs.filter { $0.library != lib.id }
        persistOpenLibraries()
        adoptSettings(of: settingsLibrary)
        refreshAll()
    }

    private func selectionBelongs(to lib: Library) -> Bool {
        switch selection {
        case .tag(let ref): return ref.library == lib.id
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
                lib.queue = qq
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
            self.fields = Self.mergeFields(fields)
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

    /// One entry per field key for the merged surfaces — columns, the inspector,
    /// the facet sections. Every library seeds the same built-ins, so a shared
    /// key is the same field wherever it came from; the first library to define
    /// one supplies its name, icon and position, and the per-library copies stay
    /// on `Library.fields` for anything that has to write to a specific database.
    private static func mergeFields(_ fields: [Field]) -> [Field] {
        var seen = Set<String>()
        var merged: [Field] = []
        for field in fields where seen.insert(field.key).inserted {
            merged.append(field)
        }
        return merged.sorted { $0.position < $1.position }
    }

    /// Which libraries a selection can possibly match. Tag and folder
    /// selections name one; everything else fans out across all of them.
    private func librariesInScope(for selection: Selection) -> [Library] {
        switch selection {
        case .tag(let ref): return library(ref.library).map { [$0] } ?? []
        case .folder(let path): return libraries.filter { $0.owns(path: path) }
        default: return libraries
        }
    }

    /// How many rows the centre pane holds at once. Each library is queried for
    /// this many, so the merge always has enough to fill the window whichever
    /// library the top of the list comes from.
    private static let listLimit = 500

    func reloadDocuments() {
        let sel = selection, text = searchText, sortField = sort, asc = sortAscending
        let keys = Set(fields.map(\.key))
        let libs = librariesInScope(for: sel)
        guard !libs.isEmpty else { documents = []; selectedIDs = []; detail = nil; return }
        reloadDocsTask?.cancel()
        reloadDocsTask = Task { [weak self] in
            guard let self else { return }
            let query = SearchQuery(text, fieldKeys: keys)
            let limit = Self.listLimit

            // Each library answers in parallel and keeps its own order; the
            // merge below is what turns them into one list.
            var byIndex: [Int: [DocumentRow]] = [:]
            await withTaskGroup(of: (Int, [DocumentRow]).self) { group in
                for (i, lib) in libs.enumerated() {
                    let libID = lib.id, store = lib.store
                    group.addTask {
                        var rows = (try? await store.listDocuments(
                            selection: sel, query: query, sort: sortField,
                            ascending: asc, limit: limit)) ?? []
                        for j in rows.indices {
                            rows[j].library = libID
                            for k in rows[j].tags.indices { rows[j].tags[k].library = libID }
                        }
                        return (i, rows)
                    }
                }
                for await (i, rows) in group { byIndex[i] = rows }
            }
            guard !Task.isCancelled else { return }

            let rows = Self.merge((0..<libs.count).map { byIndex[$0] ?? [] },
                                  sort: sortField, ascending: asc, limit: limit)
            self.documents = rows
            // Drop selections that no longer exist so the inspector cannot go stale.
            let live = Set(rows.map(\.id))
            let kept = self.selectedIDs.intersection(live)
            if kept != self.selectedIDs { self.selectedIDs = kept }
            if self.selectedIDs.isEmpty { self.detail = nil }
        }
    }
    private var reloadDocsTask: Task<Void, Never>?

    /// k-way merge of per-library results that are each already sorted the way
    /// the user asked for.
    ///
    /// The comparison has to happen here rather than in SQL because no single
    /// database sees all the rows. `DocumentSort` is the same comparator the
    /// table headers use, so the merged order matches what a column header
    /// promises.
    static func merge(_ lists: [[DocumentRow]], sort: SortField,
                      ascending: Bool, limit: Int) -> [DocumentRow] {
        let lists = lists.filter { !$0.isEmpty }
        if lists.count <= 1 { return Array((lists.first ?? []).prefix(limit)) }

        // Relevance is an FTS rank, and two indexes' ranks are not on the same
        // scale — comparing them would silently favour the smaller library. So
        // search results are interleaved in each library's own order instead.
        if sort == .relevance {
            var out: [DocumentRow] = []
            var depth = 0
            while out.count < limit {
                let round = lists.filter { depth < $0.count }
                if round.isEmpty { break }
                for list in round {
                    out.append(list[depth])
                    if out.count == limit { break }
                }
                depth += 1
            }
            return out
        }

        let comparator = DocumentSort(field: sort, order: ascending ? .forward : .reverse)
        var cursors = [Int](repeating: 0, count: lists.count)
        var out: [DocumentRow] = []
        out.reserveCapacity(min(limit, lists.reduce(0) { $0 + $1.count }))
        while out.count < limit {
            var pick: Int?
            for i in lists.indices where cursors[i] < lists[i].count {
                guard let best = pick else { pick = i; continue }
                if comparator.compare(lists[i][cursors[i]],
                                      lists[best][cursors[best]]) == .orderedAscending {
                    pick = i
                }
            }
            guard let pick else { break }
            out.append(lists[pick][cursors[pick]])
            cursors[pick] += 1
        }
        return out
    }

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
        guard selectedIDs.count == 1, let ref = selectedIDs.first,
              let lib = library(ref.library) else {
            if selectedIDs.isEmpty { detail = nil }
            return
        }
        let libID = lib.id
        detailTask = Task { [weak self] in
            guard let self else { return }
            var d = try? await lib.store.detail(ref.doc)
            if d != nil {
                d!.row.library = libID
                for i in d!.tags.indices { d!.tags[i].library = libID }
                for i in d!.row.tags.indices { d!.row.tags[i].library = libID }
            }
            guard !Task.isCancelled else { return }
            self.detail = d
        }
    }

    // MARK: - Per-library dispatch

    /// The library a row came from. Rows always carry their library, so a miss
    /// means the library was closed between the fetch and the action.
    private func library(of row: DocumentRow) -> Library? { library(row.library) }

    /// Rows grouped by owning library, for the actions that run as one batch
    /// inside a single `Indexer` or `Store`.
    private func grouped(_ rows: [DocumentRow]) -> [(library: Library, rows: [DocumentRow])] {
        var order: [LibraryID] = []
        var byLibrary: [LibraryID: [DocumentRow]] = [:]
        for row in rows {
            if byLibrary[row.library] == nil { order.append(row.library) }
            byLibrary[row.library, default: []].append(row)
        }
        return order.compactMap { id in library(id).map { ($0, byLibrary[id] ?? []) } }
    }

    // MARK: - Watching

    /// One watcher per library, over that library's root, feeding that
    /// library's pipeline. Libraries never see each other's changes.
    private func startWatching(_ lib: Library) {
        lib.watcher?.stop()
        guard let indexer = lib.indexer else { return }
        let watcher = FileWatcher { changed in
            Task { await indexer.handleChanges(paths: changed) }
        }
        watcher.start(paths: [lib.root.path])
        lib.watcher = watcher
    }

    /// Rescans one library, or every open one when none is named.
    func reindex(_ lib: Library? = nil) {
        let targets = lib.map { [$0] } ?? libraries
        Task {
            var changed = 0
            var ran = false
            for lib in targets {
                guard let n = await lib.indexer.indexAll() else { continue }
                changed += n
                ran = true
            }
            // A rescan already under way picks this request up; saying
            // "up to date" before it finishes would be wrong.
            guard ran else { return }
            let scope = targets.count == 1 ? targets[0].displayName : "\(targets.count) libraries"
            if changed == 0 { notify("\(scope) is up to date.", .info) }
            else { notify("Indexed \(changed) new or changed document\(changed == 1 ? "" : "s") in \(scope).") }
        }
    }
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
        Task {
            var n = 0
            for (lib, rows) in grouped(rows) {
                n += await lib.indexer.reprocess(ids: rows.map(\.doc))
            }
            switch n {
            case 0: notify("Nothing to reprocess — those files are no longer on disk.", .info)
            case 1: notify("Reprocessed “\(rows.first?.displayTitle ?? "document")”.")
            default: notify("Reprocessed \(n) documents.")
            }
        }
    }

    // MARK: - Model enrichment

    /// Manual trigger for the model pass over documents that are already
    /// indexed. Deliberately separate from Reprocess: this asks the model
    /// again and touches nothing else.
    func analyze(_ rows: [DocumentRow]) {
        analyze(grouped(rows).map { ($0.library, $0.rows.map(\.doc)) },
                subject: rows.count == 1
                ? rows[0].url.lastPathComponent : "\(rows.count) documents")
    }

    /// Runs the model over every open library. The expensive one, so the caller
    /// is expected to have asked first.
    func analyzeLibrary() {
        Task {
            var work: [(Library, [Int64])] = []
            var total = 0
            for lib in libraries {
                let ids = (try? await lib.store.allDocumentIDs()) ?? []
                guard !ids.isEmpty else { continue }
                work.append((lib, ids))
                total += ids.count
            }
            guard !work.isEmpty else {
                notify("There is nothing indexed yet.", .info)
                return
            }
            analyze(work, subject: "\(total) documents")
        }
    }

    private func analyze(_ work: [(Library, [Int64])], subject: String) {
        let work = work.filter { !$0.1.isEmpty }
        guard !work.isEmpty else { return }
        Task {
            var combined = Indexer.AnalyzeSummary()
            for (lib, ids) in work {
                // Settings are saved on a chained task, so a run started right
                // after a change in the settings pane could otherwise ask the
                // backend the user just switched away from.
                await lib.indexer.update(settings: lib.settings)
                let summary = await lib.indexer.analyze(ids: ids)
                combined.updated += summary.updated
                combined.skipped += summary.skipped
                combined.failed += summary.failed
                combined.blocked = combined.blocked ?? summary.blocked
            }
            // Re-probing costs a round trip, but a run that just failed is
            // exactly when the status shown in Settings is worth correcting.
            modelStatus = await intelligence.status()
            report(combined, subject: subject)
        }
    }

    /// A run that never started, or one where the model answered nothing at
    /// all, is a problem to acknowledge. Anything else is a result, however
    /// partial, and goes by as a toast.
    private func report(_ s: Indexer.AnalyzeSummary, subject: String) {
        if let blocked = s.blocked {
            errorMessage = "Could not analyze \(subject): \(blocked)"
            return
        }
        if s.updated == 0, s.failed == 0 {
            notify("Nothing to analyze — no indexed text in \(subject).", .info)
            return
        }
        if s.updated == 0 {
            errorMessage = "The model did not answer for any of \(subject). Check its status in Settings › Intelligence."
            return
        }
        var parts = ["Analyzed \(s.updated) document\(s.updated == 1 ? "" : "s")"]
        if s.skipped > 0 { parts.append("\(s.skipped) had no text") }
        if s.failed > 0 { parts.append("\(s.failed) the model could not answer for") }
        notify(parts.joined(separator: ", ") + ".", s.failed > 0 ? .warning : .success)
    }

    /// Re-asks the configured backend whether it is reachable. The Test button
    /// in Settings, and anything else that wants a fresh answer.
    func refreshModelStatus() {
        Task {
            await intelligence.update(settings: settings)
            modelStatus = await intelligence.refreshStatus()
        }
    }

    func optimize(_ rows: [DocumentRow]) {
        Task {
            var count = 0
            var saved: Int64 = 0
            for (lib, rows) in grouped(rows) {
                let result = await lib.indexer.optimize(ids: rows.map(\.doc))
                count += result.count
                saved += result.saved
            }
            if count == 0 { notify("Nothing to optimize — these files are already compact.", .info) }
            else { notify("Optimized \(count) file\(count == 1 ? "" : "s"), saved \(ByteFormat.string(saved)).") }
        }
    }

    func rename(_ rows: [DocumentRow], template: String) {
        Task {
            var n = 0
            for (lib, rows) in grouped(rows) {
                n += await lib.indexer.rename(ids: rows.map(\.doc), template: template)
            }
            if n == 0 { notify("No files needed renaming.", .info) }
            else { notify("Renamed \(n) file\(n == 1 ? "" : "s").") }
        }
    }

    func move(_ rows: [DocumentRow], to destination: URL) {
        Task {
            var moved = 0
            for (lib, rows) in grouped(rows) {
                moved += await lib.indexer.move(ids: rows.map(\.doc), to: destination)
            }
            if moved == 0 { notify("Those documents are already in “\(destination.lastPathComponent)”.", .info) }
            else { notify("Moved \(moved) document\(moved == 1 ? "" : "s") to “\(destination.lastPathComponent)”.") }
        }
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
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    try? FileManager.default.trashItem(at: row.url, resultingItemURL: nil)
                    try? await lib.store.deleteDocument(row.doc)
                }
            }
            refreshAll()
            notify(rows.count == 1 ? "Moved “\(rows[0].displayTitle)” to the Trash."
                                   : "Moved \(rows.count) documents to the Trash.")
        }
    }

    /// Files documents into a second folder as Finder aliases, leaving the
    /// master where it is. This is what a plain drag onto a folder does.
    func createAliases(_ rows: [DocumentRow], in folder: URL) {
        Task {
            var made = 0
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    guard row.url.deletingLastPathComponent().path != folder.path else { continue }
                    guard let created = try? AliasManager.createAlias(to: row.url, in: folder) else { continue }
                    try? await lib.store.recordAlias(docID: row.doc, tagID: nil, path: created.path)
                    try? await lib.store.logProcessing(docID: row.doc, action: "aliased",
                                                       detail: "Also filed under \(folder.lastPathComponent)",
                                                       confidence: nil, rule: nil, from: row.path,
                                                       to: created.path, approved: true)
                    made += 1
                }
            }
            refreshAll()
            if made == 0 { notify("Those documents are already in that folder.", .info) }
            else {
                notify("Filed \(made) document\(made == 1 ? "" : "s") in “\(folder.lastPathComponent)” as \(made == 1 ? "an alias" : "aliases").")
            }
        }
    }

    /// Removes an alias placement without touching the master file.
    func removeAlias(_ row: DocumentRow, inFolder folder: String) {
        guard let lib = library(of: row) else { return }
        Task {
            for alias in ((try? await lib.store.aliases(for: row.doc)) ?? [])
            where alias.path.hasPrefix(folder + "/") {
                AliasManager.removeAlias(at: alias.path)
                try? await lib.store.deleteAlias(id: alias.id)
            }
            refreshAll()
        }
    }

    // MARK: - Tags

    /// Tagging a mixed selection tags each row in its own library, creating the
    /// tag there if it is missing. Two libraries can carry the same tag name
    /// without it being one tag.
    func addTag(_ name: String, to rows: [DocumentRow]) {
        Task {
            for (lib, rows) in grouped(rows) {
                guard let id = try? await lib.store.tagID(named: name), id > 0 else { continue }
                for row in rows {
                    try? await lib.store.assign(tag: id, to: row.doc)
                    await lib.indexer.syncAliases(docID: row.doc, target: row.url)
                }
            }
            refreshAll()
            reloadDetail()
        }
    }

    /// A tag belongs to one library, so this only touches the rows from it.
    func removeTag(_ tag: Tag, from rows: [DocumentRow]) {
        guard let lib = library(tag.library) else { return }
        Task {
            for row in rows where row.library == tag.library {
                try? await lib.store.unassign(tag: tag.tagID, from: row.doc)
                await lib.indexer.syncAliases(docID: row.doc, target: row.url)
            }
            refreshAll()
            reloadDetail()
        }
    }

    /// Turns a tag the model proposed into a real assignment.
    func acceptTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library(of: row) else { return }
        Task {
            try? await lib.store.acceptTagSuggestion(suggestion.name, for: row.doc)
            await lib.indexer.syncAliases(docID: row.doc, target: row.url)
            refreshAll()
            reloadDetail()
        }
    }

    /// Dismisses a proposed tag without ever making it a real one.
    func discardTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library(of: row) else { return }
        Task {
            try? await lib.store.discardTagSuggestion(suggestion.name, for: row.doc)
            reloadDetail()
        }
    }

    func setTagMirroring(_ tag: Tag, enabled: Bool) {
        guard let lib = library(tag.library) else { return }
        Task {
            try? await lib.store.setTagMirroring(tag.tagID, enabled, folder: tag.folder)
            // Re-sync every document carrying the tag so disk matches immediately.
            let rows = (try? await lib.store.listDocuments(selection: .tag(tag.id), query: SearchQuery(""),
                                                           sort: .added, ascending: false, limit: 5000)) ?? []
            for row in rows { await lib.indexer.syncAliases(docID: row.doc, target: row.url) }
            refreshAll()
        }
    }

    /// New tags go to the library the sidebar selection belongs to.
    func createTag(named name: String, in lib: Library? = nil) {
        guard let lib = lib ?? activeLibrary else { return }
        Task { _ = try? await lib.store.tagID(named: name); refreshAll() }
    }

    func renameTag(_ tag: Tag, to name: String) {
        guard let lib = library(tag.library) else { return }
        Task {
            let survivor = (try? await lib.store.renameTag(tag.tagID, to: name)) ?? tag.tagID
            if selection == .tag(tag.id) {
                selection = .tag(TagRef(library: tag.library, tag: survivor))
            }
            refreshAll()
            reloadDetail()
        }
    }

    func setTagColor(_ tag: Tag, _ color: Int64) {
        guard let lib = library(tag.library) else { return }
        Task { try? await lib.store.setTagColor(tag.tagID, color); refreshAll(); reloadDetail() }
    }

    func deleteTag(_ tag: Tag) {
        guard let lib = library(tag.library) else { return }
        Task {
            try? await lib.store.deleteTag(tag.tagID)
            if selection == .tag(tag.id) { selection = .all }
            refreshAll()
        }
    }

    // MARK: - Finder tags

    /// Writing one changes the file's extended attributes, so it only ever
    /// happens on an explicit action, and the index is refreshed from whatever
    /// the disk ends up saying rather than from what we asked for.
    func addFinderTag(_ name: String, to rows: [DocumentRow]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows where FinderTags.add(clean, to: row.url) {
                    try? await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url))
                }
            }
            refreshAll()
            reloadDetail()
        }
    }

    func removeFinderTag(_ name: String, from rows: [DocumentRow]) {
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows where FinderTags.remove(name, from: row.url) {
                    try? await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url))
                }
            }
            if selection == .finderTag(name) { selection = .all }
            refreshAll()
            reloadDetail()
        }
    }

    // MARK: - Value icons

    /// Field values are matched across libraries, so an icon chosen for one is
    /// set everywhere the field exists.
    func setValueIcon(_ field: Field, value: String, icon: String?) {
        Task {
            for (lib, field) in librariesDefining(field) {
                try? await lib.store.setValueIcon(field: field, value: value, icon: icon)
            }
            refreshAll()
        }
    }

    // MARK: - Fields

    /// Each library's own copy of a field key, for the actions the merged field
    /// list has to apply everywhere at once.
    private func librariesDefining(_ field: Field) -> [(Library, Field)] {
        libraries.compactMap { lib in
            lib.fields.first { $0.key == field.key }.map { (lib, $0) }
        }
    }

    func setFieldValue(_ rows: [DocumentRow], field: Field, value: String?) {
        Task {
            for (lib, rows) in grouped(rows) {
                guard let owned = lib.fields.first(where: { $0.key == field.key }) else { continue }
                for row in rows {
                    try? await lib.store.setFieldValue(docID: row.doc, field: owned, value: value)
                }
            }
            reloadDetail()
            refreshAll()
        }
    }

    func setFieldValue(_ ref: DocumentRef, field: Field, value: String?) {
        guard let lib = library(ref.library),
              let owned = lib.fields.first(where: { $0.key == field.key }) else { return }
        Task {
            try? await lib.store.setFieldValue(docID: ref.doc, field: owned, value: value)
            reloadDetail()
            refreshAll()
        }
    }

    /// Renaming a value onto an existing one merges every matching document.
    func renameFieldValue(_ field: Field, from old: String, to new: String) {
        Task {
            var n = 0
            for (lib, field) in librariesDefining(field) {
                n += (try? await lib.store.renameFieldValue(field: field, from: old, to: new)) ?? 0
            }
            if case .field(let key, let value) = selection, key == field.key, value == old {
                selection = .field(field.key, new)
            }
            refreshAll()
            if n > 0 { notify("Renamed “\(old)” to “\(new)” on \(n) document\(n == 1 ? "" : "s").") }
        }
    }

    func deleteFieldValue(_ field: Field, value: String) {
        Task {
            for (lib, field) in librariesDefining(field) {
                try? await lib.store.deleteFieldValue(field: field, value: value)
            }
            if selection == .field(field.key, value) { selection = .all }
            refreshAll()
        }
    }

    func updateField(_ field: Field) {
        // An explicit choice in Settings supersedes one made in the list header.
        listColumns[visibility: "field.\(field.key)"] = .automatic
        Task {
            // The list shows one column per key, so a change to it has to reach
            // every library that has that key or the next refresh would undo it.
            for (lib, owned) in librariesDefining(field) {
                var updated = field
                updated.fieldID = owned.fieldID
                updated.library = lib.id
                try? await lib.store.updateField(updated)
            }
            refreshAll()
        }
    }

    /// Fields are a vocabulary the open libraries share — the centre pane shows
    /// one column per key however many libraries fill it — so a new one is
    /// added to every library rather than to a chosen one.
    func addCustomField(named name: String) {
        Task {
            for lib in libraries { _ = try? await lib.store.addCustomField(name: name) }
            refreshAll()
        }
    }

    func deleteField(_ field: Field) {
        Task {
            for (lib, owned) in librariesDefining(field) {
                try? await lib.store.deleteField(owned.fieldID)
            }
            if case .field(let key, _) = selection, key == field.key { selection = .all }
            refreshAll()
        }
    }

    // MARK: - Metadata editing

    func editMetadata(_ ref: DocumentRef, column: String, value: String?) {
        guard let lib = library(ref.library) else { return }
        Task {
            try? await lib.store.overwriteMetadataField(ref.doc, column: column, value: value?.nilIfBlank)
            reloadDetail()
            reloadDocuments()
        }
    }

    func setDocumentDate(_ ref: DocumentRef, _ date: Date?) {
        guard let lib = library(ref.library) else { return }
        Task {
            try? await lib.store.setDocumentDate(ref.doc, date)
            reloadDetail()
            reloadDocuments()
        }
    }

    // MARK: - Queue

    func approveAll() {
        Task {
            for lib in libraries {
                for entry in lib.queue where !entry.approved {
                    try? await lib.store.setProcessingApproved(entry.id, true)
                }
            }
            refreshAll()
        }
    }

    func setApproved(_ rows: [DocumentRow], _ approved: Bool) {
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    guard let entry = row.queue else { continue }
                    try? await lib.store.setProcessingApproved(entry.entryID, approved)
                }
            }
            refreshAll()
        }
    }

    // MARK: - Import

    var defaultImportDirectory: URL? {
        guard let lib = activeLibrary else { return nil }
        return lib.root.appendingPathComponent(lib.settings.scanDestination, isDirectory: true)
    }

    /// Where a scan or import triggered from the center pane should land: the
    /// folder currently selected in the sidebar, if any, else the inbox.
    var contextImportDirectory: URL? {
        if case .folder(let path) = selection { return URL(fileURLWithPath: path) }
        return defaultImportDirectory
    }

    func importFiles(_ urls: [URL], into destination: URL?, movingSource: Bool = false) {
        // A scan started from the menu bar has no explicit destination; follow
        // whatever the sidebar has selected, then fall back to the inbox.
        guard let dest = destination ?? contextImportDirectory else {
            errorMessage = "Open a library before importing."
            return
        }
        // Files land in whichever library owns the destination, so a drop into
        // one library's folder never ends up indexed by another.
        guard let lib = libraries.first(where: { $0.owns(path: dest.path) }) ?? activeLibrary else {
            errorMessage = "Open a library before importing."
            return
        }
        Task {
            let n = await lib.indexer.importFiles(urls, into: dest, movingSource: movingSource)
            if n == 0 { errorMessage = "Nothing could be imported from \(urls.count == 1 ? "that file" : "those files")." }
            else { notify("Imported \(n) document\(n == 1 ? "" : "s") into “\(dest.lastPathComponent)”.") }
        }
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
