import Foundation

extension Indexer {
    /// Nothing here writes to a file the user already had: only a fresh import is
    /// optimized, and only an import nobody gave a destination is moved.
    @discardableResult
    func pipeline(id: Int64, path: String, isImport: Bool, route: Bool,
                  scanned: Bool, isNew: Bool) async -> String? {
        var url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? await store.markOCR(id, state: .skipped)
            return name
        }

        // Hashed before anything rewrites it, so the pre-optimization bytes are
        // on record: that is the hash an identical original would present on a
        // later import.
        if let hash = FileScanner.hash(url) { try? await store.setHash(id, hash, isOriginal: true) }

        try? await store.indexFinderTags(docID: id, entries: FinderTags.entries(url))

        // What went wrong on the way, kept in the document's history so a
        // half-read document says so rather than looking like a finished one.
        var problems: [String] = []

        // 1. Optimize before OCR so the indexed text matches the stored bytes.
        // Imports only: an existing file is rewritten only when someone picks
        // Optimize for it.
        var optimized: Optimizer.Result?
        if isImport && settings.optimizeOnImport {
            do { optimized = try await optimizeFile(id: id, url: url) }
            catch { problems.append(error.localizedDescription) }
        }

        let extracted: ExtractedText
        do {
            extracted = try TextExtractor.extract(url: url)
            if extracted.source == "unreadable" { problems.append("the file could not be opened to read its text") }
            if extracted.source == TextSource.locked {
                problems.append("it is password-protected, so its text could not be read")
            }
        } catch {
            extracted = ExtractedText(source: "failed")
            problems.append("its text could not be read (\(error.localizedDescription))")
        }
        if extracted.source == "failed" || extracted.source == "unreadable" {
            try? await store.markOCR(id, state: .failed)
        } else {
            do {
                try await store.storeOCR(docID: id, text: extracted.text,
                                         words: extracted.words, source: extracted.source,
                                         elapsedMS: extracted.elapsedMS, pageCount: extracted.pageCount)
            } catch { problems.append("its text could not be saved (\(error.localizedDescription))") }
        }

        let known = (try? await store.facets(column: "correspondent"))?.map(\.value) ?? []
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var findings = DocumentAnalyzer.analyze(url: url, text: extracted.text,
                                                fallbackDate: created, knownCorrespondents: known,
                                                options: await analyzerOptions())
        try? await store.setDateCandidates(findings.dates, for: id)

        if let fingerprint = try? await store.classifierTrainingFingerprint() {
            if await classifier.needsTraining(fingerprint: fingerprint),
               let trainData = try? await store.classifierTrainingData() {
                await classifier.trainIfNeeded(docs: trainData.docs, fingerprint: trainData.fingerprint)
            }
            if findings.correspondent == nil,
               let pred = await classifier.predictCorrespondent(text: extracted.text) {
                findings.correspondent = pred.label
            }
            if findings.docType == nil,
               let pred = await classifier.predictDocType(text: extracted.text) {
                findings.docType = pred.label
            }
            let predTags = await classifier.predictTags(text: extracted.text)
            for tag in predTags {
                try? await store.suggestTag(tag.label, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
            }
        }

        var insight: DocumentInsight?
        if settings.llmBackend != .off, !extracted.text.isEmpty || settings.sendsPageImage {
            let topTags = (try? await store.tags())?.prefix(10).map(\.name) ?? []
            let examples = (try? await store.filingExamples(for: id, limit: settings.llmExampleCount)) ?? []
            insight = await intelligence.enrich(text: extracted.text, filename: name, url: url,
                                                pageCount: extracted.pageCount, candidateTags: topTags,
                                                examples: examples)
            if insight == nil, !settings.predictedFields.isEmpty,
               extracted.text.count >= LLMPrompt.minimumCharacters {
                problems.append("the model gave no answer, so only what was read off the document is used")
            }
        }

        do {
            try await store.storeMetadata(Store.MetadataPatch(
                docID: id,
                title: insight?.title ?? findings.title,
                correspondent: insight?.correspondent ?? findings.correspondent,
                docType: insight?.docType ?? findings.docType,
                language: insight?.language ?? extracted.language,
                summary: insight?.summary,
                intent: insight?.intent,
                docDate: findings.date,
                dateSource: findings.dateSource,
                source: insight?.source ?? "heuristic",
                amount: findings.amount))
        } catch { problems.append("what was read off it could not be saved (\(error.localizedDescription))") }

        for tag in (insight?.tags ?? []).prefix(4) {
            try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
        }

        // 6. Routing — every new document gets suggestions; only undirected imports move.
        if isImport || isNew {
            await self.route(id: id, url: &url, text: extracted.text, findings: findings, insight: insight,
                             moving: isImport && route && settings.autoRouteImports,
                             chosen: isImport && !route, scanned: isImport && scanned,
                             action: isImport ? .imported : .indexed)
        }

        await forgetVanishedAliases(of: id)

        if !isImport, !isNew, optimized == nil {
            try? await store.logProcessing(docID: id, action: .indexed,
                                           detail: summaryLine(extracted, findings, insight),
                                           rule: nil, from: nil, to: nil, approved: true)
        }
        if !problems.isEmpty {
            try? await store.logProcessing(docID: id, action: .indexed,
                                           detail: "Indexed with problems: " + problems.joined(separator: "; "),
                                           rule: nil, from: nil, to: nil, approved: true)
        }
        return name
    }

