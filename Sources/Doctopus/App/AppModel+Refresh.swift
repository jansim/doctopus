import Foundation

extension AppModel {

    func decode<T: Decodable>(_ key: String) -> T? {
        guard let raw = Preferences.uiState(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    nonisolated static func attempt<T: Sendable>(
        _ body: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
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
            // Stands for the rest: an index that cannot answer this cannot
            // answer any of them, and should not pass for an empty library.
            async let s = Self.attempt { try await store.stats() }
            async let svList = (try? await store.savedViews()) ?? []

            let (t, tg, fs, ftg, lbl, qq, counted, svs) = await (tree, tagList, fieldList, finder, labels, q, s, svList)
            var facetMap: [String: [Facet]] = [:]
            for field in fs { facetMap[field.key] = (try? await store.facets(field: field)) ?? [] }
            FinderTags.learn(lbl)

            guard !Task.isCancelled else { return }
            let problem: String?
            switch counted {
            case .success(let counts):
                lib.stats = counts
                problem = nil
            case .failure(let error):
                lib.stats = Store.Stats()
                problem = "Could not read the index of \(lib.displayName) (\(error.localizedDescription)). What is shown may be incomplete."
            }
            if problem != self.refreshProblem {
                self.refreshProblem = problem
                if let problem { self.errorMessage = problem }
            }
            lib.folders = t
            lib.tags = tg
            lib.fields = fs.sorted { $0.position < $1.position }
            lib.savedViews = svs
            lib.finderTags = ftg
            lib.facets = facetMap
            lib.queue = qq.sorted { $0.at > $1.at }
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
            let rows = (try? await lib.store.listDocuments(
                selection: sel, query: query, sort: sortField, ascending: asc, limit: limit,
                ruleMatched: sel == .needsReview ? lib.ruleMatchedDocs : [])) ?? []
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
        guard selectedIDs.count == 1, let doc = selectedIDs.first else {
            if selectedIDs.isEmpty { detail = nil }
            return
        }
        detailTask = Task { [weak self] in
            guard let self else { return }
            let d = await self.loadDetail(doc)
            guard !Task.isCancelled else { return }
            self.detail = d
        }
    }

    func loadDetail(_ doc: Int64) async -> DocumentDetail? {
        guard let lib = library else { return nil }
        return try? await lib.store.detail(doc)
    }
}
