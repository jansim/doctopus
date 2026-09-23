import Foundation

enum KeptVersion: Hashable, Sendable {
    case original, optimized
}

/// What a batch approval does to one kind of document; a nil version leaves the bytes alone.
struct ReviewTreatment: Hashable, Sendable {
    var move: Bool
    var version: KeptVersion?

    static func `default`(fromOutside: Bool) -> ReviewTreatment {
        ReviewTreatment(move: fromOutside, version: fromOutside ? .optimized : nil)
    }
}

/// What to take from one rule when accepting a review.
struct RuleDecision: Hashable, Sendable {
    var match: RuleMatch
    var accepted: Set<RuleMatch.Change>

    var isPartial: Bool { accepted != Set(match.changes) }
}

struct OptimizationPreview: Sendable {
    var url: URL
    var newSize: Int64

    func discard() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

extension DocumentDetail {
    /// New arrivals start on their best suggestion; anything already in the library stays put.
    var defaultFolder: String {
        row.fromOutside ? pathSuggestions.first?.path ?? row.directory : row.directory
    }

    var isOptimized: Bool { row.originalSize != nil }

    var defaultVersion: KeptVersion { row.fromOutside || isOptimized ? .optimized : .original }
}

private enum KeepOutcome {
    case unchanged, optimized(saved: Int64), compact, restored

