import Foundation

extension AppModel {

    func approveAll() {
        Task {
            for lib in libraries { try? await lib.store.approveAllPending() }
            refreshAll()
            reloadDetail()
        }
    }

    func setApproved(_ rows: [DocumentRow], _ approved: Bool) {
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows { try? await lib.store.setDocumentApproved(row.doc, approved) }
            }
            refreshAll()
            reloadDetail()
        }
    }

    func discardGeneratedInfo(_ rows: [DocumentRow]) {
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    try? await lib.store.discardGeneratedInfo(row.doc)
                    await lib.indexer.syncAliases(docID: row.doc, target: row.url)
                }
            }
            refreshAll()
            reloadDetail()
            notify(rows.count == 1 ? "Discarded what was generated for “\(rows[0].filename)”."
                                   : "Discarded what was generated for \(rows.count) documents.")
        }
    }

    func file(_ row: DocumentRow, in primary: URL, alsoIn secondaries: Set<String>,
              approve: Bool, keepOriginal: Bool = true, optimize: Bool = false, advance: Bool = false) {
        guard let lib = library(of: row) else { return }
        guard lib.owns(path: primary.path) else {
            errorMessage = "“\(primary.lastPathComponent)” is outside \(lib.displayName). A document can only be filed within its own library."
            return
        }
        let outside = secondaries.filter { !lib.owns(path: $0) }
        guard outside.isEmpty else {
            errorMessage = "“\((outside.first! as NSString).lastPathComponent)” is outside \(lib.displayName). A document can only be filed within its own library."
            return
        }
        let next = advance ? rowAfter(row) : nil
        Task {
            let wanted = secondaries.subtracting([primary.path])
            let existing = ((try? await lib.store.aliases(for: row.doc)) ?? []).filter { $0.tagID == nil }
            var have: Set<String> = []

            // Unwanted aliases go first, so one sitting in the folder the file
            // is about to move into cannot push it to "name 2.pdf".
            for alias in existing {
                let folder = (alias.path as NSString).deletingLastPathComponent
                if wanted.contains(folder) { have.insert(folder); continue }
                AliasManager.removeAlias(at: alias.path, pointingTo: row.url)
                try? await lib.store.deleteAlias(id: alias.id)
            }

            var target = row.url
            var moved = false
            if Store.canonical(primary.standardizedFileURL.path) != Store.canonical(row.directory) {
                guard await lib.indexer.move(ids: [row.doc], to: primary) == 1,
                      let now = try? await lib.store.documentPath(row.doc) else {
                    errorMessage = "Could not move “\(row.filename)” to “\(primary.lastPathComponent)”. It was left where it is."
                    refreshAll()
                    return
                }
                target = URL(fileURLWithPath: now)
                moved = true
            }

            var added: [String] = []
            for folder in wanted.subtracting(have).sorted() {
                guard let created = try? AliasManager.createAlias(to: target, in: URL(fileURLWithPath: folder))
                else { continue }
                try? await lib.store.recordAlias(docID: row.doc, tagID: nil, path: created.path)
                try? await lib.store.logProcessing(docID: row.doc, action: "aliased",
                                                   detail: "Also filed under \((folder as NSString).lastPathComponent)",
                                                   confidence: nil, rule: nil, from: target.path,
                                                   to: created.path, approved: true)
                added.append((folder as NSString).lastPathComponent)
            }

            if approve {
                try? await lib.store.setDocumentApproved(row.doc, true)
                if !keepOriginal { try? await lib.store.deleteOriginalFile(for: row.doc) }
            }
            // After approval, so the original it saves is kept.
            var optimized: (count: Int, saved: Int64) = (0, 0)
            if optimize { optimized = await lib.indexer.optimize(ids: [row.doc]) }
            if let next { selectedIDs = [next] }
            refreshAll()
            reloadDetail()

            var parts: [String] = []
            if moved { parts.append("Moved to “\(primary.lastPathComponent)”") }
            if !added.isEmpty { parts.append("also filed in \(added.map { "“\($0)”" }.joined(separator: ", "))") }
            if optimized.count > 0 { parts.append("optimized, saving \(ByteFormat.string(optimized.saved))") }
            else if optimize { parts.append("already compact, so not optimized") }
            if parts.isEmpty { parts.append(approve ? "Approved" : "Nothing to change") }
            else if approve { parts.append("approved") }
            let text = parts.joined(separator: ", ")
            notify(text.prefix(1).uppercased() + text.dropFirst() + ".", parts == ["Nothing to change"] ? .info : .success)
        }
    }

    private func rowAfter(_ row: DocumentRow) -> DocumentRef? {
        guard let index = documents.firstIndex(where: { $0.id == row.id }) else { return nil }
        if index + 1 < documents.count { return documents[index + 1].id }
        return index > 0 ? documents[index - 1].id : nil
    }
}
