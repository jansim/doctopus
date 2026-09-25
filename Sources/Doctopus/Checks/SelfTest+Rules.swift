import Foundation

/// Rules: what they match, where they file, and how a match is reviewed.
extension SelfTest {
    static func refiledRules(store: Store) {
        let base = store.root.path
        func filing(_ template: String) -> Rule {
            Rule(id: 0, name: template, actions: [RuleAction(kind: .addTags, value: "x"),
                                                  RuleAction(kind: .moveFile, value: template)])
        }
        func refiled(_ template: String, _ old: String, _ new: String) -> String? {
            filing(template).refiling(base + "/" + old, to: base + "/" + new, root: base)?.destination
        }
        Check.that("a rule filing into a renamed folder follows it, subfolders and placeholders kept",
                   refiled("Finances/Invoices/{year}", "Finances", "Money") == "Money/Invoices/{year}"
                       && refiled("finances/invoices", "Finances/Invoices", "Finances/Bills") == "Finances/Bills"
                       && refiled(base + "/Finances/{year}", "Finances", "Money") == base + "/Money/{year}",
                   refiled("Finances/Invoices/{year}", "Finances", "Money") ?? "not refiled")
        Check.that("…but not one that only reaches it by way of a placeholder, or a namesake",
                   refiled("Insurance/{correspondent}", "Insurance/Allianz", "Insurance/Allianz SE") == nil
                       && refiled("Finances-Old/{year}", "Finances", "Money") == nil
                       && refiled("Other/Finances", "Finances", "Money") == nil
                       && Rule(id: 0, name: "No folder").refiling(base + "/A", to: base + "/B", root: base) == nil)
    }

    static func routing(store: Store, settings: AppSettings, root: URL, rows: [DocumentRow]) async {
        print("\nROUTING (dry run against starter rules)")
        let router = Router(rules: (try? await store.rules()) ?? [],
                            derivedTemplate: settings.derivedTemplate, root: root, deriveWhenNoRule: true)
        for row in rows {
            let text = (try? await store.ocrText(row.doc)) ?? ""
            let findings = DocumentAnalyzer.analyze(url: row.url, text: text, fallbackDate: row.createdAt,
                                                    knownCorrespondents: [])
            let decision = router.evaluate(text: text, filename: row.filename, findings: findings,
                                           insight: nil, currentDirectory: row.url.deletingLastPathComponent())
            let target = decision.destination.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") } ?? "(stays put)"
            print("  \(row.filename.padded(38)) → \(target.padded(28)) [\(decision.rule)]")
        }

        func derives(_ template: String, dateSource: String) -> Bool {
            let findings = DocumentAnalyzer.Findings(date: .now, dateSource: dateSource, correspondent: "Acme")
            return Router(rules: [], derivedTemplate: template, root: root, deriveWhenNoRule: true)
                .evaluate(text: "", filename: "scan.pdf", findings: findings, insight: nil,
                          currentDirectory: root).shouldMove
        }
        Check.that("a derived folder by year needs a date read off the document",
                   derives("{correspondent}/{year}", dateSource: "ocr")
                       && !derives("{correspondent}/{year}", dateSource: "fs"))
        Check.that("…but not when its template has no date in it",
                   derives("{correspondent}", dateSource: "fs"))
    }

