import Foundation

extension Indexer {
    /// Forgets the placement aliases that are no longer on disk. Only the
    /// records go: an alias is the user's once it is filed, so it is theirs to
    /// delete, and one still there is left alone.
    func forgetVanishedAliases(of docID: Int64) async {
        for alias in (try? await store.aliases(for: docID)) ?? []
        where !FileManager.default.fileExists(atPath: alias.path) {
            try? await store.deleteAlias(id: alias.id)
        }
    }

    /// Nil when there is no placement to move into; throws when there was one
    /// but the move failed, which leaves the document and that placement as
    /// they were, and is no reason to send the document to the Trash instead.
    func promoteClosestAlias(docID: Int64) async throws -> URL? {
        guard let path = try? await store.documentPath(docID) else { return nil }
        let url = URL(fileURLWithPath: path)
        let home = url.deletingLastPathComponent()
        let rootPath = Store.canonical(store.root.standardizedFileURL.path)
        let homePath = Store.canonical(home.standardizedFileURL.path)

        let placements = ((try? await store.aliases(for: docID)) ?? []).filter { alias in
            let folder = Store.canonical(
                URL(fileURLWithPath: alias.path).deletingLastPathComponent()
                    .standardizedFileURL.path)
            guard folder != homePath else { return false }
            return folder == rootPath || folder.hasPrefix(rootPath + "/")
        }
        guard !placements.isEmpty else { return nil }

        let ordered = placements.sorted { l, r in
            let lf = URL(fileURLWithPath: l.path).deletingLastPathComponent()
            let rf = URL(fileURLWithPath: r.path).deletingLastPathComponent()
            let ld = AliasManager.distance(from: home, to: lf)
            let rd = AliasManager.distance(from: home, to: rf)
            if ld != rd { return ld < rd }
            let lDepth = lf.pathComponents.count
            let rDepth = rf.pathComponents.count
            if lDepth != rDepth { return lDepth < rDepth }
            return l.path < r.path
        }

        for alias in ordered {
            let folder = URL(fileURLWithPath: alias.path).deletingLastPathComponent()
            // Only an alias that is still ours, and still this document's, is
            // ours to take away; anything else at that path is the user's own
            // file, and the placement is skipped for the next one along.
            guard AliasManager.removeAlias(at: alias.path, pointingTo: url) else { continue }
            var unregistered = false
            do {
                try await store.deleteAlias(id: alias.id)
                unregistered = true
                return try await relocate(docID, from: url, into: folder, named: url.lastPathComponent,
                                          action: .promoted,
                                          detail: "Deleted from \(home.lastPathComponent); kept where it was also filed")
            } catch {
                // Nothing logged the alias's removal, so Undo could not bring it back.
                if let again = try? AliasManager.createAlias(to: url, in: folder),
                   unregistered || again.path != alias.path {
                    try? await store.recordAlias(docID: docID, path: again.path)
                }
                throw error
            }
        }
        return nil
    }

    /// How many of a batch of file changes were made, and why the rest were not.
    struct FileChanges: Sendable {
        var done = 0
        var failures: [String] = []

        mutating func fail(_ name: String, _ error: Error) {
            failures.append("“\(name)”: \(error.localizedDescription)")
        }
    }

    func rename(ids: [Int64], template: String) async -> FileChanges {
        var result = FileChanges()
        for id in ids {
            guard let detail = try? await store.detail(id) else { continue }
            let url = detail.row.url
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let ctx = Naming.Context(date: detail.row.docDate ?? detail.row.createdAt,
                                     correspondent: detail.row.correspondent,
                                     title: detail.row.title,
                                     docType: detail.row.docType,
                                     language: detail.row.language,
                                     counter: result.done + 1,
                                     originalStem: url.deletingPathExtension().lastPathComponent,
                                     ext: url.pathExtension,
                                     options: settings.namingOptions)
            let newName = Naming.render(template, ctx)
            // The library's own template is what later edits keep a name in
            // step with; any other gives a name somebody chose.
            let recorded = template == settings.namingTemplate ? newName : nil
            guard newName != url.lastPathComponent else {
                if recorded != nil { try? await store.recordAutoName(recorded, for: id) }
                continue
            }
            do {
                try await relocate(id, from: url, into: url.deletingLastPathComponent(), named: newName,
                                   action: .renamed, detail: newName, rule: template)
                try? await store.recordAutoName(recorded, for: id)
                result.done += 1
            } catch { result.fail(url.lastPathComponent, error) }
        }
        onDataChanged()
        return result
    }

