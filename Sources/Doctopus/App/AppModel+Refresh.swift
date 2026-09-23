import Foundation

extension AppModel {

    func decode<T: Decodable>(_ key: String) -> T? {
        guard let raw = Preferences.uiState(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func refreshAll() {
        reloadTask?.cancel()
        guard let lib = library else {
            reloadDocuments()
            return
        }
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let store = lib.store
            async let tree = (try? await store.folderTree()) ?? []
            async let tagList = (try? await store.tags()) ?? []
            async let fieldList = (try? await store.fields()) ?? []
            async let finder = (try? await store.finderTags()) ?? []
            async let labels = (try? await store.finderTagLabels()) ?? [:]
            async let q = (try? await store.processingQueue()) ?? []
            async let s = (try? await store.stats()) ?? Store.Stats()
            async let svList = (try? await store.savedViews()) ?? []

            let (t, tg, fs, ftg, lbl, qq, ss, svs) = await (tree, tagList, fieldList, finder, labels, q, s, svList)
            var facetMap: [String: [Facet]] = [:]
            for field in fs { facetMap[field.key] = (try? await store.facets(field: field)) ?? [] }
            FinderTags.learn(lbl)

            guard !Task.isCancelled else { return }
            let libID = lib.id
            lib.folders = t
            lib.tags = tg.map { var x = $0; x.library = libID; return x }
            lib.fields = fs.map { var x = $0; x.library = libID; return x }
                .sorted { $0.position < $1.position }
            lib.savedViews = svs.map { var x = $0; x.library = libID; return x }
            lib.finderTags = ftg
            lib.facets = facetMap
            lib.queue = qq.sorted { $0.at > $1.at }
            lib.stats = ss
            self.refreshRuleMatches()
            // A passive refresh (e.g. a Finder change) must not snap an
            // expanded "Load More" list back down to the first page.
            self.reloadDocuments(resetPaging: false)
        }
    }

    private static let pageBatchSize = 500

    func loadMore() {
        guard hasMoreDocuments else { return }
        currentLimit += Self.pageBatchSize
        reloadDocuments(resetPaging: false)
    }

    func reloadDocuments(resetPaging: Bool = true) {
        if resetPaging { currentLimit = Self.pageBatchSize }
        let sel = selection, text = searchText, sortField = sort, asc = sortAscending
        let keys = Set(fields.map(\.key))
        guard let lib = library else {
            documents = []; selectedIDs = []; detail = nil; hasMoreDocuments = false
            return
        }
        reloadDocsTask?.cancel()
        reloadDocsTask = Task { [weak self] in
            guard let self else { return }
            let query = SearchQuery(text, fieldKeys: keys)
            let limit = self.currentLimit
            let libID = lib.id
            var rows = (try? await lib.store.listDocuments(
                selection: sel, query: query, sort: sortField, ascending: asc, limit: limit,
                ruleMatched: sel == .needsReview ? lib.ruleMatchedDocs : [])) ?? []
            for j in rows.indices {
                rows[j].library = libID
                for k in rows[j].tags.indices { rows[j].tags[k].library = libID }
            }
            guard !Task.isCancelled else { return }

            self.documents = rows
            self.hasMoreDocuments = rows.count >= limit
            let live = Set(rows.map(\.id))
            let kept = self.selectedIDs.intersection(live)
            if kept != self.selectedIDs { self.selectedIDs = kept }
            if self.selectedIDs.isEmpty { self.detail = nil }
        }
    }

    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.reloadDocuments()
        }
    }

    func reloadDetail() {
        detailTask?.cancel()
        guard selectedIDs.count == 1, let ref = selectedIDs.first else {
            if selectedIDs.isEmpty { detail = nil }
            return
        }
        detailTask = Task { [weak self] in
            guard let self else { return }
            let d = await self.loadDetail(ref)
            guard !Task.isCancelled else { return }
            self.detail = d
        }
    }

    func loadDetail(_ ref: DocumentRef) async -> DocumentDetail? {
        guard let lib = library, lib.id == ref.library else { return nil }
        return await loadDetail(ref, from: lib)
    }

    private func loadDetail(_ ref: DocumentRef, from lib: Library) async -> DocumentDetail? {
        let libID = lib.id
        guard var d = try? await lib.store.detail(ref.doc) else { return nil }
        d.row.library = libID
        for i in d.tags.indices { d.tags[i].library = libID }
        for i in d.row.tags.indices { d.row.tags[i].library = libID }
        for i in d.similarDocuments.indices {
            d.similarDocuments[i].library = libID
            for j in d.similarDocuments[i].tags.indices { d.similarDocuments[i].tags[j].library = libID }
        }
        return d
    }
}
