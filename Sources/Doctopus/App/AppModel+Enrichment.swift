import Foundation
import AppKit

extension AppModel {

    func analyze(_ rows: [DocumentRow]) {
        analyze(rows.map(\.doc),
                subject: rows.count == 1
                ? rows[0].url.lastPathComponent : "\(rows.count) documents")
    }

    func analyzeLibrary() {
        guard let lib = library else { return }
        Task {
            let ids = (try? await lib.store.allDocumentIDs()) ?? []
            guard !ids.isEmpty else {
                notify("There is nothing indexed yet.", .info)
                return
            }
            analyze(ids, subject: "\(ids.count) documents")
        }
    }

    private func analyze(_ ids: [Int64], subject: String) {
        guard let lib = library, !ids.isEmpty else { return }
        Task {
            // Settings are saved on a chained task, so a run started right
            // after a change in the settings pane could otherwise ask the
            // backend the user just switched away from.
            await lib.indexer.update(settings: lib.settings)
            let summary = await lib.indexer.analyze(ids: ids)
            modelStatus = await intelligence.status()
            report(summary, subject: subject)
        }
    }

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

    func refreshModelStatus() {
        Task {
            await intelligence.update(settings: settings)
            modelStatus = await intelligence.refreshStatus()
        }
    }

    func optimize(_ rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            let result = await lib.indexer.optimize(ids: rows.map(\.doc))
            let count = result.count, saved = result.saved, failures = result.failures
            report(failures: failures, "optimize")
            if count == 0, failures.isEmpty { notify("Nothing to optimize — these files are already compact.", .info) }
            else if count > 0 { notify("Optimized \(count) file\(count == 1 ? "" : "s"), saved \(ByteFormat.string(saved)).") }
        }
    }

    func revertOptimization(_ rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            let result = await lib.indexer.revertOptimization(ids: rows.map(\.doc))
            let count = result.done, failures = result.failures
            report(failures: failures, "revert")
            if count == 0, failures.isEmpty { notify("No original pre-optimization files were found to restore.", .info) }
            else if count > 0 { notify("Reverted \(count) document\(count == 1 ? "" : "s") to original.") }
        }
    }

    func deleteOriginal(_ row: DocumentRow) {
        guard let lib = library else { return }
        Task {
            do {
                try await lib.store.deleteOriginalFile(for: row.doc)
                notify("Deleted the saved original of “\(row.displayTitle)”.")
            } catch { report(error, "delete the saved original of “\(row.displayTitle)”") }
            reloadDetail()
        }
    }

    func rename(_ rows: [DocumentRow], template: String) {
        guard let lib = library else { return }
        Task {
            let mark = await eventMark()
            let result = await lib.indexer.rename(ids: rows.map(\.doc), template: template)
            let n = result.done, failures = result.failures
            report(failures: failures, "rename")
            if n == 0 {
                if failures.isEmpty { notify("No files needed renaming.", .info) }
            } else {
                offerUndo("Rename", of: rows, since: mark)
                notify("Renamed \(n) file\(n == 1 ? "" : "s").")
            }
        }
    }

    func move(_ rows: [DocumentRow], to destination: URL) {
        guard let lib = library else { return }
        Task {
            let mark = await eventMark()
            let result = await lib.indexer.move(ids: rows.map(\.doc), to: destination)
            let moved = result.done, failures = result.failures
            report(failures: failures, "move to “\(destination.lastPathComponent)”")
            if moved == 0 {
                if failures.isEmpty {
                    notify("Those documents are already in “\(destination.lastPathComponent)”.", .info)
                }
            } else {
                offerUndo("Move", of: rows, since: mark)
                notify("Moved \(moved) document\(moved == 1 ? "" : "s") to “\(destination.lastPathComponent)”.")
            }
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

    /// Moves files to the Trash, never deletes them outright. A row shown here only
    /// as an alias deletes just the alias; a document also filed elsewhere by hand
    /// moves into its nearest alias instead (see `Indexer.promoteClosestAlias`).
    func moveToTrash(_ rows: [DocumentRow]) {
        guard let lib = library else { return }
        let viewedFolder: String?
        if case .folder(let path) = selection { viewedFolder = path } else { viewedFolder = nil }
        Task {
            let mark = await eventMark()
            var trashed: [DocumentRow] = []
            var rehomed: [(title: String, folder: String)] = []
            var unfiled = 0
            var failed: [String] = []
            var reasons: [String] = []
            for row in rows {
                if row.isAliasHere, let folder = viewedFolder {
                    unfiled += await removeAliasPlacements(of: row, in: folder, from: lib)
                    continue
                }
                do {
                    if let newHome = try await lib.indexer.promoteClosestAlias(docID: row.doc) {
                        rehomed.append((row.displayTitle,
                                        newHome.deletingLastPathComponent().lastPathComponent))
                        continue
                    }
                } catch {
                    // Also filed elsewhere, so it must not reach the Trash
                    // just because it could not move there.
                    failed.append(row.filename)
                    reasons.append("“\(row.filename)” could not move to where else it is filed: "
                                   + error.localizedDescription)
                    continue
                }
                var landed: NSURL?
                do {
                    try FileManager.default.trashItem(at: row.url, resultingItemURL: &landed)
                } catch {
                    failed.append(row.filename)
                    reasons.append("“\(row.filename)”: \(error.localizedDescription)")
                    continue
                }
                // The row stays, marked deleted and remembering where
                // in the Trash the file went. Rescuing the file a month
                // later brings the document back with its title, tags
                // and history rather than as something brand new.
                do {
                    try await lib.store.softDelete(row.doc, trashPath: (landed as URL?)?.path)
                } catch {
                    // Unrecorded, the row would stay listed with its file
                    // gone, so the file comes back out of the Trash.
                    let putBack = (landed as URL?).map {
                        (try? FileManager.default.moveItem(at: $0, to: row.url)) != nil
                    } ?? false
                    failed.append(row.filename)
                    reasons.append("“\(row.filename)”: \(error.localizedDescription)"
                                   + (putBack ? "" : " It is in the Trash, but still listed here."))
                    continue
                }
                FileScanner.pruneEmptyDirectories(startingFrom: row.url.deletingLastPathComponent(), upTo: lib.store.root)
                trashed.append(row)
            }
            refreshAll()
            if !failed.isEmpty {
                errorMessage = "Could not move \(failed.count == 1 ? "“\(failed[0])”" : "\(failed.count) files") to the Trash. \(failed.count == 1 ? "It was" : "They were") left where \(failed.count == 1 ? "it is" : "they are")."
                    + "\n\n" + reasons.prefix(5).joined(separator: "\n")
            }
            let kept = rows.filter { row in !trashed.contains { $0.id == row.id } }
            if !trashed.isEmpty || !rehomed.isEmpty || unfiled > 0 {
                offerUndo("Move to Trash", of: kept, since: mark, restoring: trashed)
            }
            var said: [String] = []
            if !trashed.isEmpty {
                said.append(trashed.count == 1 && rows.count == 1
                    ? "Moved “\(rows[0].displayTitle)” to the Trash."
                    : "Moved \(trashed.count) documents to the Trash.")
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

    func restore(_ rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            var restored = 0
            var gone: [String] = []
            var failures: [String] = []
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
                    do {
                        try await lib.store.restore(row.doc, at: target.path)
                    } catch {
                        // The row still says it is in the Trash, so that is
                        // where the file goes back to.
                        try? FileManager.default.moveItem(at: target, to: URL(fileURLWithPath: trashed))
                        throw error
                    }
                    try? await lib.store.logProcessing(
                        docID: row.doc, action: .moved, detail: "Restored from the Trash",
                        confidence: nil, rule: nil, from: trashed, to: target.path, approved: true)
                    restored += 1
                } catch {
                    failures.append("“\(row.filename)”: \(error.localizedDescription)")
                }
            }
            refreshAll()
            if !gone.isEmpty {
                errorMessage = gone.count == 1
                    ? "“\(gone[0])” is no longer in the Trash, so there is nothing to put back."
                    : "\(gone.count) of these files are no longer in the Trash."
            }
            report(failures: failures, "put back")
            if restored > 0 {
                notify(restored == 1 ? "Put “\(rows.first?.displayTitle ?? "the document")” back."
                                     : "Put \(restored) documents back.")
            }
        }
    }

    func forget(_ rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            var removed = 0
            var failures: [String] = []
            for row in rows {
                do {
                    try await lib.store.deleteDocument(row.doc)
                    removed += 1
                } catch { failures.append("“\(row.filename)”: \(error.localizedDescription)") }
            }
            refreshAll()
            report(failures: failures, "remove from the library")
            if removed > 0 {
                notify(rows.count == 1 ? "Removed “\(rows[0].displayTitle)” from the library."
                                       : "Removed \(removed) documents from the library.")
            }
        }
    }

    func createAliases(_ rows: [DocumentRow], in folder: URL) {
        guard let lib = library else { return }
        Task {
            let mark = await eventMark()
            var made = 0
            var failures: [String] = []
            for row in rows {
                guard row.url.deletingLastPathComponent().path != folder.path else { continue }
                let created: URL
                do {
                    created = try AliasManager.createAlias(to: row.url, in: folder)
                } catch { failures.append("“\(row.filename)”: \(error.localizedDescription)"); continue }
                do {
                    try await lib.store.recordAlias(docID: row.doc, tagID: nil, path: created.path)
                } catch {
                    // An alias the index does not know of could never be pruned.
                    AliasManager.removeAlias(at: created.path, pointingTo: row.url)
                    failures.append("“\(row.filename)”: \(error.localizedDescription)")
                    continue
                }
                try? await lib.store.logProcessing(docID: row.doc, action: .aliased,
                                                   detail: "Also filed under \(folder.lastPathComponent)",
                                                   confidence: nil, rule: nil, from: row.path,
                                                   to: created.path, approved: true)
                made += 1
            }
            refreshAll()
            report(failures: failures, "file in “\(folder.lastPathComponent)”")
            if made == 0 {
                if failures.isEmpty { notify("Those documents are already in that folder.", .info) }
            } else {
                offerUndo("File Here", of: rows, since: mark)
                notify("Filed \(made) document\(made == 1 ? "" : "s") in “\(folder.lastPathComponent)” as \(made == 1 ? "an alias" : "aliases").")
            }
        }
    }

    private func removeAliasPlacements(of row: DocumentRow, in folder: String,
                                       from lib: Library) async -> Int {
        var removed = 0
        for alias in ((try? await lib.store.aliases(for: row.doc)) ?? [])
        where alias.path.hasPrefix(folder + "/") {
            AliasManager.removeAlias(at: alias.path, pointingTo: row.url)
            try? await lib.store.deleteAlias(id: alias.id)
            try? await lib.store.logProcessing(
                docID: row.doc, action: .unfiled,
                detail: "No longer filed under \((folder as NSString).lastPathComponent)",
                confidence: nil, rule: nil, from: row.path, to: alias.path, approved: true)
            removed += 1
        }
        return removed
    }
}