    static func ruleEditing(store: Store, indexer: Indexer, settings: AppSettings, root: URL,
                            rows: [DocumentRow], stats: Store.Stats) async {
        print("\nRULE EDITING")
        let samples = (try? await store.ruleSamples()) ?? []
        Check.that("every document is a rule sample", samples.count == stats.total,
                   "\(samples.count)/\(stats.total)")
        Check.that("a pattern is read the way the rule says, not the way it is punctuated",
                   Router.kind(of: "invoice, rechnung") == .words(["invoice", "rechnung"])
                       && Router.kind(of: "Acme (UK) Ltd") == .words(["acme (uk) ltd"])
                       && Router.kind(of: "^inv.*", mode: .regex) == .regex
                       && { if case .invalidRegex = Router.kind(of: "inv(oice", mode: .regex) { return true }
                            return false }())
        if var rule = ((try? await store.rules()) ?? []).last,
           let payslip = rows.first(where: { $0.filename.lowercased().contains("gehalt") }) {
            let original = rule
            rule.name = "Edited"
            rule.conditions = [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")]
            rule.actions = [RuleAction(kind: .moveFile, value: "Edited/{year}")]
            _ = try? await store.upsertRule(rule)
            let others = ((try? await store.rules()) ?? []).map(\.id).filter { $0 != rule.id }
            try? await store.reorderRules([rule.id] + others)
            let edited = (try? await store.rules()) ?? []
            Check.that("an edited rule is saved and can be moved to the top",
                       edited.first?.id == rule.id
                           && edited.first?.conditions.first?.pattern == "gehaltsabrechnung"
                           && edited.first?.conditions.first?.field == .filename
                           && edited.first?.destination == "Edited/{year}")
            let text = (try? await store.ocrText(payslip.doc)) ?? ""
            let findings = DocumentAnalyzer.analyze(url: payslip.url, text: text,
                                                    fallbackDate: payslip.createdAt, knownCorrespondents: [])
            let decision = Router(rules: edited,
                                  derivedTemplate: settings.derivedTemplate, root: root,
                                  deriveWhenNoRule: true)
                .evaluate(text: text, filename: payslip.filename, findings: findings, insight: nil,
                          currentDirectory: payslip.url.deletingLastPathComponent())
            print("  \(payslip.filename) → \(decision.destination?.path.replacingOccurrences(of: root.path + "/", with: "") ?? "(stays put)") [\(decision.rule)]")
            // The Payslips starter rule matches too, and names another folder.
            Check.that("routing follows the edited rule, in its new place",
                       decision.rule == "Edited"
                           && decision.candidates.first?.destination.path.contains("/Edited/") == true)
            Check.that("…and two rules naming different folders leave it for review",
                       decision.ambiguous && decision.destination == nil)

            let ruleA = Rule(id: 0, name: "RuleA", priority: 100,
                             conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                             actions: [RuleAction(kind: .moveFile, value: "A/{year}"),
                                       RuleAction(kind: .addTags, value: "tagA, commonTag")])
            let ruleB = Rule(id: 0, name: "RuleB", priority: 90,
                             conditions: [RuleCondition(field: .filename, pattern: "februar")],
                             actions: [RuleAction(kind: .moveFile, value: "B/{year}"),
                                       RuleAction(kind: .addTags, value: "tagB, commonTag")])
            let unionDecision = Router(rules: [ruleA, ruleB],
                                       derivedTemplate: "", root: root, deriveWhenNoRule: false)
                .evaluate(text: text, filename: payslip.filename, findings: findings, insight: nil,
                          currentDirectory: payslip.url.deletingLastPathComponent())
            Check.that("matching rules combine tags as a union",
                       unionDecision.tags.contains("tagA") && unionDecision.tags.contains("tagB") && unionDecision.tags.count == 3)

            await conditionsAndActions(store: store, root: root, text: text,
                                       findings: findings, payslip: payslip)

            let assignRule = Rule(id: 0, name: "SetPayroll", priority: 100,
                                  conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                                  actions: [RuleAction(kind: .addTags, value: "payroll"),
                                            RuleAction(kind: .setCorrespondent, value: "Acme HR"),
                                            RuleAction(kind: .setDocType, value: "Payslip")])
            let savedAssignID = (try? await store.upsertRule(assignRule)) ?? 0
            let applyResult = await indexer.applyRule(assignRule)
            Check.that("rule can assign metadata and tags to existing documents",
                       applyResult.matched > 0 && applyResult.tagged > 0)
            try? await store.deleteRule(savedAssignID)
            if let payrollTag = try? await store.tagID(named: "payroll") {
                try? await store.deleteTag(payrollTag)
            }

            _ = try? await store.upsertRule(original)
            try? await store.reorderRules(((try? await store.rules()) ?? [])
                .sorted { $0.priority > $1.priority }.map(\.id))

            await ruleMatches(store: store, indexer: indexer, payslip: payslip)
        }
    }

    static func matchModes(store: Store) async {
        print("\nMATCH MODES")
        func hits(_ pattern: String, _ mode: MatchMode, _ subject: String,
                  insensitive: Bool = true) -> Bool {
            PatternMatcher.matches(pattern, mode: mode, insensitive: insensitive, in: subject)
        }
        Check.that("“Acme (UK) Ltd” is a name when the rule says it is one",
                   hits("Acme (UK) Ltd", .anyWord, "Invoice from Acme (UK) Ltd"))
        Check.that("a new condition defaults to reading its pattern as words",
                   RuleCondition(pattern: "Acme (UK) Ltd").mode == .anyWord)
        Check.that("a word matches the whole word and nothing longer",
                   hits("rechnung", .anyWord, "Ihre Rechnung, Nr. 42")
                       && !hits("rechnung", .anyWord, "Rechnungsnummer 42")
                       && !hits("rechnung", .anyWord, "Gehaltsabrechnung"))
        Check.that("a trailing * matches the start of a word",
                   hits("rechnung*", .anyWord, "Rechnungsnummer 42")
                       && !hits("rechnung*", .anyWord, "Gehaltsabrechnung"))
        Check.that("a leading * matches the end of one, and both anywhere in it",
                   hits("*rechnung", .anyWord, "Gehaltsabrechnung")
                       && !hits("*rechnung", .anyWord, "Rechnungsnummer")
                       && hits("*rechnung*", .anyWord, "Gehaltsabrechnungen"))
        Check.that("a phrase in a word pattern is matched whole too",
                   hits("net pay", .anyWord, "Total net pay: 2.400")
                       && !hits("net pay", .anyWord, "net payment"))
        Check.that("a pattern written before * existed keeps its meaning",
                   Schema.openingEnds("invoice,  rechnung*, net pay") == "invoice*, rechnung*, net pay*")
        Check.that("all words needs every one of them",
                   hits("amount, due", .allWords, "the amount due is")
                       && !hits("amount, missing", .allWords, "the amount due is"))
        Check.that("a phrase matches across the line break OCR put in it",
                   hits("amount due", .exactPhrase, "Total\namount\n  due   today")
                       && !hits("amount due", .exactPhrase, "amount is overdue"))
        Check.that("a regex is one only when the rule says so",
                   hits("^inv-\\d+", .regex, "inv-4821")
                       && !hits("^inv-\\d+", .anyWord, "inv-4821"))
        Check.that("case can be insisted on",
                   hits("ACME", .anyWord, "acme corp")
                       && !hits("ACME", .anyWord, "acme corp", insensitive: false))
        Check.that("fuzzy survives a misread letter",
                   hits("rechnung", .fuzzy, "Rechnunq Nr. 42")
                       && !hits("rechnung", .fuzzy, "Kontoauszug"))
        for pattern in ["Acme (UK) Ltd", "^inv-\\d+", "inv(oice"] {
            print("  " + pattern.padded(20) + " → " + (MatchMode(rawValue: Schema.inferredMode(pattern))?.shortLabel ?? "?"))
        }
        Check.that("a pattern that was read as a regex keeps being one when migrated",
                   Schema.inferredMode("^inv-\\d+") == MatchMode.regex.rawValue)
        Check.that("…and one that never compiled is migrated as the words it was matching",
                   Schema.inferredMode("inv(oice") == MatchMode.anyWord.rawValue)

        if let id = try? await store.upsertRule(
            Rule(id: 0, name: "Phrase Test", enabled: false, priority: 1,
                 requiresAll: true,
                 conditions: [RuleCondition(field: .text, pattern: "amount due",
                                            mode: .exactPhrase, caseInsensitive: false),
                              RuleCondition(field: .filename, pattern: "credit note",
                                            negated: true)],
                 actions: [RuleAction(kind: .moveFile, value: "Filed/Phrase"),
                           RuleAction(kind: .addTags, value: "phrase, filed")])) {
            let saved = ((try? await store.rules()) ?? []).first { $0.id == id }
            Check.that("a rule remembers how it reads its patterns",
                       saved?.conditions.count == 2 && saved?.requiresAll == true
                           && saved?.conditions.first?.mode == .exactPhrase
                           && saved?.conditions.first?.caseInsensitive == false
                           && saved?.conditions.last?.negated == true
                           && saved?.conditions.last?.field == .filename)
            Check.that("…and what it does, in the order it was given",
                       saved?.actions.map(\.kind) == [.moveFile, .addTags]
                           && saved?.destination == "Filed/Phrase"
                           && saved?.tagNames == ["phrase", "filed"])
            try? await store.deleteRule(id)
            Check.that("deleting a rule takes its conditions and actions with it",
                       ((try? await store.rules()) ?? []).allSatisfy { $0.id != id })
        }
    }

    private static func ruleMatches(store: Store, indexer: Indexer, payslip: DocumentRow) async {
        print("\nRULE MATCHES")
        let rule = Rule(id: 0, name: "Outlier Check", priority: 1,
                        conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                        actions: [RuleAction(kind: .addTags, value: "outlier-check")])
        guard let id = try? await store.upsertRule(rule) else {
            Check.that("a rule to check matches with is saved", false)
            return
        }
        var saved = rule
        saved.id = id

        func match() async -> RuleMatch? {
            ((try? await store.ruleMatches()) ?? [:])[payslip.doc]?.first { $0.ruleID == id }
        }
        func tagged() async -> Bool {
            ((try? await store.tags(for: payslip.doc)) ?? []).contains { $0.name == "outlier-check" }
        }

        let pending = await match()
        Check.that("a matching rule that would change a document is pointed out on it",
                   pending?.isPending == true && pending?.changes == [.addTags(["outlier-check"])],
                   pending.map { $0.changes.map(\.label).joined(separator: "; ") } ?? "no match")
        let reviewing = (try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                        sort: .added, ascending: false,
                                                        ruleMatched: [payslip.doc])) ?? []
        Check.that("Needs Review lists a document a rule would still change",
                   reviewing.contains { $0.doc == payslip.doc })

        try? await store.setRuleSuppressed(true, rule: id, doc: payslip.doc)
        let suppressed = await match()
        Check.that("an outlier is still listed, but no longer pending",
                   suppressed?.suppressed == true && suppressed?.isPending == false)
        let counts = (try? await store.suppressionCounts()) ?? [:]
        let listed = (try? await store.listDocuments(selection: .outliers(rule: id),
                                                     query: SearchQuery(""), sort: .added,
                                                     ascending: false)) ?? []
        Check.that("a rule counts and lists its outliers",
                   counts[id] == 1 && listed.map(\.doc) == [payslip.doc],
                   "count \(counts[id] ?? 0), listed \(listed.count)")
        let skipped = await indexer.applyRule(saved)
        let skippedTagged = await tagged()
        Check.that("Apply to Existing leaves an outlier alone",
                   !skippedTagged, "matched \(skipped.matched)")

        try? await store.setRuleSuppressed(false, rule: id, doc: payslip.doc)
        let handedBack = await match()
        Check.that("an outlier can be handed back to its rule", handedBack?.isPending == true)
        let applied = await indexer.applyRule(saved, onlyTo: payslip.doc)
        let appliedTagged = await tagged()
        let after = await match()
        Check.that("applying the rule to the one document settles the match",
                   applied.matched == 1 && appliedTagged && after == nil)
        await partialRuleMatch(store: store, indexer: indexer, payslip: payslip)
        await conflictingRuleMatches(store: store, payslip: payslip)

        let original = try? await store.detail(payslip.doc)
        let tagsBefore = Set(((try? await store.tags()) ?? []).map(\.tagID))
        try? await store.setDocumentApproved(payslip.doc, false)
        saved.actions.append(RuleAction(kind: .moveFile, value: "Outlier Check/{year}"))
        _ = try? await store.upsertRule(saved)
        await indexer.reroute(applyingActions: true)
        let followsRule = ((try? await store.pathSuggestions(for: payslip.doc)) ?? [])
            .contains { $0.path.contains("/Outlier Check/") }
        Check.that("a changed rule is re-applied to a document awaiting review", followsRule)
        try? await store.setDocumentDate(payslip.doc, Date(timeIntervalSince1970: 1_560_000_000))
        await indexer.reroute([payslip.doc], applyingActions: false)
        let followsDate = ((try? await store.pathSuggestions(for: payslip.doc)) ?? [])
            .contains { $0.path.hasSuffix("/Outlier Check/2019") }
        Check.that("correcting the date moves the suggested folder with it", followsDate)
        try? await store.setDocumentDate(payslip.doc, original?.row.docDate,
                                         source: original?.dateSource ?? "fs")
        try? await store.setDocumentApproved(payslip.doc, true)
        // Re-routing applied the starter rules' tags too; later checks count tags.
        for tag in (try? await store.tags()) ?? [] where !tagsBefore.contains(tag.tagID) {
            try? await store.deleteTag(tag.tagID)
        }

        try? await store.setRuleSuppressed(true, rule: id, doc: payslip.doc)
        try? await store.deleteRule(id)
        let orphaned = ((try? await store.suppressions()) ?? [:])[payslip.doc]?.contains(id) == true
        Check.that("deleting a rule forgets its outliers", !orphaned)
        if let tag = try? await store.tagID(named: "outlier-check") { try? await store.deleteTag(tag) }
    }