    /// Renames documents whose fields have just changed to what the library's
    /// template now makes of them, as far as the naming setting reaches: under
    /// `followTemplateNames` only a file whose name the template gave it, under
    /// `automatic` any. A suppressed document, and one a matching rule
    /// renames, keep their names.
    func followNaming(_ ids: [Int64]) async -> FileChanges {
        var result = FileChanges()
        let enforcement = settings.namingEnforcement
        guard enforcement.followsEdits, let template = settings.namingTemplate.nilIfBlank else { return result }
        for id in ids {
            guard let state = try? await store.namingState(id), !state.suppressed,
                  enforcement == .automatic || state.autoNamed,
                  (try? await store.isRuleRenamed(id)) == false,
                  let row = try? await store.detail(id)?.row else { continue }
            let url = row.url
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let name = Naming.render(template, Naming.Context(row, options: settings.namingOptions))
            guard !Naming.isRendering(url.lastPathComponent, of: name) else { continue }
            do {
                try await relocate(id, from: url, into: url.deletingLastPathComponent(), named: name,
                                   action: .renamed, detail: name, rule: template)
                try? await store.recordAutoName(name, for: id)
                result.done += 1
            } catch { result.fail(url.lastPathComponent, error) }
        }
        if result.done > 0 { onDataChanged() }
        return result
    }

    func move(ids: [Int64], to destination: URL) async -> FileChanges {
        var result = FileChanges()
        for id in ids {
            guard let path = try? await store.documentPath(id) else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().path != destination.path else { continue }
            do {
                try await relocate(id, from: url, into: destination, named: url.lastPathComponent,
                                   action: .moved, detail: destination.lastPathComponent)
                result.done += 1
            } catch { result.fail(url.lastPathComponent, error) }
        }
        onDataChanged()
        return result
    }

    func optimize(ids: [Int64]) async -> (count: Int, saved: Int64, failures: [String]) {
        var count = 0
        var saved: Int64 = 0
        var failures: [String] = []
        for id in ids {
            guard let path = try? await store.documentPath(id) else { continue }
            let url = URL(fileURLWithPath: path)
            do {
                guard let result = try await optimizeFile(id: id, url: url) else { continue }
                count += 1
                saved += result.originalSize - result.newSize
            } catch { failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
        }
        onDataChanged()
        return (count, saved, failures)
    }

    enum OptimizeError: LocalizedError {
        case originalUnreadable
        case originalNotKept(String)
        case unrecorded(String)

        var errorDescription: String? {
            switch self {
            case .originalUnreadable:
                return "its original could not be read to keep a copy, so it was left as it is"
            case .originalNotKept(let reason):
                return "its original could not be kept (\(reason)), so it was left as it is"
            case .unrecorded(let reason):
                return "it was optimized, but the index could not record where its original is kept (\(reason)), so it cannot be reverted"
            }
        }
    }

    /// Nil when optimizing would not help. Throws, before touching the file,
    /// when its original cannot be kept: without it the change could never
    /// be taken back.
    func optimizeFile(id: Int64, url: URL) async throws -> Optimizer.Result? {
        guard let preHash = FileScanner.hash(url) else { throw OptimizeError.originalUnreadable }
        // False when an identical original is already kept, which will do.
        let savedOriginal: String?
        do {
            savedOriginal = try await store.saveOriginalFile(for: id, from: url, hash: preHash) ? preHash : nil
        } catch { throw OptimizeError.originalNotKept(error.localizedDescription) }
        guard let result = try? Optimizer.optimize(url: url, options: settings.optimizerOptions) else {
            if let savedOriginal { await store.discardOriginalFile(hash: savedOriginal, ext: url.pathExtension) }
            return nil
        }
        // `original_size` is what finds the kept original again, so a revert
        // is only possible once this is on record.
        do { try await store.setSizes(id, size: result.newSize, originalSize: result.originalSize) }
        catch { throw OptimizeError.unrecorded(error.localizedDescription) }
        try? await store.logProcessing(
            docID: id, action: .optimized,
            detail: String(format: "%.0f%% smaller (%d page%@ rasterized)",
                           result.savings * 100, result.pagesRasterized,
                           result.pagesRasterized == 1 ? "" : "s"),
            rule: nil, from: nil, to: nil, approved: true)
        if let hash = FileScanner.hash(url) { try? await store.setHash(id, hash) }
        return result
    }

    func revertOptimization(ids: [Int64]) async -> FileChanges {
        let fm = FileManager.default
        var result = FileChanges()
        for id in ids {
            guard let saved = try? await store.savedOriginal(id) else { continue }
            // Staged beside the live file and swapped in, so a failing copy can
            // never leave the row pointing at a file that no longer exists.
            let staged = saved.current.deletingLastPathComponent()
                .appendingPathComponent(".doctopus-revert-\(UUID().uuidString).\(saved.current.pathExtension)")
            do {
                try fm.copyItem(at: saved.file, to: staged)
                if fm.fileExists(atPath: saved.current.path) {
                    _ = try fm.replaceItemAt(saved.current, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: saved.current)
                }
                try await store.markReverted(id, size: saved.size)
            } catch {
                try? fm.removeItem(at: staged)
                result.fail(saved.current.lastPathComponent, error)
                continue
            }
            try? await store.logProcessing(docID: id, action: .revertedOptimization,
                                           detail: "Reverted to original pre-optimization file",
                                           rule: nil, from: nil, to: saved.current.path,
                                           approved: true)
            result.done += 1
        }
        if result.done > 0 || !result.failures.isEmpty { onDataChanged() }
        return result
    }

    /// Every move of a document's file ends here: the file, its row, the folder
    /// it left, its event and its alias records.
    @discardableResult
    func relocate(_ id: Int64, from url: URL, into folder: URL, named name: String,
                  action: EventAction?, detail: String?, rule: String? = nil,
                  approved: Bool = true) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = Naming.uniqueURL(in: folder, filename: name,
                                      separator: settings.filenameUnderscoresForSpaces ? "_" : " ")
        try FileManager.default.moveItem(at: url, to: target)
        do {
            try await store.updatePath(id, to: target.path)
        } catch {
            // The row still says where the file was, so that is where it goes
            // back to, rather than somewhere the index and Undo know nothing of.
            do { try FileManager.default.moveItem(at: target, to: url) } catch {
                throw UnrecordedMove(target: target, reason: error.localizedDescription)
            }
            throw error
        }
        FileScanner.pruneEmptyDirectories(startingFrom: url.deletingLastPathComponent(), upTo: store.root)
        if let action {
            try? await store.logProcessing(docID: id, action: action, detail: detail,
                                           rule: rule, from: url.path, to: target.path, approved: approved)
        }
        await forgetVanishedAliases(of: id)
        return target
    }

