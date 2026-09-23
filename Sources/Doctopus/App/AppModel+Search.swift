import Foundation

struct GlobalSearchResult: Identifiable, Sendable {
    enum Category: String, Sendable {
        case document = "Document"
        case tag = "Tag"
        case correspondent = "Correspondent"
        case docType = "Document Type"
        case folder = "Folder"
        case savedView = "Smart Folder"
    }
    var id: String
    var category: Category
    var title: String
    var subtitle: String?
    var icon: String
    var document: DocumentRef?
    var path: String?
    var fieldKey: String?
    var tagRef: TagRef?
    var savedViewID: Int64?
}

enum URLSchemeHandler: Sendable {
    enum Action: Equatable, Sendable {
        case search(String)
        case `import`(String)
        case open(Int64)
        case verify
    }

    static func parse(_ url: URL) -> Action? {
        guard url.scheme == "doctopus" else { return nil }
        let host = url.host ?? url.path
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = comps?.queryItems ?? []
        func param(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        switch host {
        case "import":
            if let path = param("path") { return .import(path) }
        case "search":
            if let q = param("q") ?? param("query") { return .search(q) }
        case "open", "doc", "document":
            if let idStr = param("id"), let docID = Int64(idStr) { return .open(docID) }
        case "verify":
            return .verify
        default:
            break
        }
        return nil
    }
}

extension AppModel {

    func globalSearch(text: String, limit: Int = 20) -> [GlobalSearchResult] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let query = text.lowercased()
        var results: [GlobalSearchResult] = []

        for sv in savedViews where sv.name.lowercased().contains(query) {
            results.append(GlobalSearchResult(id: "sv-\(sv.id)", category: .savedView, title: sv.name, subtitle: sv.query, icon: sv.icon, savedViewID: sv.id))
        }

        for tag in distinctTags where tag.name.lowercased().contains(query) {
            results.append(GlobalSearchResult(id: "tag-\(tag.tagID)", category: .tag, title: tag.name, subtitle: "\(tag.count) document(s)", icon: "tag", tagRef: tag.id))
        }

        let taxonomies: [(key: String, category: GlobalSearchResult.Category, icon: String)] = [
            ("correspondent", .correspondent, "person.2"),
            ("doc_type", .docType, "doc.on.doc"),
        ]
        for taxonomy in taxonomies {
            for f in facets[taxonomy.key] ?? [] where f.value.lowercased().contains(query) {
                results.append(GlobalSearchResult(id: "facet-\(taxonomy.key)-\(f.value)",
                                                  category: taxonomy.category, title: f.value,
                                                  subtitle: "\(f.count) document(s)",
                                                  icon: f.icon ?? taxonomy.icon, fieldKey: taxonomy.key))
            }
        }

        func collectFolders(_ nodes: [FolderNode]) {
            for n in nodes {
                if n.name.lowercased().contains(query) && !n.isRoot {
                    results.append(GlobalSearchResult(id: "folder-\(n.path)", category: .folder, title: n.name, subtitle: n.path, icon: "folder", path: n.path))
                }
                collectFolders(n.children)
            }
        }
        collectFolders(folders)

        for doc in documents where doc.displayTitle.lowercased().contains(query) || doc.filename.lowercased().contains(query) {
            results.append(GlobalSearchResult(id: "doc-\(doc.library)-\(doc.doc)", category: .document,
                                              title: doc.displayTitle, subtitle: doc.filename,
                                              icon: "doc.text", document: doc.id))
        }

        return Array(results.prefix(limit))
    }

    func saveCurrentSearchAsSmartFolder(name: String, icon: String = "line.3.horizontal.decrease.circle") {
        guard let lib = activeLibrary else { return }
        Task {
            let sv = SavedView(id: 0, name: name, icon: icon, query: searchText,
                               sortKey: sort.storageKey, ascending: sortAscending,
                               viewMode: viewMode.rawValue, position: Int64(savedViews.count * 10))
            do { _ = try await lib.store.upsertSavedView(sv) }
            catch { report(error, "save the smart folder “\(name)”"); return }
            refreshAll()
            notify("Saved smart folder “\(name)”.", .success)
        }
    }

    func deleteSavedView(_ sv: SavedView) {
        guard let lib = library(sv.library) ?? activeLibrary else { return }
        Task {
            do { try await lib.store.deleteSavedView(sv.id) }
            catch { report(error, "delete the smart folder “\(sv.name)”"); return }
            if case .savedView(let id, _) = selection, id == sv.id {
                selection = .all
            }
            refreshAll()
            notify("Deleted smart folder “\(sv.name)”.", .info)
        }
    }

    func selectSavedView(_ sv: SavedView) {
        // The query, sort and view mode are adopted by `selection`'s observer,
        // which every path into a smart folder goes through.
        selection = .savedView(id: sv.id, query: sv.query)
    }

    func adoptSavedViewSettings(_ sv: SavedView) {
        if let sk = sv.sortKey, let sortField = SortField(storageKey: sk) {
            sort = sortField
            sortAscending = sv.ascending
        }
        if let vm = sv.viewMode, let mode = ViewMode(rawValue: vm) {
            viewMode = mode
        }
    }

    func handleURL(_ url: URL) {
        guard let action = URLSchemeHandler.parse(url) else { return }
        switch action {
        case .import(let path):
            let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            importFiles([fileURL], into: nil)
        case .search(let q):
            selection = .all
            searchText = q
        case .open(let docID):
            selection = .all
            if let lib = activeLibrary {
                selectedIDs = [DocumentRef(library: lib.id, doc: docID)]
            }
        case .verify:
            verifyLibrary()
        }
    }
}