    /// Accepting part of a match from Needs Review: the ticked changes are
    /// applied with the rule cut down to them, and the rule is suppressed.
    private static func partialRuleMatch(store: Store, indexer: Indexer, payslip: DocumentRow) async {
        let rule = Rule(id: 0, name: "Partial Check", priority: 1,
                        conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                        actions: [RuleAction(kind: .addTags, value: "partial-check"),
                                  RuleAction(kind: .setDocType, value: "Partial Check")])
        guard let id = try? await store.upsertRule(rule) else {
            Check.that("a rule to accept part of is saved", false)
            return
        }
        var saved = rule
        saved.id = id
        let typeBefore = (try? await store.detail(payslip.doc))?.row.docType

        let match = ((try? await store.ruleMatches()) ?? [:])[payslip.doc]?.first { $0.ruleID == id }
        let accepted = Set(match?.changes.filter { $0.kind == .addTags } ?? [])
        Check.that("a match offers each of its changes apart",
                   match?.changes.count == 2 && accepted.count == 1,
                   match.map { $0.changes.map(\.label).joined(separator: "; ") } ?? "no match")
        _ = await indexer.applyRule(saved.limited(to: Set(accepted.map(\.kind))), onlyTo: payslip.doc)
        try? await store.setRuleSuppressed(true, rule: id, doc: payslip.doc)

        let detail = try? await store.detail(payslip.doc)
        let tagged = ((try? await store.tags(for: payslip.doc)) ?? []).contains { $0.name == "partial-check" }
        let settled = ((try? await store.ruleMatches()) ?? [:])[payslip.doc]?.first { $0.ruleID == id }
        Check.that("accepting part of a match applies only that and suppresses the rule",
                   tagged && detail?.row.docType == typeBefore && settled?.isPending == false,
                   "tagged \(tagged), type \(detail?.row.docType ?? "none"), pending \(settled?.isPending ?? false)")

        try? await store.deleteRule(id)
        if let tag = try? await store.tagID(named: "partial-check") { try? await store.deleteTag(tag) }
    }

