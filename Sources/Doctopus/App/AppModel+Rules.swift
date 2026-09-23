import Foundation

extension AppModel {

    func ruleMatches(for row: DocumentRow) -> [RuleMatch] {
        library(of: row)?.ruleMatches[row.doc] ?? []
    }

    func pendingRuleMatches(for row: DocumentRow) -> [RuleMatch] {
        ruleMatches(for: row).filter(\.isPending)
    }

    /// Debounced, because a refresh arrives for every document the indexer
    /// finishes; the store remembers what it matched, so a pass after the
    /// first only reads the text of documents that changed.
    func refreshRuleMatches() {
        ruleMatchTask?.cancel()
        let libs = libraries
        ruleMatchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            for lib in libs {
                guard !Task.isCancelled else { return }
                guard let matches = try? await lib.store.ruleMatches() else { continue }
                guard !Task.isCancelled, self != nil else { return }
                if lib.ruleMatches != matches { lib.ruleMatches = matches }
            }
        }
    }

    func applyRule(_ match: RuleMatch, to row: DocumentRow) {
        guard let lib = library(of: row) else { return }
        Task {
            guard let rule = try? await lib.store.rules().first(where: { $0.id == match.ruleID }) else {
                notify("That rule no longer exists.", .info)
                refreshRuleMatches()
                return
            }
            let result = (try? await lib.store.applyRuleToExisting(rule, onlyTo: row.doc))
                ?? Store.RuleApplyResult()
            if result.matched > 0,
               let path = try? await lib.store.documentPath(row.doc) {
                await lib.indexer.syncAliases(docID: row.doc, target: URL(fileURLWithPath: path))
            }
            refreshAll()
            reloadDetail()
            notify(result.matched > 0 ? "Applied “\(rule.name)” to “\(row.displayTitle)”."
                                      : "“\(rule.name)” no longer matches “\(row.displayTitle)”.",
                   result.matched > 0 ? .success : .info)
        }
    }

    /// An outlier keeps matching the rule, but is no longer pointed out, nor
    /// filed by it when the rule is applied to existing documents or the
    /// document is reprocessed.
    func setRuleSuppressed(_ suppressed: Bool, _ match: RuleMatch, for row: DocumentRow) {
        guard let lib = library(of: row) else { return }
        Task {
            await setRuleSuppressed(suppressed, rule: match.ruleID, name: match.ruleName,
                                    doc: row.doc, in: lib)
            reloadDetail()
        }
    }

    func setRuleSuppressed(_ suppressed: Bool, rule ruleID: Int64, name: String,
                           doc: Int64, in lib: Library) async {
        try? await lib.store.setRuleSuppressed(suppressed, rule: ruleID, doc: doc)
        lib.outlierRevision += 1
        // Ahead of the debounced pass, so the badge goes the moment it is asked to.
        if var matches = lib.ruleMatches[doc],
           let index = matches.firstIndex(where: { $0.ruleID == ruleID }) {
            matches[index].suppressed = suppressed
            matches.removeAll { !$0.suppressed && $0.changes.isEmpty }
            lib.ruleMatches[doc] = matches.isEmpty ? nil : matches
        }
        try? await lib.store.logEdit(docID: doc, detail: suppressed
                                     ? "Marked as an outlier for rule “\(name)”"
                                     : "No longer an outlier for rule “\(name)”")
        refreshRuleMatches()
        if case .outliers(let id, let rule) = selection, id == lib.id, rule == ruleID {
            reloadDocuments(resetPaging: false)
        }
    }

    func showOutliers(of ruleID: Int64, in lib: Library) {
        searchText = ""
        selection = .outliers(library: lib.id, rule: ruleID)
    }
}
