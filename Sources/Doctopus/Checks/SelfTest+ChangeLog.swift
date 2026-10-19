import Foundation

/// The library's change log, and reverting what is in it.
extension SelfTest {
    static func changeLog(store: Store, indexer: Indexer, root: URL) async {
        print("\nCHANGE LOG")
        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        guard let subject = rows.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            Check.that("the change log has a document to work on", false)
            return
        }
        let doc = subject.doc
        func title() async -> String? { (try? await store.detail(doc))?.row.title }
        func history() async -> [HistoryEvent] { (try? await store.history(for: doc, limit: 10_000)) ?? [] }

        let added = await history().last { $0.action == .added }
        Check.that("what brought a document into the library cannot be reverted",
                   added == nil || added?.revert == nil)

        let before = await title()
        let typed = "Typed for the change log"
        try? await store.change(doc: doc, "Title → \(typed)") { store in
            try store.overwriteMetadataField(doc, column: "title", value: typed)
        }
        let edit = await history().first
        Check.that("a hand edit is one change in the document's history",
                   edit?.action == .edited && edit?.detail == "Title → \(typed)" && edit?.revert == .rows,
                   edit?.detail ?? "nothing logged")
        let unchanged = await history().count
        try? await store.change(doc: doc, "Title → \(typed)") { store in
            try store.overwriteMetadataField(doc, column: "title", value: typed)
        }
        Check.that("an edit that changes nothing is not logged", await history().count == unchanged)

        let logged = (try? await store.changeLog(limit: 10)) ?? []
        Check.that("the library's change log holds it too, newest first",
                   logged.first?.id == edit?.id && zip(logged, logged.dropFirst()).allSatisfy { $0.id > $1.id })

        if let edit {
            do { try await indexer.revert(edit.id) } catch { Check.that("a hand edit reverts", false, "\(error)") }
            let reverted = await history()
            let restored = await title()
            Check.that("reverting it puts the title back", restored == before, restored ?? "no title")
            Check.that("…marks it reverted, so it cannot be reverted twice",
                       reverted.first { $0.id == edit.id }.map { $0.reverted && $0.revert == nil } == true)
            let revert = reverted.first
            Check.that("…and is logged as a change of its own, which can be reverted in turn",
                       revert?.action == .reverted && revert?.revert == .rows, revert?.detail ?? "nothing logged")
            if let revert {
                try? await indexer.revert(revert.id)
                Check.that("reverting the revert puts the edit back", await title() == typed)
                Check.that("…and the edit counts as in effect again",
                           await history().first { $0.id == edit.id }?.reverted == false)
            }
        }

        // A change to the library as a whole, cascading into documents.
        let tagName = "changelogcheck"
        let tagID = (try? await store.change(doc: nil, "Created tag “\(tagName)”") { store in
            try store.tagID(named: tagName)
        }) ?? 0
        try? await store.change(doc: doc, "Tagged “\(tagName)”") { store in
            try store.assign(tag: tagID, to: doc)
        }
        try? await store.change(doc: nil, "Deleted tag “\(tagName)”") { store in
            try store.deleteTag(tagID)
        }
        let deletion = ((try? await store.changeLog(limit: 1)) ?? []).first
        Check.that("a change to the library as a whole is logged without a document",
                   deletion?.docID == nil && deletion?.revert == .rows, deletion?.detail ?? "nothing logged")
        if let deletion {
            try? await indexer.revert(deletion.id)
            let tags = (try? await store.tags(for: doc)) ?? []
            Check.that("reverting a tag's deletion brings it back onto the documents it was on",
                       tags.contains { $0.tagID == tagID && $0.name == tagName })
            let found = (try? await store.listDocuments(selection: .all, query: SearchQuery(tagName),
                                                        sort: .relevance, ascending: false)) ?? []
            Check.that("…and into their search text", found.contains { $0.doc == doc })
        }
        try? await store.deleteTag(tagID)

        // A move is taken back on disk, and stays on record.
        let original = subject.url
        let moved = root.appendingPathComponent("Work/changelog-\(subject.filename)")
        if (try? FileManager.default.moveItem(at: original, to: moved)) != nil {
            try? await store.updatePath(doc, to: moved.path)
            try? await store.logProcessing(docID: doc, action: .moved, detail: "change log move",
                                           rule: nil, from: original.path, to: moved.path, approved: true)
            let move = await history().first
            Check.that("a move can be reverted", move?.action == .moved && move?.revert == .file)
            if let move { try? await indexer.revert(move.id) }
            Check.that("reverting it puts the file back",
                       FileManager.default.fileExists(atPath: original.path)
                           && (try? await store.documentPath(doc)) == original.path)
            Check.that("…and keeps the move in the history, marked",
                       await history().first { $0.id == move?.id }?.reverted == true)
        }

        let total = (try? await store.eventCount()) ?? 0
        try? await store.setHistoryLimit(5)
        let kept = (try? await store.eventCount()) ?? 0
        try? await store.change(doc: doc, "Title → kept") { store in
            try store.overwriteMetadataField(doc, column: "title", value: "kept")
        }
        Check.that("the log keeps only as many changes as it is set to",
                   kept == min(5, total) && ((try? await store.eventCount()) ?? 0) == min(5, total + 1),
                   "\(kept) of \(total) kept")
        try? await store.setHistoryLimit(0)
        try? await store.overwriteMetadataField(doc, column: "title", value: before)
        print("  \(total) change(s) logged before trimming to 5")
    }
}
