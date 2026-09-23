import Foundation
import AppKit

extension AppModel {

    func analyze(_ rows: [DocumentRow]) {
        analyze(grouped(rows).map { ($0.library, $0.rows.map(\.doc)) },
                subject: rows.count == 1
                ? rows[0].url.lastPathComponent : "\(rows.count) documents")
    }

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
            modelStatus = await intelligence.status()
            report(combined, subject: subject)
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

    func deleteOriginal(_ row: DocumentRow) {
        guard let lib = library(of: row) else { return }
        Task {
            try? await lib.store.deleteOriginalFile(for: row.doc)
            reloadDetail()
            notify("Deleted the saved original of “\(row.displayTitle)”.")
        }
    }

    func rename(_ rows: [DocumentRow], template: String) {
        Task {
            let marks = await eventMarks(rows)
            var n = 0
            for (lib, rows) in grouped(rows) {
                n += await lib.indexer.rename(ids: rows.map(\.doc), template: template)
            }
            if n == 0 { notify("No files needed renaming.", .info) }
            else {
                offerUndo("Rename", of: rows, since: marks)
                notify("Renamed \(n) file\(n == 1 ? "" : "s").")
            }
        }
    }

    func move(_ rows: [DocumentRow], to destination: URL) {
        Task {
            let marks = await eventMarks(rows)
            var moved = 0
            for (lib, rows) in grouped(rows) {
                moved += await lib.indexer.move(ids: rows.map(\.doc), to: destination)
            }
            if moved == 0 { notify("Those documents are already in “\(destination.lastPathComponent)”.", .info) }
            else {
                offerUndo("Move", of: rows, since: marks)
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
        let viewedFolder: String?
        if case .folder(let path) = selection { viewedFolder = path } else { viewedFolder = nil }
        Task {
            let marks = await eventMarks(rows)
            var trashed: [DocumentRow] = []
            var rehomed: [(title: String, folder: String)] = []
            var unfiled = 0
            var failed: [String] = []
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    if row.isAliasHere, let folder = viewedFolder {
                        unfiled += await removeAliasPlacements(of: row, in: folder, from: lib)
                        continue
                    }
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
                        trashed.append(row)
                    } catch {
                        failed.append(row.filename)
                    }
                }
            }
            refreshAll()
            if !failed.isEmpty {
                errorMessage = "Could not move \(failed.count == 1 ? "“\(failed[0])”" : "\(failed.count) files") to the Trash. \(failed.count == 1 ? "It was" : "They were") left where \(failed.count == 1 ? "it is" : "they are")."
            }
            let kept = rows.filter { row in !trashed.contains { $0.id == row.id } }
            if !trashed.isEmpty || !rehomed.isEmpty || unfiled > 0 {
                offerUndo("Move to Trash", of: kept, since: marks, restoring: trashed)
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
                            docID: row.doc, action: .moved, detail: "Restored from the Trash",
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

    func createAliases(_ rows: [DocumentRow], in folder: URL) {
        Task {
            let marks = await eventMarks(rows)
            var made = 0
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    guard row.url.deletingLastPathComponent().path != folder.path else { continue }
                    guard let created = try? AliasManager.createAlias(to: row.url, in: folder) else { continue }
                    try? await lib.store.recordAlias(docID: row.doc, tagID: nil, path: created.path)
                    try? await lib.store.logProcessing(docID: row.doc, action: .aliased,
                                                       detail: "Also filed under \(folder.lastPathComponent)",
                                                       confidence: nil, rule: nil, from: row.path,
                                                       to: created.path, approved: true)
                    made += 1
                }
            }
            refreshAll()
            if made == 0 { notify("Those documents are already in that folder.", .info) }
            else {
                offerUndo("File Here", of: rows, since: marks)
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
