import Foundation
import AppKit

extension AppModel {

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

    func revertOptimization(_ rows: [DocumentRow]) {
        Task {
            var count = 0
            for (lib, rows) in grouped(rows) {
                count += await lib.indexer.revertOptimization(ids: rows.map(\.doc))
            }
            if count == 0 { notify("No original pre-optimization files were found to restore.", .info) }
            else { notify("Reverted \(count) document\(count == 1 ? "" : "s") to original.") }
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

    /// Moves the master files to the Trash — never deletes them outright — and
    /// forgets them only once the Trash has actually taken them.
    ///
    /// Two kinds of row never reach the Trash at all:
    ///
    /// A row that is in the folder being viewed only as an alias *is* the
    /// alias, and deleting it deletes exactly that — the same thing Remove
    /// Alias does, and the same thing Finder does with an alias. The document
    /// it points at is somewhere else and is not what was deleted.
    ///
    /// A document that was filed in another folder by hand moves to the
    /// nearest of those folders, taking the place of the alias standing there,
    /// so it leaves the folder it was deleted from without the placements it
    /// had being left pointing at nothing. See `Indexer.promoteClosestAlias`.
    func moveToTrash(_ rows: [DocumentRow]) {
        // `isAliasHere` is only ever set while a folder is being viewed, and
        // that folder is the one the alias is in.
        let viewedFolder: String?
        if case .folder(let path) = selection { viewedFolder = path } else { viewedFolder = nil }
        Task {
            var trashed = 0
            var rehomed: [(title: String, folder: String)] = []
            var unfiled = 0
            var failed: [String] = []
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    // The alias is the thing on screen, so it is the thing
                    // deleted. Nothing else about the document changes.
                    if row.isAliasHere, let folder = viewedFolder {
                        unfiled += await removeAliasPlacements(of: row, in: folder, from: lib)
                        continue
                    }
                    // Somewhere else to be beats the Trash.
                    if let newHome = await lib.indexer.promoteClosestAlias(docID: row.doc) {
                        rehomed.append((row.displayTitle,
                                        newHome.deletingLastPathComponent().lastPathComponent))
                        continue
                    }
                    do {
                        var landed: NSURL?
                        try FileManager.default.trashItem(at: row.url, resultingItemURL: &landed)
                        // The row stays, marked deleted and remembering where
                        // in the Trash the file went. Rescuing the file a month
                        // later brings the document back with its title, tags
                        // and history rather than as something brand new.
                        try? await lib.store.softDelete(row.doc,
                                                        trashPath: (landed as URL?)?.path)
                        FileScanner.pruneEmptyDirectories(startingFrom: row.url.deletingLastPathComponent(), upTo: lib.store.root)
                        trashed += 1
                    } catch {
                        failed.append(row.filename)
                    }
                }
            }
            refreshAll()
            if !failed.isEmpty {
                errorMessage = "Could not move \(failed.count == 1 ? "“\(failed[0])”" : "\(failed.count) files") to the Trash. \(failed.count == 1 ? "It was" : "They were") left where \(failed.count == 1 ? "it is" : "they are")."
            }
            // A delete can end three ways at once, and one toast replaces the
            // last, so they are said in one line rather than hiding each other.
            var said: [String] = []
            if trashed > 0 {
                said.append(trashed == 1 && rows.count == 1
                    ? "Moved “\(rows[0].displayTitle)” to the Trash."
                    : "Moved \(trashed) documents to the Trash.")
            }
            if !rehomed.isEmpty {
                said.append(rehomed.count == 1
                    ? "“\(rehomed[0].title)” is also filed in “\(rehomed[0].folder)”, so it moved there instead of the Trash."
                    : "\(rehomed.count) documents are also filed in other folders, so they moved there instead of the Trash.")
            }
            if unfiled > 0, let folder = viewedFolder {
                let name = (folder as NSString).lastPathComponent
                said.append(unfiled == 1
                    ? "Took the alias out of “\(name)”. The document itself is untouched."
                    : "Took \(unfiled) aliases out of “\(name)”. The documents themselves are untouched.")
            }
            if !said.isEmpty { notify(said.joined(separator: " ")) }
        }
    }

    /// Puts deleted documents back: the file comes out of the Trash and the row
    /// it always had is revived, rather than the file being re-indexed as
    /// something new.
    func restore(_ rows: [DocumentRow]) {
        Task {
            var restored = 0
            var gone: [String] = []
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    guard let trashed = try? await lib.store.trashedFile(row.doc) else {
                        gone.append(row.filename)
                        continue
                    }
                    let destination = URL(fileURLWithPath: row.path)
                    do {
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        let target = Naming.uniqueURL(in: destination.deletingLastPathComponent(),
                                                      filename: destination.lastPathComponent)
                        try FileManager.default.moveItem(at: URL(fileURLWithPath: trashed), to: target)
                        try? await lib.store.restore(row.doc, at: target.path)
                        try? await lib.store.logProcessing(
                            docID: row.doc, action: "moved", detail: "Restored from the Trash",
                            confidence: nil, rule: nil, from: trashed, to: target.path, approved: true)
                        restored += 1
                    } catch {
                        gone.append(row.filename)
                    }
                }
            }
            refreshAll()
            if !gone.isEmpty {
                errorMessage = gone.count == 1
                    ? "“\(gone[0])” is no longer in the Trash, so there is nothing to put back."
                    : "\(gone.count) of these files are no longer in the Trash."
            }
            if restored > 0 {
                notify(restored == 1 ? "Put “\(rows.first?.displayTitle ?? "the document")” back."
                                     : "Put \(restored) documents back.")
            }
        }
    }

    /// Forgets a deleted document for good. The file stays in the Trash —
    /// emptying that is the Finder's business, not Doctopus's.
    func forget(_ rows: [DocumentRow]) {
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows { try? await lib.store.deleteDocument(row.doc) }
            }
            refreshAll()
            notify(rows.count == 1 ? "Removed “\(rows[0].displayTitle)” from the library."
                                   : "Removed \(rows.count) documents from the library.")
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

    /// Takes a document's aliases inside `folder` away, leaving the master file
    /// where it is, and says how many went. The registry lets go of the
    /// placement either way: an entry whose file is no longer the alias we
    /// wrote is a record of something that is not ours to remove.
    ///
    /// Each one is recorded as an `unfiled` event carrying where the alias was,
    /// which is what lets Undo write it again.
    private func removeAliasPlacements(of row: DocumentRow, in folder: String,
                                       from lib: Library) async -> Int {
        var removed = 0
        for alias in ((try? await lib.store.aliases(for: row.doc)) ?? [])
        where alias.path.hasPrefix(folder + "/") {
            AliasManager.removeAlias(at: alias.path, pointingTo: row.url)
            try? await lib.store.deleteAlias(id: alias.id)
            try? await lib.store.logProcessing(
                docID: row.doc, action: "unfiled",
                detail: "No longer filed under \((folder as NSString).lastPathComponent)",
                confidence: nil, rule: nil, from: row.path, to: alias.path, approved: true)
            removed += 1
        }
        return removed
    }
}
