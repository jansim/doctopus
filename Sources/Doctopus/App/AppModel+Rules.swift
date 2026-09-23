import Foundation

extension AppModel {

    func ruleMatches(for row: DocumentRow) -> [RuleMatch] {
        library?.ruleMatches[row.doc] ?? []
    }

    func pendingRuleMatches(for row: DocumentRow) -> [RuleMatch] {
        ruleMatches(for: row).filter(\.isPending)
    }

    /// Documents waiting for approval, and those a rule would still change.
    var needsReviewCount: Int {
        guard let lib = library else { return 0 }
        let waiting = lib.queue.filter { !$0.approved }
        return waiting.count + lib.ruleMatchedDocs.subtracting(waiting.map(\.docID)).count
    }

    /// Debounced: the indexer triggers a refresh per document.
    func refreshRuleMatches() {
        ruleMatchTask?.cancel()
        guard let lib = library else { return }
        ruleMatchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard let matches = try? await lib.store.ruleMatches(naming: lib.settings.namingOptions),
                  !Task.isCancelled, lib.ruleMatches != matches else { return }
            let changed = lib.ruleMatchedDocs != Library.ruleMatchedDocs(in: matches)
            lib.ruleMatches = matches
            if changed { ruleMatchedDocsChanged() }
        }
    }

    /// Needs Review lists what a rule would still change, so it follows along.
    private func ruleMatchedDocsChanged() {
        if selection == .needsReview { reloadDocuments(resetPaging: false) }
    }

    func rulesChanged() {
        guard let lib = library else { return }
        Task {
            await lib.indexer.reroute(applyingActions: true)
            refreshAll()
            reloadDetail()
        }
    }

    /// Accepting only some of a match's changes applies those and marks the
    /// document as an outlier, so the rule stops pointing out the rest.
    func applyRule(_ match: RuleMatch, to row: DocumentRow, accepting accepted: Set<RuleMatch.Change>? = nil) {
        guard let lib = library else { return }
        let accepted = accepted ?? Set(match.changes)
        let partial = accepted != Set(match.changes)
        Task {
            guard var rule = try? await lib.store.rules().first(where: { $0.id == match.ruleID }) else { return }
            let name = rule.name
            if partial { rule = rule.limited(to: Set(accepted.map(\.kind))) }
            let mark = await eventMark()
            var result = Indexer.RuleApplyResult()
            if rule.hasEffect {
                result = await lib.indexer.applyRule(rule, onlyTo: row.doc)
            }
            if result.moved + result.renamed > 0 { offerUndo("Apply Rule", of: [row], since: mark) }
            if result.matched > 0,
               let path = try? await lib.store.documentPath(row.doc) {
                await lib.indexer.syncAliases(docID: row.doc, target: URL(fileURLWithPath: path))
            }
            if partial {
                await setRuleSuppressed(true, rule: match.ruleID, name: name, doc: row.doc, in: lib)
            }
            refreshAll()
            reloadDetail()
            if partial {
                notify(accepted.isEmpty
                       ? "Suppressed “\(name)” for “\(row.displayTitle)”."
                       : "Applied \(accepted.count) of \(match.changes.count) changes from “\(name)” to “\(row.displayTitle)” and suppressed the rest.",
                       .success)
            } else {
                notify(result.matched > 0 ? "Applied “\(name)” to “\(row.displayTitle)”."
                                          : "“\(name)” no longer matches “\(row.displayTitle)”.",
                       result.matched > 0 ? .success : .info)
            }
        }
    }

    func setRuleSuppressed(_ suppressed: Bool, _ match: RuleMatch, for row: DocumentRow) {
        guard let lib = library else { return }
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
        // Update now rather than after the debounced pass.
        if var matches = lib.ruleMatches[doc],
           let index = matches.firstIndex(where: { $0.ruleID == ruleID }) {
            matches[index].suppressed = suppressed
            matches.removeAll { !$0.suppressed && $0.changes.isEmpty }
            lib.ruleMatches[doc] = matches.isEmpty ? nil : matches
            ruleMatchedDocsChanged()
        }
        try? await lib.store.logEdit(docID: doc, detail: suppressed
                                     ? "Marked as an outlier for rule “\(name)”"
                                     : "No longer an outlier for rule “\(name)”")
        refreshRuleMatches()
        if case .outliers(let id, let rule) = selection, id == lib.id, rule == ruleID {
            reloadDocuments(resetPaging: false)
        }
    }

    func showOutliers(of ruleID: Int64) {
        guard let lib = library else { return }
        searchText = ""
        selection = .outliers(library: lib.id, rule: ruleID)
    }
}
