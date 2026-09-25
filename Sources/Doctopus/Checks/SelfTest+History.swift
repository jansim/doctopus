import Foundation

/// What happened to a document, and taking it back.
extension SelfTest {
    static func recentlyReviewed(store: Store) async {
        print("\nRECENTLY REVIEWED (same browser, review columns)")
        func reviewed() async -> [DocumentRow] {
            (try? await store.listDocuments(selection: .reviewed, query: SearchQuery(""),
                                            sort: .added, ascending: false)) ?? []
        }
        let current = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                      sort: .added, ascending: false)) ?? []
        if current.count >= 2 {
            let first = current[0], second = current[1]
            try? await store.setDocumentApproved(first.doc, true)
            try? await Task.sleep(for: .milliseconds(20))
            try? await store.setDocumentApproved(second.doc, true)
            var queued = await reviewed()
            Check.that("an approval lands in Recently Reviewed, newest approval first",
                       queued.prefix(2).map(\.doc) == [second.doc, first.doc]
                           && queued.prefix(2).allSatisfy { $0.queue?.approved == true })
            try? await store.setDocumentApproved(first.doc, true)
            queued = await reviewed()
            Check.that("approving again moves it back to the top", queued.first?.doc == first.doc)
            try? await store.setDocumentApproved(second.doc, false)
            queued = await reviewed()
            Check.that("sending it back for review takes it out",
                       !queued.contains { $0.doc == second.doc })
            try? await store.setDocumentApproved(second.doc, true)
        }
        for row in await reviewed().prefix(4) {
            guard let q = row.queue else { continue }
            print("  \(row.filename.padded(36)) \(q.action.rawValue.padded(10)) "
                  + "\(q.approved ? "approved    " : "needs review") \(q.detail ?? "")")
        }
    }

    static func queue(store: Store) async {
        print("\nQUEUE")
        for entry in ((try? await store.processingQueue(limit: 8)) ?? []) {
            print("  \(entry.action.rawValue.padded(10)) \(entry.filename.padded(34)) \(entry.detail ?? "")")
        }
    }

    static func revertibleOptimisation(store: Store, indexer: Indexer, rows: [DocumentRow]) async {
        print("\nREVERTIBLE OPTIMISATION")
        if let targetDoc = rows.first(where: { $0.ext == "pdf" }) {
            let origSize = targetDoc.size
            if let hash = FileScanner.hash(targetDoc.url) {
                _ = try? await store.saveOriginalFile(for: targetDoc.doc, from: targetDoc.url, hash: hash)
                try? await store.setSizes(targetDoc.doc, size: origSize / 2, originalSize: origSize)
                let origURL = try? await store.originalFileURL(for: targetDoc.doc)
                Check.that("pre-optimization original file is preserved", origURL != nil && FileManager.default.fileExists(atPath: origURL!.path))
                let reverted = await indexer.revertOptimization(ids: [targetDoc.doc]).done == 1
                Check.that("revert optimization restores document size and removes original_size", reverted)
            }
        }
    }

    static func recentlyDeleted(store: Store, rows: [DocumentRow]) async {
        print("\nRECENTLY DELETED")
        if let victim = rows.first(where: { $0.directory.hasSuffix("Personal") }) ?? rows.first {
            let tagID = (try? await store.tagID(named: "doctopus-restore")) ?? 0
            try? await store.assign(tag: tagID, to: victim.doc)
            try? await store.softDelete(victim.doc, trashPath: nil)

            let listed = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                         sort: .added, ascending: false)) ?? []
            let inTrash = (try? await store.listDocuments(selection: .deleted, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? []
            let after = (try? await store.stats()) ?? Store.Stats()
            print("  deleted \(victim.filename): \(after.deleted) in Recently Deleted, "
                  + "\(after.total) still listed")
            Check.that("a deleted document leaves every ordinary listing",
                       !listed.contains { $0.doc == victim.doc })
            Check.that("…and is exactly what Recently Deleted holds",
                       inTrash.contains { $0.doc == victim.doc } && after.deleted == 1)
            Check.that("…and stops being searchable",
                       !((try? await store.listDocuments(
                            selection: .all, query: SearchQuery(victim.filename),
                            sort: .relevance, ascending: false)) ?? []).contains { $0.doc == victim.doc })
            Check.that("…but its row, and everything on it, is still there",
                       ((try? await store.tags(for: victim.doc)) ?? []).contains { $0.tagID == tagID })

            _ = try? await store.purgeMissing(olderThan: 0)
            let survived = (try? await store.listDocuments(selection: .deleted, query: SearchQuery(""),
                                                           sort: .added, ascending: false)) ?? []
            Check.that("the purge leaves a document that was deleted on purpose alone",
                       survived.contains { $0.doc == victim.doc })

            try? await store.restore(victim.doc)
            let back = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                       sort: .added, ascending: false)) ?? []
            let keptTags = (try? await store.tags(for: victim.doc)) ?? []
            Check.that("putting it back revives the row it always had",
                       back.contains { $0.doc == victim.doc }
                           && keptTags.contains { $0.tagID == tagID })
            try? await store.unassign(tag: tagID, from: victim.doc)
            try? await store.deleteTag(tagID)
        }
    }

    static func history(store: Store, indexer: Indexer, root: URL, rows: [DocumentRow]) async {
        print("\nHISTORY")
        if let subject = rows.first {
            let firstEvents = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            let oldest = firstEvents.last
            for n in 0...Store.queueLength {
                try? await store.logProcessing(docID: subject.doc, action: .indexed,
                                               detail: "filler \(n)", rule: nil,
                                               from: nil, to: nil, approved: true)
            }
            let queue = (try? await store.processingQueue(limit: 10_000)) ?? []
            let kept = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            let total = (try? await store.eventCount()) ?? 0
            print("  queue holds \(queue.count), history holds \(total) event(s), "
                  + "\(kept.count) of them for \(subject.filename)")
            Check.that("the queue stays bounded", queue.count <= Store.queueLength,
                       "\(queue.count) entries")
            Check.that("the history is not trimmed with it",
                       kept.count > queue.count, "\(kept.count) events kept")
            Check.that("the first thing that happened to a document is still on record",
                       oldest == nil || kept.contains { $0.id == oldest!.id })
            let detailed = try? await store.detail(subject.doc)
            Check.that("a document's history reaches the inspector",
                       (detailed?.history.count ?? 0) > 0)
            Check.that("history is newest first",
                       zip(kept, kept.dropFirst()).allSatisfy { $0.at >= $1.at })

            let approvedBefore = (try? await store.detail(subject.doc))?.row.approved
            try? await store.logEdit(docID: subject.doc, detail: "Title → Typed by hand")
            let edited = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            let queueAfterEdit = (try? await store.processingQueue(limit: 10_000)) ?? []
            Check.that("a hand edit is recorded in the history",
                       edited.contains { $0.action == .edited
                                         && $0.detail == "Title → Typed by hand" })
            Check.that("a hand edit stays out of the review queue",
                       queueAfterEdit.count == queue.count,
                       "\(queueAfterEdit.count) entries, was \(queue.count)")
            Check.that("a hand edit does not put the document back into review",
                       (try? await store.detail(subject.doc))?.row.approved == approvedBefore)

            let window = Store.editGroupingWindow
            let soon = Date().addingTimeInterval(60)
            try? await store.logEdit(docID: subject.doc, detail: "Date → 1 Jan 2024", at: soon)
            try? await store.logEdit(docID: subject.doc, detail: "Title → Typed again",
                                     at: soon.addingTimeInterval(60))
            let grouped = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            Check.that("hand edits within \(Int(window / 60)) minutes are grouped into one entry",
                       grouped.count == edited.count, "\(grouped.count) events, was \(edited.count)")
            Check.that("a grouped entry keeps each field's latest value, once",
                       grouped.first?.detail == "Date → 1 Jan 2024\nTitle → Typed again",
                       grouped.first?.detail ?? "no detail")
            Check.that("a grouped entry is dated by its latest edit",
                       grouped.first.map { abs($0.at.timeIntervalSince(soon) - 60) < 1 } == true)
            try? await store.logEdit(docID: subject.doc, detail: "Title cleared",
                                     at: soon.addingTimeInterval(60 + window + 1))
            let later = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            Check.that("an edit after a longer pause starts a new entry",
                       later.count == grouped.count + 1 && later.first?.detail == "Title cleared",
                       "\(later.count) events, was \(grouped.count)")

            let origPath = subject.path
            let movedTarget = root.appendingPathComponent("Work/undotest-\(subject.filename)")
            let mark = (try? await store.latestEventID()) ?? 0
            if (try? FileManager.default.moveItem(at: subject.url, to: movedTarget)) != nil {
                try? await store.updatePath(subject.doc, to: movedTarget.path)
                try? await store.logProcessing(docID: subject.doc, action: .moved, detail: "test move",
                                               rule: nil, from: origPath, to: movedTarget.path, approved: true)
                let undone = await indexer.undo([subject.doc], since: mark)
                Check.that("undo restores moved file to previous path",
                           undone == 1 && FileManager.default.fileExists(atPath: origPath))
            }
        }

        if let sample = rows.first {
            let similar = (try? await store.similarDocuments(for: sample.doc, limit: 3)) ?? []
            Check.that("more-like-this finds similar documents without self", !similar.contains { $0.doc == sample.doc })
        }
    }
}
