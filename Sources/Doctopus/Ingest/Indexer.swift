import Foundation

struct IndexProgress: Sendable, Equatable {
    var phase: String = ""
    var done = 0
    var total = 0
    var current: String?
    var isRunning: Bool { total > 0 && done < total }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Orchestrates scan → hash → OCR → analyze → enrich → optimize → route.
/// Concurrency is bounded: oversubscribing OCR slows the machine, not the batch.
actor Indexer {
    private let store: Store
    private let intelligence: Intelligence
    private let classifier = DocumentClassifier()
    private var settings: AppSettings
    private var cancelled = false
    private var running = false

    private let onProgress: @Sendable (IndexProgress) -> Void
    private let onDataChanged: @Sendable () -> Void
    /// A scan that could not do its job, said rather than passed off as a clean one.
    private let onProblem: @Sendable (String) -> Void

    init(store: Store, intelligence: Intelligence, settings: AppSettings,
         onProgress: @escaping @Sendable (IndexProgress) -> Void,
         onDataChanged: @escaping @Sendable () -> Void,
         onProblem: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.intelligence = intelligence
        self.settings = settings
        self.onProgress = onProgress
        self.onDataChanged = onDataChanged
        self.onProblem = onProblem
    }

    func update(settings: AppSettings) async {
        self.settings = settings
        languageCache = nil
        entityRuleCache = nil
        await intelligence.update(settings: settings)
    }
    func cancel() { cancelled = true }
    var isRunning: Bool { running }

    @discardableResult
    func indexAll() async -> Int? {
        guard !running else { return nil }
        running = true
        cancelled = false
        defer { running = false; onProgress(IndexProgress()); onDataChanged() }

        onProgress(IndexProgress(phase: "Scanning", done: 0, total: 1))

        let name = store.root.lastPathComponent
        // A new library's first pass is its existing archive, not new arrivals.
        // An index that cannot say how much it holds cannot say which that is.
        let firstPass: Bool
        let upserted: [(id: Int64, path: String, isNew: Bool, changed: Bool)]
        var scan = FileScanner.scan(root: store.root)
        let found = scan.found.map { Self.facts($0) }
        do {
            firstPass = try await store.documentCount() == 0
            if cancelled { return nil }
            await relinkMoved(found)
            upserted = try await store.upsertDocuments(found)
        } catch {
            onProblem("Could not index \(name): \(error.localizedDescription)")
            return nil
        }
        var toProcess = upserted.filter(\.changed).map { ($0.id, $0.path) }
        let fresh = firstPass ? [] : Set(upserted.filter(\.isNew).map(\.id))

        var skipped: [String] = []
        // A library that reads as empty while its index still holds documents is
        // far likelier unmounted or unreadable than emptied, so it is not taken
        // at its word. A file deleted for real is still heard by the watcher.
        let indexed = (try? await store.allDocumentIDs(limit: 1))?.isEmpty == false
        let readAsEmpty = scan.found.isEmpty && indexed
        if readAsEmpty { scan.unreadable.append(store.root) }
        do { _ = try await store.reconcileMissing(scan) }
        catch { skipped.append("marking files that are gone as missing (\(error.localizedDescription))") }
        // Forgetting a document forgets everything anyone ever typed about it,
        // so it waits for a scan that saw the whole library.
        if scan.isComplete {
            do {
                _ = try await store.purgeMissing()
                _ = try await store.purgeDeleted()
            } catch { skipped.append("forgetting files gone for good (\(error.localizedDescription))") }
        } else {
            onProblem(Self.unreadableProblem(scan, in: store.root, readAsEmpty: readAsEmpty))
        }
        do {
            let pending = try await store.documentIDsNeedingOCR()
            let known = Set(toProcess.map(\.0))
            toProcess.append(contentsOf: pending.filter { !known.contains($0.id) }.map { ($0.id, $0.path) })
        } catch { skipped.append("finding documents still waiting for their text (\(error.localizedDescription))") }
        if !skipped.isEmpty {
            onProblem("Indexing \(name) skipped " + skipped.joined(separator: "; ") + ".")
        }

        onDataChanged()
        return await process(documents: toProcess, phase: "Indexing", isImport: false, found: fresh)
    }

    /// `rescanning`: folders FSEvents could only say *something* changed in.
    /// Those are walked again and reconciled, as a full scan would — whatever
    /// was deleted in there went by without an event of its own.
    func handleChanges(paths: [String], rescanning: [String] = []) async {
        let rootPrefix = store.root.path + "/"
        let fm = FileManager.default

        var toProcess: [(Int64, String)] = []
        var fresh: Set<Int64> = []
        var touched = false

        for directory in rescanning {
            let path = Store.canonical(directory)
            guard path == store.root.path || path.hasPrefix(rootPrefix),
                  !FileScanner.isInsideLibraryContainer(URL(fileURLWithPath: path)) else { continue }
            // A root that is gone is the library leaving, not its documents.
            guard fm.fileExists(atPath: store.root.path) else { continue }
            await resync(directory: URL(fileURLWithPath: path), into: &toProcess, fresh: &fresh)
            touched = true
        }

        for path in paths {
            guard path == store.root.path || path.hasPrefix(rootPrefix) else { continue }
            if FileScanner.isInsideLibraryContainer(URL(fileURLWithPath: path)) { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

            if isDir.boolValue {
                await rescan(directory: URL(fileURLWithPath: path), into: &toProcess, fresh: &fresh)
                touched = true
                continue
            }

            let url = URL(fileURLWithPath: path)
            guard FileScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }

            if !exists {
                try? await store.markMissing(path: path)
                touched = true
                continue
            }

            guard let v = try? url.resourceValues(forKeys: Set(Self.factKeys + [.isAliasFileKey])),
                  v.isAliasFile != true else { continue }
            let facts = Self.facts(path: path, v)

            // After a file-ID relink the upsert still runs, to catch an edit made on the way.
            if (try? await store.relinkByFileID(facts)) == nil,
               let hash = FileScanner.hash(url),
               (try? await store.relinkByHash(hash: hash, newPath: path)) != nil {
                touched = true
                continue
            }

            if let result = try? await store.upsertDocument(facts, origin: .inLibrary), result.changed {
                toProcess.append((result.id, path))
                if result.isNew { fresh.insert(result.id) }
            }
            touched = true
        }

        if touched { onDataChanged() }
        if !toProcess.isEmpty {
            await process(documents: toProcess, phase: "Indexing", isImport: false, found: fresh)
        }
    }

    private func rescan(directory: URL, into toProcess: inout [(Int64, String)],
                        fresh: inout Set<Int64>) async {
        let found = FileScanner.scan(root: directory).found.map { Self.facts($0) }
        await relinkMoved(found)
        for facts in found {
            if let r = try? await store.upsertDocument(facts, origin: .inLibrary), r.changed {
                toProcess.append((r.id, facts.path))
                if r.isNew { fresh.insert(r.id) }
            }
        }
    }

    private func resync(directory: URL, into toProcess: inout [(Int64, String)],
                        fresh: inout Set<Int64>) async {
        var isDir: ObjCBool = false
        let scan = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) && isDir.boolValue
            ? FileScanner.scan(root: directory) : FileScanner.Scan()
        let found = scan.found.map { Self.facts($0) }
        await relinkMoved(found)
        for facts in found {
            if let r = try? await store.upsertDocument(facts, origin: .inLibrary), r.changed {
                toProcess.append((r.id, facts.path))
                if r.isNew { fresh.insert(r.id) }
            }
        }
        do { _ = try await store.reconcileMissing(scan, within: directory.path) }
        catch { onProblem("Could not check \(directory.lastPathComponent) for removed files: \(error.localizedDescription)") }
        if !scan.isComplete {
            onProblem(Self.unreadableProblem(scan, in: store.root, readAsEmpty: false))
        }
    }