    private func analyzerOptions() async -> DocumentAnalyzer.Options {
        if languageCache == nil {
            languageCache = .some((try? await store.dominantLanguage()) ?? nil)
        }
        if entityRuleCache == nil {
            entityRuleCache = (try? await store.matchingEntities()) ?? []
        }
        return DocumentAnalyzer.Options(dateOrder: settings.dateOrder,
                                        ignoredDays: settings.ignoredDays,
                                        language: languageCache ?? nil,
                                        entityRules: entityRuleCache ?? [])
    }

    private func summaryLine(_ t: ExtractedText, _ f: DocumentAnalyzer.Findings, _ i: DocumentInsight?) -> String {
        var parts: [String] = []
        parts.append("\(t.words) words via \(t.source)")
        if let type = i?.docType ?? f.docType { parts.append(type) }
        if let c = i?.correspondent ?? f.correspondent { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    /// Leaves out the rules the document is an outlier for.
    private func router(for id: Int64) async -> Router {
        let outlierOf = (try? await store.suppressedRuleIDs(for: id)) ?? []
        return Router(rules: ((try? await store.rules()) ?? []).filter { !outlierOf.contains($0.id) },
                      derivedTemplate: settings.derivedTemplate,
                      root: store.root,
                      deriveWhenNoRule: settings.deriveWhenNoRule)
    }

    /// A `chosen` folder heads the suggestions so the review keeps it.
    private func suggest(_ decision: Router.Decision, for id: Int64, chosen: URL?) async {
        var candidates = decision.candidates
        if let chosen {
            candidates.removeAll { $0.destination.standardizedFileURL == chosen.standardizedFileURL }
            candidates.insert(Router.Candidate(destination: chosen, rule: "chosen",
                                               explanation: "Chosen when it was brought in"), at: 0)
        }
        try? await store.setPathSuggestions(candidates.map {
            PathSuggestion(path: $0.destination.path, source: $0.rule,
                           explanation: $0.explanation)
        }, for: id)
    }

    private func tagNames(of id: Int64) async -> [String] {
        ((try? await store.tags(for: id)) ?? []).map(\.name)
    }

    private func applyRuleActions(_ decision: Router.Decision, to id: Int64) async {
        if let corr = decision.setCorrespondent {
            try? await store.storeMetadata(Store.MetadataPatch(docID: id, correspondent: corr, source: "rule"))
        }
        if let docType = decision.setDocType {
            try? await store.storeMetadata(Store.MetadataPatch(docID: id, docType: docType, source: "rule"))
        }
        guard decision.tagsFromRule else { return }
        for tag in decision.tags {
            if let tagID = try? await store.tagID(named: tag) {
                try? await store.assign(tag: tagID, to: id, auto: true)
            }
        }
    }

    /// Re-routes documents awaiting review from what the index holds, updating
    /// their suggested folders without moving files. `applyingActions` also
    /// re-applies rule tags and metadata; off after a hand edit, which it would
    /// overwrite.
    func reroute(_ ids: [Int64]? = nil, applyingActions: Bool) async {
        let waiting = Set((try? await store.reviewDocumentIDs()) ?? [])
        let targets = ids?.filter({ waiting.contains($0) }) ?? Array(waiting)
        for id in targets {
            guard let input = try? await store.routingInput(for: id) else { continue }
            let findings = DocumentAnalyzer.Findings(date: input.date, dateSource: input.dateSource,
                                                     correspondent: input.correspondent, docType: input.docType)
            let decision = await router(for: id).evaluate(
                text: input.text, filename: input.url.lastPathComponent, findings: findings,
                insight: DocumentInsight(correspondent: input.correspondent, docType: input.docType),
                currentDirectory: input.url.deletingLastPathComponent(),
                tags: await tagNames(of: id))
            let chosen = try? await store.pathSuggestions(for: id).first { $0.source == "chosen" }
            await suggest(decision, for: id, chosen: chosen.map { URL(fileURLWithPath: $0.path) })
            guard applyingActions else { continue }
            await applyRuleActions(decision, to: id)
            await forgetVanishedAliases(of: id)
        }
    }

    /// Renames and moves only when `moving`, except that a `scanned` file —
    /// named by Doctopus, not by anyone — takes the template's name wherever
    /// it lands.
    private func route(id: Int64, url: inout URL, text: String,
                       findings: DocumentAnalyzer.Findings, insight: DocumentInsight?,
                       moving: Bool, chosen: Bool, scanned: Bool, action: EventAction) async {
        let decision = await router(for: id).evaluate(
            text: text, filename: url.lastPathComponent, findings: findings, insight: insight,
            currentDirectory: url.deletingLastPathComponent(), tags: await tagNames(of: id))
        await suggest(decision, for: id, chosen: chosen ? url.deletingLastPathComponent() : nil)
        await applyRuleActions(decision, to: id)
        if !decision.tagsFromRule {
            for tag in decision.tags {
                try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
            }
        }

        guard moving else {
            // Into a chosen folder a rule's name is only a suggestion, like its
            // folder, and a scan it would rename is left for it to point out.
            if scanned, settings.nameScans, decision.rename == nil {
                await nameOnArrival(id: id, url: &url, template: nil, rule: nil,
                                    decision: decision, findings: findings, insight: insight, action: action)
            }
            let detail = decision.destination.map {
                "Suggested “\($0.lastPathComponent)”, left where it is — \(decision.explanation)"
            } ?? decision.explanation
            try? await store.logProcessing(docID: id, action: action, detail: detail,
                                           rule: decision.rule,
                                           from: nil, to: url.path, approved: false)
            return
        }

        // A rule's name comes first; failing one, a file Doctopus brought in
        // and is filing itself is named by the library's template when names
        // are enforced automatically, or when it is a scan.
        let byTemplate = decision.rename == nil
            && (settings.namingEnforcement == .automatic || (scanned && settings.nameScans))
        if decision.rename != nil || byTemplate {
            await nameOnArrival(id: id, url: &url, template: decision.rename,
                                rule: byTemplate ? nil : decision.rule,
                                decision: decision, findings: findings, insight: insight, action: action)
        }

        guard let destination = decision.destination else {
            try? await store.logProcessing(docID: id, action: .imported, detail: decision.explanation,
                                           rule: decision.rule,
                                           from: nil, to: url.path, approved: false)
            return
        }

        let from = url.path
        do {
            // Whether a rule or the derived path moved it, what was read off
            // the document still deserves a look, so it waits in Needs Review.
            url = try await relocate(id, from: url, into: destination, named: url.lastPathComponent,
                                     action: .routed, detail: decision.explanation, rule: decision.rule,
                                     approved: false)
        } catch {
            try? await store.logProcessing(docID: id, action: .imported,
                                           detail: "Could not move: \(error.localizedDescription)",
                                           rule: decision.rule,
                                           from: from, to: from, approved: false)
        }
    }

    /// Renames a file just brought in by `template`, or by the library's own
    /// when nil — and only then records the name as the template's, so later
    /// edits keep it in step.
    private func nameOnArrival(id: Int64, url: inout URL, template: String?, rule: String?,
                               decision: Router.Decision, findings: DocumentAnalyzer.Findings,
                               insight: DocumentInsight?, action: EventAction) async {
        let byTemplate = template == nil
        guard let template = template ?? settings.namingTemplate.nilIfBlank else { return }
        let name = Naming.render(template, Naming.Context(
            date: findings.date,
            correspondent: decision.setCorrespondent ?? insight?.correspondent ?? findings.correspondent,
            title: insight?.title ?? findings.title,
            docType: decision.setDocType ?? insight?.docType ?? findings.docType,
            language: insight?.language, counter: nil,
            originalStem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension,
            options: settings.namingOptions))
        var named = name == url.lastPathComponent
        if !named {
            do {
                url = try await relocate(id, from: url, into: url.deletingLastPathComponent(), named: name,
                                         action: .renamed, detail: name, rule: rule)
                named = true
            } catch {
                try? await store.logProcessing(docID: id, action: action,
                                               detail: "Could not rename to “\(name)”: \(error.localizedDescription)",
                                               rule: rule,
                                               from: url.path, to: url.path, approved: false)
            }
        }
        if byTemplate, named { try? await store.recordAutoName(name, for: id) }
    }
}