    /// Two rules both wanting a document: the folders they disagree on are a
    /// conflict to choose from, the tags they add together are not.
    private static func conflictingRuleMatches(store: Store, payslip: DocumentRow) async {
        func rule(_ name: String, folder: String, tag: String) -> Rule {
            Rule(id: 0, name: name, priority: 1,
                 conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                 actions: [RuleAction(kind: .moveFile, value: folder),
                           RuleAction(kind: .addTags, value: tag)])
        }
        guard let first = try? await store.upsertRule(rule("Conflict A", folder: "Conflict A", tag: "conflict-a")),
              let second = try? await store.upsertRule(rule("Conflict B", folder: "Conflict B", tag: "conflict-b"))
        else {
            Check.that("two rules to conflict are saved", false)
            return
        }
        let matches = ((try? await store.ruleMatches()) ?? [:])[payslip.doc]?
            .filter { [first, second].contains($0.ruleID) } ?? []
        let conflicts = RuleMatch.conflicts(among: matches)
        Check.that("rules moving a document to different folders conflict, and their tags do not",
                   matches.count == 2 && conflicts.map(\.kind) == [.moveFile]
                       && Set(conflicts.first?.options.map(\.ruleID) ?? []) == [first, second],
                   conflicts.map(\.summary).joined(separator: "; "))

        var choices = RuleMatchChoices()
        let unsettled = conflicts.allSatisfy(choices.isSettled)
        if let conflict = conflicts.first { choices.choose(first, in: conflict) }
        let loser = matches.first { $0.ruleID == second }
        Check.that("choosing one rule settles the conflict and leaves the other's tags",
                   !unsettled && conflicts.allSatisfy(choices.isSettled)
                       && loser.map(choices.accepted) == [.addTags(["conflict-b"])])

        // A rule already applied still has a say: the one after it must not quietly undo it.
        let folder = store.relPath((try? await store.detail(payslip.doc))?.row.directory ?? payslip.directory)
        try? await store.deleteRule(second)
        guard !folder.isEmpty,
              let here = try? await store.upsertRule(rule("Conflict Here", folder: folder, tag: "conflict-a"))
        else {
            Check.that("a rule already in effect is saved", false)
            try? await store.deleteRule(first)
            return
        }
        let withApplied = ((try? await store.ruleMatches()) ?? [:])[payslip.doc]?
            .filter { [first, here].contains($0.ruleID) } ?? []
        let applied = withApplied.first { $0.ruleID == here }
        let contested = RuleMatch.conflicts(among: withApplied)
        Check.that("a rule already in effect conflicts with one that would move the document away",
                   applied?.changes.isEmpty == false && applied?.inEffect == [.move(to: folder)]
                       && contested.map(\.kind) == [.moveFile]
                       && Set(contested.first?.options.map(\.ruleID) ?? []) == [first, here],
                   contested.map(\.summary).joined(separator: "; "))

        try? await store.deleteRule(first)
        let others = ((try? await store.ruleMatches()) ?? [:])[payslip.doc] ?? []
        let options = RuleMatch.conflicts(among: others).flatMap(\.options)
        Check.that("…and what is in effect is only pointed out where another rule disagrees",
                   others.allSatisfy { match in
                       match.inEffect.allSatisfy { change in
                           options.contains { $0.ruleID == match.ruleID && $0.change == change }
                       }
                   }, others.map(\.summary).joined(separator: " | "))
        try? await store.deleteRule(here)
    }

