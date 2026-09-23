import Foundation

extension AppModel {

    func ruleMatches(for row: DocumentRow) -> [RuleMatch] {
        library(of: row)?.ruleMatches[row.doc] ?? []
    }

    func pendingRuleMatches(for row: DocumentRow) -> [RuleMatch] {
        ruleMatches(for: row).filter(\.isPending)
    }

    /// Documents waiting for approval, and those a rule would still change.
    var needsReviewCount: Int {
        libraries.reduce(0) { count, lib in
            let waiting = lib.queue.filter { !$0.approved }
            return count + waiting.count + lib.ruleMatchedDocs.subtracting(waiting.map(\.docID)).count
        }
    }

    /// Debounced: the indexer triggers a refresh per document.
    func refreshRuleMatches() {
        ruleMatchTask?.cancel()
        let libs = libraries
        ruleMatchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            var changed = false
            for lib in libs {
                guard let matches = try? await lib.store.ruleMatches(naming: lib.settings.namingOptions) else { continue }
                guard !Task.isCancelled else { return }
                if lib.ruleMatches != matches {
                    changed = changed || lib.ruleMatchedDocs != Library.ruleMatchedDocs(in: matches)
                    lib.ruleMatches = matches
                }
            }
            if changed { ruleMatchedDocsChanged() }
        }
    }

    /// Needs Review lists what a rule would still change, so it follows along.
    private func ruleMatchedDocsChanged() {
        if selection == .needsReview { reloadDocuments(resetPaging: false) }
    }

    func rulesChanged(in lib: Library) {
        Task {
            await lib.indexer.reroute(applyingActions: true)
            refreshAll()
            reloadDetail()
        }
    }

    /// Accepting only some of a match's changes applies those and marks the
    /// document as an outlier, so the rule stops pointing out the rest.
    func applyRule(_ match: RuleMatch, to row: DocumentRow, accepting accepted: Set<RuleMatch.Change>? = nil) {
        applyRules([(match, accepted ?? Set(match.changes))], to: row)
    }

    /// Settles several matches as one step, which is how a choice between
    /// conflicting rules lands: each applies what was accepted of it, in turn,
    /// and one with anything left out is suppressed like a partial match.
    func applyRules(_ plan: [(match: RuleMatch, accepted: Set<RuleMatch.Change>)], to row: DocumentRow) {
        guard let lib = library(of: row), !plan.isEmpty else { return }
        Task {
            let rules = (try? await lib.store.rules()) ?? []
            let marks = await eventMarks([row])
            var total = Indexer.RuleApplyResult()
            var suppressed = 0
            for (match, accepted) in plan {
                guard var rule = rules.first(where: { $0.id == match.ruleID }) else { continue }
                let partial = accepted != Set(match.changes)
                if partial { rule = rule.limited(to: Set(accepted.map(\.kind))) }
                var result = Indexer.RuleApplyResult()
                if rule.hasEffect {
                    result = await lib.indexer.applyRule(rule, onlyTo: row.doc)
                }
                total.matched += result.matched
                total.moved += result.moved
                total.renamed += result.renamed
                if result.matched > 0,
                   let path = try? await lib.store.documentPath(row.doc) {
                    await lib.indexer.syncAliases(docID: row.doc, target: URL(fileURLWithPath: path))
                }
                if partial {
                    await setRuleSuppressed(true, rule: match.ruleID, name: match.ruleName,
                                            doc: row.doc, in: lib)
                    suppressed += 1
                }
            }
            if total.moved + total.renamed > 0 { offerUndo("Apply Rule", of: [row], since: marks) }
            refreshAll()
            reloadDetail()
            notify(Self.applyMessage(plan, matched: total.matched, suppressed: suppressed, row: row),
                   total.matched > 0 || suppressed > 0 ? .success : .info)
        }
    }

    private static func applyMessage(_ plan: [(match: RuleMatch, accepted: Set<RuleMatch.Change>)],
                                     matched: Int, suppressed: Int, row: DocumentRow) -> String {
        guard plan.count == 1, let only = plan.first else {
            return suppressed == 0
                ? "Applied \(plan.count) rules to “\(row.displayTitle)”."
                : "Applied your choice from \(plan.count) rules to “\(row.displayTitle)” and suppressed what you left out."
        }
        let (match, accepted) = only
        let name = match.ruleName
        if accepted == Set(match.changes) {
            return matched > 0 ? "Applied “\(name)” to “\(row.displayTitle)”."
                               : "“\(name)” no longer matches “\(row.displayTitle)”."
        }
        return accepted.isEmpty
            ? "Suppressed “\(name)” for “\(row.displayTitle)”."
            : "Applied \(accepted.count) of \(match.changes.count) changes from “\(name)” to “\(row.displayTitle)” and suppressed the rest."
    }

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

    func showOutliers(of ruleID: Int64, in lib: Library) {
        searchText = ""
        selection = .outliers(library: lib.id, rule: ruleID)
    }
}
