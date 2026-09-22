import Foundation

extension AppModel {

    func decode<T: Decodable>(_ key: String) -> T? {
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
            var allSavedViews: [SavedView] = []
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
                async let svList = (try? await store.savedViews()) ?? []

                let (t, tg, fs, ftg, lbl, qq, ss, svs) = await (tree, tagList, fieldList, finder, labels, q, s, svList)
                var facetMap: [String: [Facet]] = [:]
                for field in fs { facetMap[field.key] = (try? await store.facets(field: field)) ?? [] }

                let libID = lib.id
                let stampedTags = tg.map { var x = $0; x.library = libID; return x }
                let stampedFields = fs.map { var x = $0; x.library = libID; return x }
                let stampedSavedViews = svs.map { var x = $0; x.library = libID; return x }
                lib.folders = t
                lib.tags = stampedTags
                lib.fields = stampedFields
                lib.savedViews = stampedSavedViews
                lib.finderTags = ftg
                lib.facets = facetMap
                lib.queue = qq
                lib.stats = ss

                folders += t
                tags += stampedTags
                fields += stampedFields
                allSavedViews += stampedSavedViews
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
            self.savedViews = allSavedViews
            self.finderTags = finderTags
            self.fields = Self.mergeFields(fields)
            self.facets = facets
            self.queue = queue
            self.stats = stats
            // A passive refresh (e.g. a Finder change) must not snap an
            // expanded "Load More" list back down to the first page.
            self.reloadDocuments(resetPaging: false)
        }
    }

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

    private static func mergeFields(_ fields: [Field]) -> [Field] {
        var seen = Set<String>()
        var merged: [Field] = []
        for field in fields where seen.insert(field.key).inserted {
            merged.append(field)
        }
        return merged.sorted { $0.position < $1.position }
    }

    private func librariesInScope(for selection: Selection) -> [Library] {
        switch selection {
        case .tag(let ref): return library(ref.library).map { [$0] } ?? []
        case .folder(let path): return libraries.filter { $0.owns(path: path) }
        default: return libraries
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
        let libs = librariesInScope(for: sel)
        guard !libs.isEmpty else { documents = []; selectedIDs = []; detail = nil; hasMoreDocuments = false; return }
        reloadDocsTask?.cancel()
        reloadDocsTask = Task { [weak self] in
            guard let self else { return }
            let query = SearchQuery(text, fieldKeys: keys)
            let limit = self.currentLimit

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
            self.hasMoreDocuments = rows.count >= limit
            let live = Set(rows.map(\.id))
            let kept = self.selectedIDs.intersection(live)
            if kept != self.selectedIDs { self.selectedIDs = kept }
            if self.selectedIDs.isEmpty { self.detail = nil }
        }
    }

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
        guard selectedIDs.count == 1, let ref = selectedIDs.first,
              let lib = library(ref.library) else {
            if selectedIDs.isEmpty { detail = nil }
            return
        }
        detailTask = Task { [weak self] in
            guard let self else { return }
            let d = await self.loadDetail(ref, from: lib)
            guard !Task.isCancelled else { return }
            self.detail = d
        }
    }

    func loadDetail(_ ref: DocumentRef) async -> DocumentDetail? {
        guard let lib = library(ref.library) else { return nil }
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
