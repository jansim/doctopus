import AppKit

/// A document filed in more than one folder, by alias.
extension SelfTest {
    static func aliasInAFolder(store: Store, rows: [DocumentRow]) async {
        print("\nALIASES (drag onto a folder)")
        if let target = rows.first(where: { $0.directory.hasSuffix("Work") })?.url.deletingLastPathComponent(),
           let source = rows.first(where: { $0.directory.hasSuffix("Inbox") }) {
            if let created = try? AliasManager.createAlias(to: source.url, in: target) {
                try? await store.recordAlias(docID: source.doc, tagID: nil, path: created.path)
                let listed = (try? await store.listDocuments(selection: .folder(target.path),
                                                             query: SearchQuery(""), sort: .added,
                                                             ascending: false)) ?? []
                print("  aliased \(source.filename) into \(target.lastPathComponent)")
                for row in listed {
                    print("    \(row.filename.padded(40)) \(row.isAliasHere ? "alias → \((row.directory as NSString).lastPathComponent)" : "master")")
                }
                print("  resolves back to: \(AliasManager.resolve(created)?.lastPathComponent ?? "✗ broken")")
                Check.that("alias is listed in its folder and resolves to the master",
                           listed.contains { $0.isAliasHere && $0.id == source.id }
                               && AliasManager.resolve(created) == source.url)
                AliasManager.removeAlias(at: created.path)
            }
        }
    }

    static func promotedAlias(store: Store, indexer: Indexer, rows: [DocumentRow]) async {
        if let source = rows.first(where: { $0.directory.hasSuffix("Inbox") }),
           let second = rows.first(where: { $0.directory.hasSuffix("Work") })?
               .url.deletingLastPathComponent(),
           let created = try? AliasManager.createAlias(to: source.url, in: second) {
            try? await store.recordAlias(docID: source.doc, tagID: nil, path: created.path)
            let mark = (try? await store.latestEventID()) ?? 0
            let landed = try? await indexer.promoteClosestAlias(docID: source.doc)
            print("  deleted \(source.filename.padded(32)) → "
                  + (landed?.deletingLastPathComponent().lastPathComponent ?? "the Trash"))
            Check.that("deleting an aliased document promotes the alias into the document",
                       landed?.deletingLastPathComponent().standardizedFileURL
                           == second.standardizedFileURL
                           && FileManager.default.fileExists(atPath: landed?.path ?? ""))
            Check.that("…and the alias it stood in for is gone",
                       !AliasManager.isAlias(URL(fileURLWithPath: created.path)))
            Check.that("…and nothing is left in the folder it was deleted from",
                       !FileManager.default.fileExists(atPath: source.path))
            Check.that("…and the registry no longer carries the promoted placement",
                       !((try? await store.aliases(for: source.doc)) ?? [])
                           .contains(where: { $0.path == created.path }))

            let undone = await indexer.undo([source.doc], since: mark)
            let restored = (try? await store.documentPath(source.doc)) ?? ""
            let placements = ((try? await store.aliases(for: source.doc)) ?? [])
                .filter { $0.tagID == nil }
            Check.that("undo returns a promoted document to the folder it was deleted from",
                       undone == 1 && restored == source.path, "\(undone) change(s) undone")
            Check.that("…and writes the alias it stood in for again",
                       placements.contains(where: { alias in
                           let at = URL(fileURLWithPath: alias.path)
                           guard AliasManager.isAlias(at),
                                 let points = AliasManager.resolve(at) else { return false }
                           return Store.canonical(points.standardizedFileURL.path)
                               == Store.canonical(URL(fileURLWithPath: restored)
                                   .standardizedFileURL.path)
                       }),
                       "\(placements.count) placement(s)")

            for alias in placements {
                AliasManager.removeAlias(at: alias.path,
                                         pointingTo: URL(fileURLWithPath: restored))
                try? await store.deleteAlias(id: alias.id)
            }
        }
    }

    static func undoneAlias(store: Store, indexer: Indexer, rows: [DocumentRow]) async {
        if let doc = rows.first(where: { $0.directory.hasSuffix("Inbox") }),
           let elsewhere = rows.first(where: { $0.directory.hasSuffix("Work") })?
               .url.deletingLastPathComponent(),
           let created = try? AliasManager.createAlias(to: doc.url, in: elsewhere) {
            try? await store.recordAlias(docID: doc.doc, tagID: nil, path: created.path)
            let record = ((try? await store.aliases(for: doc.doc)) ?? [])
                .first(where: { $0.path == created.path })
            AliasManager.removeAlias(at: created.path, pointingTo: doc.url)
            if let record { try? await store.deleteAlias(id: record.id) }
            let mark = (try? await store.latestEventID()) ?? 0
            try? await store.logProcessing(
                docID: doc.doc, action: .unfiled,
                detail: "No longer filed under \(elsewhere.lastPathComponent)",
                rule: nil, from: doc.path, to: created.path, approved: true)

            let undone = await indexer.undo([doc.doc], since: mark)
            let back = ((try? await store.aliases(for: doc.doc)) ?? []).filter { $0.tagID == nil }
            // `&&` takes its right side as a non-async autoclosure, so anything
            // awaited has to be in hand before the check, not inside it.
            let stillHome = (try? await store.documentPath(doc.doc)) ?? ""
            Check.that("undoing a deleted alias writes the alias again, and nothing else",
                       undone == 1
                           && back.contains(where: { AliasManager.isAlias(URL(fileURLWithPath: $0.path)) })
                           && stillHome == doc.path, "\(undone) change(s) undone")

            for alias in back {
                AliasManager.removeAlias(at: alias.path, pointingTo: doc.url)
                try? await store.deleteAlias(id: alias.id)
            }
        }
    }

    static func folderDrops() {
        print("\nFOLDER DROPS")
        Check.that("a drag with nothing held moves the master file",
                   FolderDropIntent.reading([]) == .move)
        Check.that("⌥ files the document in a second place instead",
                   FolderDropIntent.reading([.option]) == .alias)
        Check.that("⌘⌥, Finder's alias drag, files it there too",
                   FolderDropIntent.reading([.command, .option]) == .alias)
        Check.that("⌘ on its own is still a move",
                   FolderDropIntent.reading([.command]) == .move)
        func movesInto(_ intent: FolderDropIntent, _ folder: String) -> Bool {
            if case .move(let target) = intent.action(on: folder) { return target == folder }
            return false
        }
        Check.that("the intent carries the folder the drag was read over",
                   movesInto(.move, "/Documents/Taxes") && !movesInto(.alias, "/Documents/Taxes"))
        Check.that("the row says which of the two it would be",
                   FolderDropIntent.alias.label == "File Here"
                       && FolderDropIntent.move.label == "Move Here")
    }
}