    struct UnrecordedMove: LocalizedError {
        let target: URL
        let reason: String
        var errorDescription: String? {
            "It was moved to “\(target.path)”, which the index could not record, "
                + "and could not be put back (\(reason)). The next scan will find it there."
        }
    }

    /// Takes back every file change made to these documents since `mark`,
    /// newest first. One whose file has since moved outside Doctopus is dropped
    /// rather than left to block the rest.
    @discardableResult
    func undo(_ docIDs: [Int64], since mark: Int64) async -> Int {
        var undone = 0
        for id in docIDs {
            while let event = try? await store.lastUndoableEvent(of: id, after: mark) {
                guard await takeBack(event) else { break }
                undone += 1
            }
        }
        if undone > 0 { onDataChanged() }
        return undone
    }

    /// False when the change could not be put back, which leaves it on record.
    private func takeBack(_ event: Store.UndoableEvent) async -> Bool {
        let moved = URL(fileURLWithPath: event.to)
        let current = (try? await store.documentPath(event.docID)).map { URL(fileURLWithPath: $0) }
        switch event.action {
        case .aliased:
            if let current, AliasManager.removeAlias(at: event.to, pointingTo: current) {
                for alias in (try? await store.aliases(for: event.docID)) ?? [] where alias.path == event.to {
                    try? await store.deleteAlias(id: alias.id)
                }
            }
        case .unfiled:
            if let current, FileManager.default.fileExists(atPath: current.path),
               let alias = try? AliasManager.createAlias(to: current, in: moved.deletingLastPathComponent()) {
                try? await store.recordAlias(docID: event.docID, path: alias.path)
            }
        default:
            guard FileManager.default.fileExists(atPath: moved.path) else { break }
            let original = URL(fileURLWithPath: event.from)
            guard let target = try? await relocate(event.docID, from: moved,
                                                   into: original.deletingLastPathComponent(),
                                                   named: original.lastPathComponent, action: nil, detail: nil)
            else { return false }
            if event.action == .promoted,
               let alias = try? AliasManager.createAlias(to: target, in: moved.deletingLastPathComponent()) {
                try? await store.recordAlias(docID: event.docID, path: alias.path)
            }
        }
        // An event that stays on record would be handed straight back by
        // `lastUndoableEvent`, and `undo` would loop on it forever.
        do { try await store.deleteEvent(event.id) } catch { return false }
        return true
    }
}