    /// Before any upsert, so a new file at an old path cannot claim the moved row.
    private func relinkMoved(_ found: [Store.FileFacts]) async {
        for facts in found where facts.fileID != nil {
            _ = try? await store.relinkByFileID(facts)
        }
    }

    /// `found`: new to the index, but already in the library.
    @discardableResult
    func process(documents: [(Int64, String)], phase: String, isImport: Bool,
                 route: Bool = false, found: Set<Int64> = []) async -> Int {
        guard !documents.isEmpty else { return 0 }
        let total = documents.count
        var done = 0
        onProgress(IndexProgress(phase: phase, done: 0, total: total))

        let width = settings.effectiveConcurrency
        var iterator = documents.makeIterator()

        await withTaskGroup(of: String?.self) { group in
            var inFlight = 0
            while inFlight < width, let next = iterator.next() {
                group.addTask { [weak self] in
                    await self?.pipeline(id: next.0, path: next.1, isImport: isImport, route: route,
                                         isNew: found.contains(next.0))
                }
                inFlight += 1
            }
            while let finished = await group.next() {
                done += 1
                onProgress(IndexProgress(phase: phase, done: done, total: total, current: finished))
                if done % 8 == 0 { onDataChanged() }
                if cancelled { group.cancelAll(); break }
                if let next = iterator.next() {
                    group.addTask { [weak self] in
                        await self?.pipeline(id: next.0, path: next.1, isImport: isImport, route: route,
                                         isNew: found.contains(next.0))
                    }
                }
            }
        }
        onProgress(IndexProgress())
        onDataChanged()
        return done
    }