    var note: String? {
        switch self {
        case .unchanged: return nil
        case .optimized(let saved): return "optimized, saving \(ByteFormat.string(saved))"
        case .compact: return "already compact, so not optimized"
        case .restored: return "restored to the original"
        }
    }
}

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
              approve: Bool, version: KeptVersion? = nil, advance: Bool = false) {
        guard let lib = library(of: row), canFile(in: primary, alsoIn: secondaries, lib) else { return }
        let next = advance ? rowAfter(row) : nil
        Task {
            let marks = await eventMarks([row])
            await file(row, in: primary, alsoIn: secondaries, approve: approve, version: version,
                       lib: lib, since: marks, next: next)
        }
    }

    /// The whole review of one document in one go: the rule changes left ticked,
    /// where it lives, and approval. A rule's move is the folder choice, so it
    /// is never applied on its own; a rule whose folder was not picked, or with
    /// any change unticked, is suppressed so it stops pointing out the rest.
    func accept(_ row: DocumentRow, in primary: URL, alsoIn secondaries: Set<String>,
                rules decisions: [RuleDecision], version: KeptVersion? = nil, advance: Bool = false) {
        guard let lib = library(of: row), canFile(in: primary, alsoIn: secondaries, lib) else { return }
        let next = advance ? rowAfter(row) : nil
        Task {
            let marks = await eventMarks([row])
            var notes: [String] = []
            if !decisions.isEmpty {
                let rules = (try? await lib.store.rules()) ?? []
                for decision in decisions {
                    let name = decision.match.ruleName
                    let kinds = Set(decision.accepted.map(\.kind)).subtracting([.moveFile])
                    if !kinds.isEmpty, let rule = rules.first(where: { $0.id == decision.match.ruleID }) {
                        let limited = rule.limited(to: kinds)
                        if limited.hasEffect { _ = await lib.indexer.applyRule(limited, onlyTo: row.doc) }
                    }
                    if decision.isPartial {
                        await setRuleSuppressed(true, rule: decision.match.ruleID, name: name,
                                                doc: row.doc, in: lib)
                        notes.append(decision.accepted.isEmpty ? "left “\(name)” out"
                                                               : "applied part of “\(name)”")
                    } else {
                        notes.append("applied “\(name)”")
                    }
                }
            }
            // A rule may have renamed it, so file what is on disk now.
            let current = await loadDetail(row.id)?.row ?? row
            await file(current, in: primary, alsoIn: secondaries, approve: true, version: version,
                       lib: lib, since: marks, next: next, notes: notes)
        }
    }

    private func canFile(in primary: URL, alsoIn secondaries: Set<String>, _ lib: Library) -> Bool {
        guard lib.owns(path: primary.path) else {
            errorMessage = "“\(primary.lastPathComponent)” is outside \(lib.displayName). A document can only be filed within its own library."
            return false
        }
        let outside = secondaries.filter { !lib.owns(path: $0) }
        guard outside.isEmpty else {
            errorMessage = "“\((outside.first! as NSString).lastPathComponent)” is outside \(lib.displayName). A document can only be filed within its own library."
            return false
        }
        return true
    }

    private func file(_ row: DocumentRow, in primary: URL, alsoIn secondaries: Set<String>,
                      approve: Bool, version: KeptVersion?, lib: Library,
                      since marks: [LibraryID: Int64], next: DocumentRef?, notes: [String] = []) async {
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
            try? await lib.store.logProcessing(docID: row.doc, action: .aliased,
                                               detail: "Also filed under \((folder as NSString).lastPathComponent)",
                                               confidence: nil, rule: nil, from: target.path,
                                               to: created.path, approved: true)
            added.append((folder as NSString).lastPathComponent)
        }

        var kept: String?
        if approve {
            try? await lib.store.setDocumentApproved(row.doc, true)
            if let version { kept = await keep(version, of: row, in: lib).note }
        }
        if moved || !added.isEmpty || !notes.isEmpty { offerUndo("File", of: [row], since: marks) }
        if let next { selectedIDs = [next] }
        refreshAll()
        reloadDetail()

        var parts: [String] = []
        if moved { parts.append("Moved to “\(primary.lastPathComponent)”") }
        if !added.isEmpty { parts.append("also filed in \(added.map { "“\($0)”" }.joined(separator: ", "))") }
        parts += notes
        if let kept { parts.append(kept) }
        if parts.isEmpty { parts.append(approve ? "Approved" : "Nothing to change") }
        else if approve { parts.append("approved") }
        let text = parts.joined(separator: ", ")
        notify(text.prefix(1).uppercased() + text.dropFirst() + ".", parts == ["Nothing to change"] ? .info : .success)
    }

    func approve(_ rows: [DocumentRow], newArrivals: ReviewTreatment, alreadyInLibrary: ReviewTreatment) {
        Task {
            var moved = 0, optimized = 0, restored = 0, failed = 0
            var saved: Int64 = 0
            for (lib, rows) in grouped(rows) {
                for row in rows {
                    let treatment = row.fromOutside ? newArrivals : alreadyInLibrary
                    if treatment.move, let best = await suggestedFolder(for: row) {
                        if await lib.indexer.move(ids: [row.doc], to: URL(fileURLWithPath: best, isDirectory: true)) == 1 {
                            moved += 1
                        } else {
                            failed += 1
                        }
                    }
                    try? await lib.store.setDocumentApproved(row.doc, true)
                    guard let version = treatment.version else { continue }
                    switch await keep(version, of: row, in: lib) {
                    case .optimized(let bytes): optimized += 1; saved += bytes
                    case .restored: restored += 1
                    case .unchanged, .compact: break
                    }
                }
            }
            refreshAll()
            reloadDetail()

            var parts = ["Approved \(rows.count) document\(rows.count == 1 ? "" : "s")"]
            if moved > 0 { parts.append("moved \(moved)") }
            if optimized > 0 { parts.append("optimized \(optimized), saving \(ByteFormat.string(saved))") }
            if restored > 0 { parts.append("restored \(restored) to the original") }
            if failed > 0 {
                parts.append("\(failed) could not be moved and \(failed == 1 ? "was" : "were") left where \(failed == 1 ? "it is" : "they are")")
            }
            notify(parts.joined(separator: ", ") + ".", failed > 0 ? .warning : .success)
        }
    }

    func suggestedFolder(for row: DocumentRow) async -> String? {
        guard let lib = library(of: row) else { return nil }
        let suggestions = (try? await lib.store.pathSuggestions(for: row.doc)) ?? []
        guard let best = suggestions.first(where: { lib.owns(path: $0.path) }),
              Store.canonical(best.path) != Store.canonical(row.directory) else { return nil }
        return best.path
    }

    /// Only a new arrival drops its original; one already in the library keeps it so it can be reverted.
    private func keep(_ version: KeptVersion, of row: DocumentRow, in lib: Library) async -> KeepOutcome {
        switch version {
        case .original:
            guard (try? await lib.store.originalFileURL(for: row.doc)) != nil,
                  await lib.indexer.revertOptimization(ids: [row.doc]) > 0 else { return .unchanged }
            return .restored
        case .optimized:
            var outcome = KeepOutcome.unchanged
            if row.originalSize == nil {
                let result = await lib.indexer.optimize(ids: [row.doc])
                outcome = result.count > 0 ? .optimized(saved: result.saved) : .compact
            }
            if row.fromOutside { try? await lib.store.deleteOriginalFile(for: row.doc) }
            return outcome
        }
    }

    /// Optimizes a throwaway copy, so the review can show the result; nil when it would not help.
    func optimizationPreview(of row: DocumentRow) async -> OptimizationPreview? {
        guard let lib = library(of: row) else { return nil }
        let options = lib.settings.optimizerOptions
        let source = row.url
        return await Task.detached(priority: .utility) { () -> OptimizationPreview? in
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("doctopus-preview-\(UUID().uuidString)", isDirectory: true)
            let stem = source.deletingPathExtension().lastPathComponent
            let copy = dir.appendingPathComponent("\(stem) (optimized).\(source.pathExtension)")
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
                  (try? fm.copyItem(at: source, to: copy)) != nil,
                  let result = try? Optimizer.optimize(url: copy, options: options) else {
                try? fm.removeItem(at: dir)
                return nil
            }
            return OptimizationPreview(url: copy, newSize: result.newSize)
        }.value
    }

    private func rowAfter(_ row: DocumentRow) -> DocumentRef? {
        guard let index = documents.firstIndex(where: { $0.id == row.id }) else { return nil }
        if index + 1 < documents.count { return documents[index + 1].id }
        return index > 0 ? documents[index - 1].id : nil
    }
}