    private static func conditionsAndActions(store: Store, root: URL, text: String,
                                             findings: DocumentAnalyzer.Findings,
                                             payslip: DocumentRow) async {
        func decide(_ rule: Rule) -> Router.Decision {
            Router(rules: [rule], derivedTemplate: "", root: root,
                   deriveWhenNoRule: false)
                .evaluate(text: text, filename: payslip.filename, findings: findings, insight: nil,
                          currentDirectory: payslip.url.deletingLastPathComponent())
        }

        let both = Rule(id: 0, name: "Both", requiresAll: true,
                        conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung"),
                                     RuleCondition(field: .filename, pattern: "februar")],
                        actions: [RuleAction(kind: .moveFile, value: "Filed/Both")])
        var missing = both
        missing.conditions[1].pattern = "doctopus-nothing-matches-this"
        Check.that("all of the conditions means all of them",
                   decide(both).destination?.path.contains("/Filed/Both") == true
                       && decide(missing).destination == nil)

        var either = missing
        either.requiresAll = false
        Check.that("…and any of them means one is enough",
                   decide(either).destination?.path.contains("/Filed/Both") == true)

        var excluded = both
        excluded.conditions[1] = RuleCondition(field: .filename, pattern: "februar", negated: true)
        Check.that("a condition can rule a document out", decide(excluded).destination == nil)