    /// Nothing here writes to a file the user already had: only a fresh import is
    /// optimized, and only an import nobody gave a destination is moved.
    @discardableResult
    private func pipeline(id: Int64, path: String, isImport: Bool, route: Bool,
                          isNew: Bool) async -> String? {
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
            let examples = (try? await store.filingExamples(for: id)) ?? []
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
                             chosen: isImport && !route,
                             action: isImport ? .imported : .indexed)
        }

        await syncAliases(docID: id, target: url)

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

    private var languageCache: String??
    private var entityRuleCache: [Entity]?
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
            await syncAliases(docID: id, target: input.url)
        }
    }

    /// Renames and moves only when `moving`.
    private func route(id: Int64, url: inout URL, text: String,
                       findings: DocumentAnalyzer.Findings, insight: DocumentInsight?,
                       moving: Bool, chosen: Bool, action: EventAction) async {
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
        // are enforced automatically.
        let byTemplate = decision.rename == nil && settings.namingEnforcement == .automatic
        if let template = decision.rename ?? (byTemplate ? settings.namingTemplate.nilIfBlank : nil) {
            let rule = byTemplate ? nil : decision.rule
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

    /// Only tag aliases are Doctopus's to prune. Hand-made folder aliases are left
    /// alone, and nothing is deleted unless it is still our alias to this document.
    func syncAliases(docID: Int64, target: URL) async {
        let tags = (try? await store.tags(for: docID)) ?? []
        let mirroring = tags.filter { $0.mirrors || settings.mirrorTagsAsAliases }
        let existing = (try? await store.aliases(for: docID)) ?? []
        let root = store.root

        var wanted: [Int64: URL] = [:]
        for tag in mirroring { wanted[tag.tagID] = AliasManager.tagFolder(root: root, tag: tag) }

        for alias in existing {
            guard let tagID = alias.tagID else {
                if !FileManager.default.fileExists(atPath: alias.path) {
                    try? await store.deleteAlias(id: alias.id)
                }
                continue
            }
            let stillThere = FileManager.default.fileExists(atPath: alias.path)
            if wanted[tagID] == nil || !stillThere {
                if stillThere { AliasManager.removeAlias(at: alias.path, pointingTo: target) }
                try? await store.deleteAlias(id: alias.id)
            }
        }

        let present = Set(((try? await store.aliases(for: docID)) ?? []).compactMap(\.tagID))
        for (tagID, folder) in wanted where !present.contains(tagID) {
            if let created = try? AliasManager.createAlias(to: target, in: folder) {
                try? await store.recordAlias(docID: docID, tagID: tagID, path: created.path)
            }
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
            guard alias.tagID == nil else { return false }
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
                    try? await store.recordAlias(docID: docID, tagID: nil, path: again.path)
                }
                throw error
            }
        }
        return nil
    }

    @discardableResult
    func reprocess(ids: [Int64], asImport: Bool = false) async -> Int {
        var work: [(Int64, String)] = []
        for id in ids {
            if let path = try? await store.documentPath(id) { work.append((id, path)) }
        }
        return await process(documents: work, phase: "Reprocessing", isImport: asImport)
    }

    struct AnalyzeSummary: Sendable {
        var updated = 0
        var skipped = 0
        var failed = 0
        var blocked: String?
    }

    private enum AnalyzeOutcome: Sendable {
        case updated(String)
        case skipped
        case failed
    }

    func analyze(ids: [Int64]) async -> AnalyzeSummary {
        guard settings.llmBackend != .off else {
            return AnalyzeSummary(blocked: "No model is selected in Settings › Intelligence.")
        }
        guard !settings.predictedFields.isEmpty else {
            return AnalyzeSummary(blocked: "Every field is switched off under Suggestions in Settings › Intelligence.")
        }
        let status = await intelligence.status()
        guard status.isReady else { return AnalyzeSummary(blocked: status.label) }
        guard !ids.isEmpty else { return AnalyzeSummary() }

        cancelled = false
        var summary = AnalyzeSummary()
        let total = ids.count
        var done = 0
        onProgress(IndexProgress(phase: "Analyzing", done: 0, total: total))

        let width = max(1, min(await intelligence.width, total))
        var iterator = ids.makeIterator()

        await withTaskGroup(of: AnalyzeOutcome.self) { group in
            var inFlight = 0
            while inFlight < width, let next = iterator.next() {
                group.addTask { [weak self] in await self?.analyzeOne(id: next) ?? .failed }
                inFlight += 1
            }
            while let outcome = await group.next() {
                done += 1
                var current: String?
                switch outcome {
                case .updated(let name): summary.updated += 1; current = name
                case .skipped: summary.skipped += 1
                case .failed: summary.failed += 1
                }
                onProgress(IndexProgress(phase: "Analyzing", done: done, total: total, current: current))
                if done % 4 == 0 { onDataChanged() }
                if cancelled { group.cancelAll(); break }
                if let next = iterator.next() {
                    group.addTask { [weak self] in await self?.analyzeOne(id: next) ?? .failed }
                }
            }
        }
        onProgress(IndexProgress())
        onDataChanged()
        return summary
    }

    private func analyzeOne(id: Int64) async -> AnalyzeOutcome {
        guard let path = try? await store.documentPath(id) else { return .skipped }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let text = (try? await store.ocrText(id)) ?? ""
        guard text.count >= LLMPrompt.minimumCharacters || settings.sendsPageImage else { return .skipped }
        let pages = (try? await store.documentPageCount(id)) ?? nil
        let examples = (try? await store.filingExamples(for: id)) ?? []
        guard let insight = await intelligence.enrich(text: text, filename: name, url: url,
                                                      pageCount: pages, examples: examples)
        else { return .failed }

        try? await store.storeMetadata(Store.MetadataPatch(
            docID: id,
            title: insight.title,
            correspondent: insight.correspondent,
            docType: insight.docType,
            language: insight.language,
            summary: insight.summary,
            intent: insight.intent,
            docDate: nil,
            dateSource: nil,
            source: insight.source,
            amount: nil))

        for tag in insight.tags.prefix(4) {
            try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
        }
        try? await store.logProcessing(docID: id, action: .analyzed, detail: analysisLine(insight),
                                       rule: nil, from: nil, to: nil, approved: true)
        return .updated(name)
    }

    private func analysisLine(_ i: DocumentInsight) -> String {
        var parts = [MetadataSource(i.source).detailedLabel]
        if let type = i.docType { parts.append(type) }
        if let c = i.correspondent { parts.append(c) }
        if !i.tags.isEmpty { parts.append(i.tags.prefix(4).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    struct ImportSummary: Sendable {
        var imported = 0
        var routed = 0
        var alreadyInLibrary = 0
        var duplicates = 0
        var duplicateNames: [String] = []
        var failed = 0
        /// Why, one line per file that failed.
        var failures: [String] = []

        mutating func fail(_ name: String, _ reason: String) {
            failed += 1
            failures.append("“\(name)”: \(reason)")
        }
    }

    /// A file from outside the library is copied in and the original left alone —
    /// `movingSource` is only for files the app itself produced. A file already in
    /// the library is indexed in place, never optimized or moved.
    @discardableResult
    func importFiles(_ urls: [URL], into destination: URL,
                     movingSource: Bool = false, route: Bool = false) async -> ImportSummary {
        var summary = ImportSummary()
        var imported: [(Int64, String)] = []
        var inPlace: [(Int64, String)] = []
        var fresh: Set<Int64> = []
        let rootPath = store.root.path
        var madeDestination = false

        for url in FileScanner.importable(urls) {
            let path = Store.canonical(url.standardizedFileURL.path)
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                guard let facts = Self.facts(URL(fileURLWithPath: path)) else {
                    summary.fail(url.lastPathComponent, "it could not be read"); continue
                }
                let r: (id: Int64, isNew: Bool, changed: Bool)
                do { r = try await store.upsertDocument(facts, origin: .inLibrary) }
                catch { summary.fail(url.lastPathComponent, error.localizedDescription); continue }
                summary.alreadyInLibrary += 1
                if r.changed { inPlace.append((r.id, path)) }
                if r.isNew { fresh.insert(r.id) }
                continue
            }
            if let sourceHash = FileScanner.hash(url),
               (try? await store.findDuplicate(hash: sourceHash)) != nil {
                summary.duplicates += 1
                summary.duplicateNames.append(url.lastPathComponent)
                // `movingSource` files are the app's own scratch copies, so this is the only
                // chance to clean one up. A plain import's source is never touched.
                if movingSource { try? FileManager.default.removeItem(at: url) }
                continue
            }
            do {
                if !madeDestination {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    madeDestination = true
                }
                let target = Naming.uniqueURL(in: destination, filename: url.lastPathComponent)
                if movingSource {
                    try FileManager.default.moveItem(at: url, to: target)
                } else {
                    try FileManager.default.copyItem(at: url, to: target)
                }
                let origin: DocumentOrigin = movingSource ? .scanned : .imported(from: path)
                guard let facts = Self.facts(target) else {
                    summary.fail(url.lastPathComponent, "its copy could not be read"); continue
                }
                let r = try await store.upsertDocument(facts, origin: origin)
                imported.append((r.id, target.path))
                summary.imported += 1
            } catch {
                summary.fail(url.lastPathComponent, error.localizedDescription)
            }
        }
        await process(documents: inPlace, phase: "Indexing", isImport: false, found: fresh)
        await process(documents: imported, phase: "Importing", isImport: true, route: route)
        if route {
            for (id, path) in imported {
                if let now = try? await store.documentPath(id), now != path { summary.routed += 1 }
            }
        }
        return summary
    }

    private static let factKeys: [URLResourceKey] =
        [.fileSizeKey, .contentModificationDateKey, .creationDateKey] + FileScanner.identityKeys

    static func unreadableProblem(_ scan: FileScanner.Scan, in root: URL, readAsEmpty: Bool) -> String {
        let name = root.lastPathComponent
        if readAsEmpty {
            return "\(name) looked empty, although documents are indexed in it. "
                + "Nothing was marked missing; if the folder is on a drive or a share, check that it is connected."
        }
        let places = scan.unreadable.map { url in
            url.path == root.path ? name : String(url.path.dropFirst(root.path.count + 1))
        }
        let shown = places.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            + (places.count > 3 ? " and \(places.count - 3) more" : "")
        return "Doctopus could not read \(shown) in \(name). "
            + "Documents there were left as they were, and nothing will be forgotten until it can read them again."
    }

    private static func facts(_ url: URL) -> Store.FileFacts? {
        guard let v = try? url.resourceValues(forKeys: Set(factKeys)) else { return nil }
        return facts(path: url.path, v)
    }

    private static func facts(path: String, _ v: URLResourceValues) -> Store.FileFacts {
        Store.FileFacts(path: path, size: Int64(v.fileSize ?? 0),
                        mtime: v.contentModificationDate ?? Date(),
                        created: v.creationDate ?? Date(),
                        fileID: FileScanner.fileID(v))
    }

    private static func facts(_ f: FileScanner.Found) -> Store.FileFacts {
        Store.FileFacts(path: f.url.path, size: f.size, mtime: f.mtime,
                        created: f.created, fileID: f.fileID)
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
    private func optimizeFile(id: Int64, url: URL) async throws -> Optimizer.Result? {
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
    /// it left, its event and its tag aliases.
    @discardableResult
    private func relocate(_ id: Int64, from url: URL, into folder: URL, named name: String,
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
        await syncAliases(docID: id, target: target)
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
                try? await store.recordAlias(docID: event.docID, tagID: nil, path: alias.path)
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
                try? await store.recordAlias(docID: event.docID, tagID: nil, path: alias.path)
            }
        }
        // An event that stays on record would be handed straight back by
        // `lastUndoableEvent`, and `undo` would loop on it forever.
        do { try await store.deleteEvent(event.id) } catch { return false }
        return true
    }

    struct RuleApplyResult: Sendable {
        var matched = 0
        var moved = 0
        var renamed = 0
        var tagged = 0
        var metadataUpdated = 0
        var failures: [String] = []
    }

    /// A rule, saved or still a draft, applied on request to the documents
    /// already in the library — all but its outliers, or the one named.
    func applyRule(_ rule: Rule, onlyTo docID: Int64? = nil) async -> RuleApplyResult {
        var result = RuleApplyResult()
        let router = Router(rules: [rule], derivedTemplate: "", root: store.root,
                            deriveWhenNoRule: false)
        for doc in (try? await store.ruleTargets(for: rule, onlyTo: docID)) ?? [] where rule.matches(doc.subject) {
            result.matched += 1
            if !rule.tagNames.isEmpty {
                for tag in rule.tagNames {
                    if let tagID = try? await store.tagID(named: tag) {
                        try? await store.assign(tag: tagID, to: doc.id, auto: true)
                    }
                }
                result.tagged += 1
            }
            var url = URL(fileURLWithPath: doc.path)
            var patch = Store.MetadataPatch(docID: doc.id)
            patch.correspondent = rule.setCorrespondent
            patch.docType = rule.setDocType
            if patch.correspondent != nil || patch.docType != nil {
                do {
                    try await store.storeMetadata(patch)
                    result.metadataUpdated += 1
                } catch { result.failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
            }

            let correspondent = rule.setCorrespondent ?? doc.subject.correspondent
            let docType = rule.setDocType ?? doc.subject.docType
            let date = doc.docDate ?? doc.created
            if let template = rule.destination {
                let folder = router.expand(template, correspondent: correspondent, docType: docType, date: date)
                if router.isInsideLibrary(folder),
                   url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                    do {
                        url = try await relocate(doc.id, from: url, into: folder, named: url.lastPathComponent,
                                                 action: .routed, detail: "Applied rule “\(rule.name)”",
                                                 rule: rule.name)
                        result.moved += 1
                    } catch { result.failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
                }
            }
            if let template = rule.rename {
                let name = Naming.render(template, Naming.Context(
                    date: date, correspondent: correspondent, title: doc.title, docType: docType,
                    language: doc.language, counter: nil,
                    originalStem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension,
                    options: settings.namingOptions))
                if name != url.lastPathComponent {
                    do {
                        try await relocate(doc.id, from: url, into: url.deletingLastPathComponent(), named: name,
                                           action: .renamed, detail: name, rule: rule.name)
                        result.renamed += 1
                    } catch { result.failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
                }
            }
        }
        onDataChanged()
        return result
    }
}
