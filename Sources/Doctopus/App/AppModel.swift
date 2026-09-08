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
    let store: Store
    let llm = LLMService()
    private(set) var indexer: Indexer!
    private var watcher: FileWatcher?

    // Persisted configuration
    var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            let s = settings
            Task { await s.save(to: store); await indexer.update(settings: s) }
        }
    }

    // Sidebar data
    var roots: [Store.Root] = []
    var folders: [FolderNode] = []
    var tags: [Tag] = []
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
    }

    private func persist(_ key: String, _ value: String?) {
        guard let value else { return }
        Task { try? await store.setSetting(key, value) }
    }

    /// Mirrors a header-menu show/hide onto the field, which is what the rest
    /// of the app (and Settings) reads.
    private func adoptColumnVisibility() {
        for field in fields {
            let visibility = listColumns[visibility: "field.\(field.key)"]
            guard visibility != .automatic else { continue }
            let shown = visibility == .visible
            guard shown != field.showInList else { continue }
            let updated = Field(id: field.id, key: field.key, name: field.name,
                                builtinColumn: field.builtinColumn, icon: field.icon,
                                showInSidebar: field.showInSidebar, showInList: shown,
                                position: field.position, enabled: field.enabled)
            Task { try? await store.updateField(updated); refreshAll() }
        }
    }

    /// Document date rather than added date, so the default order is the one
    /// the Date column shows — and its header carries the sort arrow.
    var sort: SortField = .docDate { didSet { if !batchingSort { reloadDocuments() } } }
    var sortAscending = false { didSet { if !batchingSort { reloadDocuments() } } }
    private var batchingSort = false

    /// Field and direction together, so a header click runs one query.
    func setSort(_ field: SortField, ascending: Bool) {
        guard field != sort || ascending != sortAscending else { return }
        batchingSort = true
        sort = field
        sortAscending = ascending
        batchingSort = false
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

    /// `storeURL` exists for the headless UI checks, which drive a real model
    /// against a throwaway index instead of the user's own.
    init(storeURL: URL? = nil) {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("Doctopus", isDirectory: true)
        let url = storeURL ?? dir.appendingPathComponent("index.sqlite")
        do {
            store = try Store(url: url)
        } catch {
            // A corrupt index is recoverable — the disk still holds every document.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("index-\(Int(Date().timeIntervalSince1970)).sqlite")
            try? FileManager.default.moveItem(at: url, to: backup)
            store = try! Store(url: url)
        }
    }

    func bootstrap() async {
        settings = await AppSettings.load(from: store)
        viewMode = settings.viewMode
        if let saved: TableColumnCustomization<DocumentRow> = await decode(UIState.columns) {
            listColumns = saved
        }
        if let saved: [String] = await decode(UIState.collapsed) {
            collapsedFolders = Set(saved)
        }

        // The callbacks hop back to the main actor; the actors themselves stay off it.
        indexer = Indexer(
            store: store, llm: llm, settings: settings,
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onDataChanged: { [weak self] in Task { @MainActor in self?.refreshAll() } })

        if (try? await store.rules())?.isEmpty ?? true {
            for rule in Router.starterRules { _ = try? await store.upsertRule(rule) }
        }

        modelStatus = await llm.probe()

        // Load the roots before anything reads them: `refreshAll` runs in a
        // detached task, so checking `roots` right after it would always lose
        // the race and skip the first index.
        roots = (try? await store.roots()) ?? []
        refreshAll()
        startWatching()

        if !roots.isEmpty { await indexer.indexAll() }
    }

    // MARK: - Refresh

    private func decode<T: Decodable>(_ key: String) async -> T? {
        guard let raw = try? await store.setting(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func refreshAll() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let rootList = (try? await store.roots()) ?? []
            let paths = rootList.map(\.path)
            async let tree = (try? await store.folderTree(roots: paths)) ?? []
            async let tagList = (try? await store.tags()) ?? []
            async let fieldList = (try? await store.fields()) ?? []
            async let q = (try? await store.processingQueue()) ?? []
            async let s = (try? await store.stats()) ?? Store.Stats()

            let (t, tg, fs, qq, ss) = await (tree, tagList, fieldList, q, s)
            var facetMap: [String: [Facet]] = [:]
            for field in fs {
                facetMap[field.key] = (try? await store.facets(field: field)) ?? []
            }
            guard !Task.isCancelled else { return }
            self.roots = rootList
            self.folders = t
            self.tags = tg
            self.fields = fs
            self.facets = facetMap
            self.queue = qq
            self.stats = ss
            self.reloadDocuments()
        }
    }

    func reloadDocuments() {
        let sel = selection, text = searchText, sortField = sort, asc = sortAscending
        let keys = Set(fields.map(\.key))
        Task { [weak self] in
            guard let self else { return }
            let query = SearchQuery(text, fieldKeys: keys)
            let rows = (try? await store.listDocuments(selection: sel, query: query,
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
        guard selectedIDs.count == 1, let id = selectedIDs.first else {
            if selectedIDs.isEmpty { detail = nil }
            return
        }
        detailTask = Task { [weak self] in
            guard let self else { return }
            let d = try? await store.detail(id)
            guard !Task.isCancelled else { return }
            self.detail = d
        }
    }

    // MARK: - Roots & watching

    private func startWatching() {
        watcher?.stop()
        guard !roots.isEmpty else { return }
        let paths = roots.map(\.path)
        watcher = FileWatcher { [weak self] changed in
            Task { @MainActor in
                guard let self else { return }
                await self.indexer.handleChanges(paths: changed)
            }
        }
        watcher?.start(paths: paths)
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index Folder"
        panel.message = "Choose a folder to index in place. Nothing will be moved or renamed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = try? await store.addRoot(path: url.path, bookmark: bookmark)
            roots = (try? await store.roots()) ?? []
            refreshAll()
            startWatching()
            await indexer.indexAll()
        }
    }

    func removeRoot(_ root: Store.Root) {
        Task {
            try? await store.removeRoot(id: root.id)
            roots = (try? await store.roots()) ?? []
            refreshAll()
            startWatching()
        }
    }

    func reindex() { Task { await indexer.indexAll() } }
    func cancelIndexing() { Task { await indexer.cancel() } }

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
            let rows = (try? await store.listDocuments(selection: .tag(tag.id), query: SearchQuery(""),
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
            if selection == .tag(tag.id) { selection = .tag(survivor) }
            refreshAll()
            reloadDetail()
        }
    }

    func setTagColor(_ tag: Tag, _ color: Int64) {
        Task { try? await store.setTagColor(tag.id, color); refreshAll(); reloadDetail() }
    }

    func deleteTag(_ tag: Tag) {
        Task {
            try? await store.deleteTag(tag.id)
            if selection == .tag(tag.id) { selection = .all }
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
        guard let root = roots.first else { return nil }
        return URL(fileURLWithPath: root.path).appendingPathComponent(settings.scanDestination, isDirectory: true)
    }

    /// Where a scan or import triggered from the center pane should land: the
    /// folder currently selected in the sidebar, if any, else the inbox.
    var contextImportDirectory: URL? {
        if case .folder(let path) = selection { return URL(fileURLWithPath: path) }
        return defaultImportDirectory
    }

    func importFiles(_ urls: [URL], into destination: URL?, movingSource: Bool = false) {
        guard let root = roots.first else {
            errorMessage = "Add a folder to index before importing."
            return
        }
        // A scan started from the menu bar has no explicit destination; follow
        // whatever the sidebar has selected, then fall back to the inbox.
        let dest = destination ?? contextImportDirectory ?? URL(fileURLWithPath: root.path)
        Task { await indexer.importFiles(urls, into: dest, rootID: root.id, movingSource: movingSource) }
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