        let labelOnly = Rule(id: 0, name: "Label",
                             conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                             actions: [RuleAction(kind: .addTags, value: "labelled"),
                                       RuleAction(kind: .setDocType, value: "Payslip")])
        let labelled = decide(labelOnly)
        Check.that("a rule that files nothing still tags and labels",
                   labelled.destination == nil && labelled.tags == ["labelled"]
                       && labelled.tagsFromRule && labelled.setDocType == "Payslip")

        var renaming = labelOnly
        renaming.actions.append(RuleAction(kind: .renameFile, value: "{date}_{type}"))
        Check.that("a rule can ask for a rename without moving anything",
                   decide(renaming).rename == "{date}_{type}" && decide(renaming).destination == nil)

        var halfTyped = labelOnly
        halfTyped.requiresAll = true
        halfTyped.conditions.append(RuleCondition())
        Check.that("a condition with nothing in it changes nothing",
                   decide(halfTyped).tags == ["labelled"])
        Check.that("…and a rule with no condition at all matches nothing",
                   !Rule(id: 0, name: "Empty",
                         actions: [RuleAction(kind: .addTags, value: "x")])
                       .matches(Rule.Subject(text: text, filename: payslip.filename)))

        func tagRule(_ pattern: String, negated: Bool = false, mode: MatchMode = .anyWord) -> Rule {
            Rule(id: 0, name: "Tagged",
                 conditions: [RuleCondition(field: .tags, pattern: pattern, mode: mode, negated: negated)],
                 actions: [RuleAction(kind: .setDocType, value: "Tagged")])
        }
        let tagged = Rule.Subject(text: text, filename: payslip.filename, tags: ["Work", "tax 2025"])
        let untagged = Rule.Subject(text: text, filename: payslip.filename)
        Check.that("a tag condition matches a document carrying the tag",
                   tagRule("work").matches(tagged) && !tagRule("work").matches(untagged))
        Check.that("…and a negated one matches a document without it, untagged included",
                   tagRule("invoice", negated: true).matches(tagged)
                       && tagRule("work", negated: true).matches(untagged)
                       && !tagRule("work", negated: true).matches(tagged))
        Check.that("…and a phrase cannot run across two tags",
                   tagRule("work tax", mode: .exactPhrase).matches(tagged) == false
                       && tagRule("tax 2025", mode: .exactPhrase).matches(tagged))
        Check.that("the router hands a document's tags to the rules",
                   Router(rules: [tagRule("work")], derivedTemplate: "", root: root, deriveWhenNoRule: false)
                       .evaluate(text: text, filename: payslip.filename, findings: findings, insight: nil,
                                 currentDirectory: root, tags: ["Work"]).setDocType == "Tagged")

        var stored = tagRule("tag-condition-check")
        stored.name = "Tag Condition Check"
        guard let id = try? await store.upsertRule(stored) else {
            Check.that("a rule with a tag condition is saved", false)
            return
        }
        func matched() async -> Bool {
            ((try? await store.ruleMatches()) ?? [:])[payslip.doc]?.contains { $0.ruleID == id } == true
        }
        let before = await matched()
        let tag = try? await store.tagID(named: "tag-condition-check")
        if let tag { try? await store.assign(tag: tag, to: payslip.doc) }
        let after = await matched()
        Check.that("tagging a document brings up the rules that match on that tag",
                   !before && after, "before \(before), after \(after)")
        try? await store.deleteRule(id)
        if let tag { try? await store.deleteTag(tag) }
    }
}
