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

    init(store: Store, intelligence: Intelligence, settings: AppSettings,
         onProgress: @escaping @Sendable (IndexProgress) -> Void,
         onDataChanged: @escaping @Sendable () -> Void) {
        self.store = store
        self.intelligence = intelligence
        self.settings = settings
        self.onProgress = onProgress
        self.onDataChanged = onDataChanged
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

        let found = FileScanner.scan(root: store.root)
        if cancelled { return nil }
        let facts = found.map { Store.FileFacts(path: $0.url.path, size: $0.size, mtime: $0.mtime, created: $0.created) }
        guard let upserted = try? await store.upsertDocuments(facts) else { return nil }
        var toProcess = upserted.filter(\.changed).map { ($0.id, $0.path) }
        _ = try? await store.reconcileMissing(seenPaths: Set(facts.map(\.path)))

        _ = try? await store.purgeMissing()
        _ = try? await store.purgeDeleted()

        if let pending = try? await store.documentIDsNeedingOCR() {
            let known = Set(toProcess.map(\.0))
            toProcess.append(contentsOf: pending.filter { !known.contains($0.id) }.map { ($0.id, $0.path) })
        }

        onDataChanged()
        return await process(documents: toProcess, phase: "Indexing", isImport: false)
    }

    func handleChanges(paths: [String]) async {
        let rootPrefix = store.root.path + "/"
        let fm = FileManager.default

        var toProcess: [(Int64, String)] = []
        var touched = false

        for path in paths {
            guard path == store.root.path || path.hasPrefix(rootPrefix) else { continue }
            if FileScanner.isInsideLibraryContainer(URL(fileURLWithPath: path)) { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

            if isDir.boolValue {
                await rescan(directory: URL(fileURLWithPath: path), into: &toProcess)
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

            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isAliasFileKey]),
                  v.isAliasFile != true else { continue }

            if let hash = FileScanner.hash(url),
               (try? await store.relinkByHash(hash: hash, newPath: path)) != nil {
                touched = true
                continue
            }

            let facts = Store.FileFacts(path: path, size: Int64(v.fileSize ?? 0),
                                        mtime: v.contentModificationDate ?? Date(),
                                        created: v.creationDate ?? Date())
            if let result = try? await store.upsertDocument(facts), result.changed {
                toProcess.append((result.id, path))
            }
            touched = true
        }

        if touched { onDataChanged() }
        if !toProcess.isEmpty {
            await process(documents: toProcess, phase: "Indexing", isImport: false)
        }
    }

    private func rescan(directory: URL, into toProcess: inout [(Int64, String)]) async {
        for f in FileScanner.scan(root: directory) {
            let facts = Store.FileFacts(path: f.url.path, size: f.size,
                                        mtime: f.mtime, created: f.created)
            if let r = try? await store.upsertDocument(facts), r.changed {
                toProcess.append((r.id, f.url.path))
            }
        }
    }

    @discardableResult
    func process(documents: [(Int64, String)], phase: String, isImport: Bool,
                 route: Bool = false) async -> Int {
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
                    await self?.pipeline(id: next.0, path: next.1, isImport: isImport, route: route)
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
                        await self?.pipeline(id: next.0, path: next.1, isImport: isImport, route: route)
                    }
                }
            }
        }
        onProgress(IndexProgress())
        onDataChanged()
        return done
    }

    /// Nothing here writes to a file the user already had: only a fresh import is
    /// optimized, and only an import nobody gave a destination is routed.
    @discardableResult
    private func pipeline(id: Int64, path: String, isImport: Bool, route: Bool) async -> String? {
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

        // 1. Optimize before OCR so the indexed text matches the stored bytes.
        // Imports only: an existing file is rewritten only when someone picks
        // Optimize for it.
        var optimized: Optimizer.Result?
        if isImport && settings.optimizeOnImport {
            optimized = await optimizeFile(id: id, url: url)
        }

        let extracted = (try? TextExtractor.extract(url: url)) ?? ExtractedText(source: "failed")
        if extracted.source == "failed" || extracted.source == "unreadable" {
            try? await store.markOCR(id, state: .failed)
        } else {
            try? await store.storeOCR(docID: id, text: extracted.text, confidence: extracted.confidence,
                                      words: extracted.words, source: extracted.source,
                                      elapsedMS: extracted.elapsedMS, pageCount: extracted.pageCount)
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
            insight = await intelligence.enrich(text: extracted.text, filename: name, url: url,
                                                pageCount: extracted.pageCount, candidateTags: topTags)
        }

        try? await store.storeMetadata(Store.MetadataPatch(
            docID: id,
            title: insight?.title ?? findings.title,
            correspondent: insight?.correspondent ?? findings.correspondent,
            docType: insight?.docType ?? findings.docType,
            language: insight?.language ?? extracted.language,
            summary: insight?.summary,
            intent: insight?.intent,
            docDate: findings.date,
            dateSource: findings.dateSource,
            confidence: max(findings.confidence, insight?.confidence ?? 0),
            source: insight?.source ?? "heuristic",
            amount: findings.amount))

        for tag in (insight?.tags ?? []).prefix(4) {
            try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
        }

        // 6. Routing — undirected imports only; existing files are never moved
        // uninvited, and neither is anything imported into a chosen folder.
        if isImport, route, settings.autoRouteImports {
            await self.route(id: id, url: &url, text: extracted.text, findings: findings, insight: insight)
        }

        await syncAliases(docID: id, target: url)

        if !isImport, optimized == nil {
            try? await store.logProcessing(docID: id, action: .indexed,
                                           detail: summaryLine(extracted, findings, insight),
                                           confidence: findings.confidence, rule: nil,
                                           from: nil, to: nil, approved: true)
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

    private func route(id: Int64, url: inout URL, text: String,
                       findings: DocumentAnalyzer.Findings, insight: DocumentInsight?) async {
        let router = Router(rules: (try? await store.rules()) ?? [],
                            threshold: settings.routingThreshold,
                            derivedTemplate: settings.derivedTemplate,
                            root: store.root,
                            deriveWhenNoRule: settings.deriveWhenNoRule)

        let decision = router.evaluate(text: text, filename: url.lastPathComponent,
                                       findings: findings, insight: insight,
                                       currentDirectory: url.deletingLastPathComponent())
        try? await store.setPathSuggestions(decision.candidates.map {
            PathSuggestion(path: $0.destination.path, confidence: $0.confidence, source: $0.rule,
                           explanation: $0.explanation)
        }, for: id)

        if let corr = decision.setCorrespondent {
            try? await store.storeMetadata(Store.MetadataPatch(docID: id, correspondent: corr, source: "rule"))
        }
        if let docType = decision.setDocType {
            try? await store.storeMetadata(Store.MetadataPatch(docID: id, docType: docType, source: "rule"))
        }

        for tag in decision.tags {
            if decision.tagsFromRule {
                if let tagID = try? await store.tagID(named: tag) {
                    try? await store.assign(tag: tagID, to: id, auto: true)
                }
            } else {
                try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
            }
        }

        if let template = decision.rename {
            let name = Naming.render(template, Naming.Context(
                date: findings.date,
                correspondent: decision.setCorrespondent ?? insight?.correspondent ?? findings.correspondent,
                title: insight?.title ?? findings.title,
                docType: decision.setDocType ?? insight?.docType ?? findings.docType,
                language: insight?.language, counter: nil,
                originalStem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension))
            if name != url.lastPathComponent,
               let target = try? await relocate(id, from: url, into: url.deletingLastPathComponent(), named: name,
                                                action: .renamed, detail: name, rule: decision.rule) {
                url = target
            }
        }

        guard let destination = decision.destination else {
            try? await store.logProcessing(docID: id, action: .imported, detail: decision.explanation,
                                           confidence: decision.confidence, rule: decision.rule,
                                           from: nil, to: url.path, approved: false)
            return
        }

        let from = url.path
        do {
            // A rule's move is certain, but what was read off the document
            // still deserves a look, so it waits in Needs Review.
            url = try await relocate(id, from: url, into: destination, named: url.lastPathComponent,
                                     action: .routed, detail: decision.explanation, rule: decision.rule,
                                     confidence: decision.confidence,
                                     approved: decision.rule == "derived" && decision.confidence >= 0.9)
        } catch {
            try? await store.logProcessing(docID: id, action: .imported,
                                           detail: "Could not move: \(error.localizedDescription)",
                                           confidence: decision.confidence, rule: decision.rule,
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

    func promoteClosestAlias(docID: Int64) async -> URL? {
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
            try? await store.deleteAlias(id: alias.id)
            return try? await relocate(docID, from: url, into: folder, named: url.lastPathComponent,
                                       action: .promoted,
                                       detail: "Deleted from \(home.lastPathComponent); kept where it was also filed")
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
        guard let insight = await intelligence.enrich(text: text, filename: name, url: url,
                                                      pageCount: pages) else { return .failed }

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
            confidence: insight.confidence,
            source: insight.source,
            amount: nil))

        for tag in insight.tags.prefix(4) {
            try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
        }
        try? await store.logProcessing(docID: id, action: .analyzed, detail: analysisLine(insight),
                                       confidence: insight.confidence, rule: nil,
                                       from: nil, to: nil, approved: true)
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
    }

    /// A file from outside the library is copied in and the original left alone —
    /// `movingSource` is only for files the app itself produced. A file already in
    /// the library is indexed in place, never optimized or routed.
    @discardableResult
    func importFiles(_ urls: [URL], into destination: URL,
                     movingSource: Bool = false, route: Bool = false) async -> ImportSummary {
        var summary = ImportSummary()
        var imported: [(Int64, String)] = []
        var inPlace: [(Int64, String)] = []
        let rootPath = store.root.path
        var madeDestination = false

        for url in FileScanner.importable(urls) {
            let path = Store.canonical(url.standardizedFileURL.path)
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                guard let facts = Self.facts(URL(fileURLWithPath: path)),
                      let r = try? await store.upsertDocument(facts) else { summary.failed += 1; continue }
                summary.alreadyInLibrary += 1
                if r.changed { inPlace.append((r.id, path)) }
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
                guard let facts = Self.facts(target),
                      let r = try? await store.upsertDocument(facts) else { summary.failed += 1; continue }
                imported.append((r.id, target.path))
                summary.imported += 1
            } catch {
                summary.failed += 1
            }
        }
        await process(documents: inPlace, phase: "Indexing", isImport: false)
        await process(documents: imported, phase: "Importing", isImport: true, route: route)
        if route {
            for (id, path) in imported {
                if let now = try? await store.documentPath(id), now != path { summary.routed += 1 }
            }
        }
        return summary
    }

    private static func facts(_ url: URL) -> Store.FileFacts? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        else { return nil }
        return Store.FileFacts(path: url.path, size: Int64(v.fileSize ?? 0),
                               mtime: v.contentModificationDate ?? Date(),
                               created: v.creationDate ?? Date())
    }

    func rename(ids: [Int64], template: String) async -> Int {
        var renamed = 0
        for id in ids {
            guard let detail = try? await store.detail(id) else { continue }
            let url = detail.row.url
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let ctx = Naming.Context(date: detail.row.docDate ?? detail.row.createdAt,
                                     correspondent: detail.row.correspondent,
                                     title: detail.row.title,
                                     docType: detail.row.docType,
                                     language: detail.row.language,
                                     counter: renamed + 1,
                                     originalStem: url.deletingPathExtension().lastPathComponent,
                                     ext: url.pathExtension)
            let newName = Naming.render(template, ctx)
            guard newName != url.lastPathComponent else { continue }
            if (try? await relocate(id, from: url, into: url.deletingLastPathComponent(), named: newName,
                                    action: .renamed, detail: newName, rule: template)) != nil {
                renamed += 1
            }
        }
        onDataChanged()
        return renamed
    }

    func move(ids: [Int64], to destination: URL) async -> Int {
        var moved = 0
        for id in ids {
            guard let path = try? await store.documentPath(id) else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().path != destination.path else { continue }
            if (try? await relocate(id, from: url, into: destination, named: url.lastPathComponent,
                                    action: .moved, detail: destination.lastPathComponent)) != nil {
                moved += 1
            }
        }
        onDataChanged()
        return moved
    }

    func optimize(ids: [Int64]) async -> (count: Int, saved: Int64) {
        var count = 0
        var saved: Int64 = 0
        for id in ids {
            guard let path = try? await store.documentPath(id),
                  let result = await optimizeFile(id: id, url: URL(fileURLWithPath: path)) else { continue }
            count += 1
            saved += result.originalSize - result.newSize
        }
        onDataChanged()
        return (count, saved)
    }

    private func optimizeFile(id: Int64, url: URL) async -> Optimizer.Result? {
        var savedOriginal: String?
        if let preHash = FileScanner.hash(url),
           (try? await store.saveOriginalFile(for: id, from: url, hash: preHash)) == true {
            savedOriginal = preHash
        }
        guard let result = try? Optimizer.optimize(url: url, options: settings.optimizerOptions) else {
            if let savedOriginal { await store.discardOriginalFile(hash: savedOriginal, ext: url.pathExtension) }
            return nil
        }
        try? await store.setSizes(id, size: result.newSize, originalSize: result.originalSize)
        try? await store.logProcessing(
            docID: id, action: .optimized,
            detail: String(format: "%.0f%% smaller (%d page%@ rasterized)",
                           result.savings * 100, result.pagesRasterized,
                           result.pagesRasterized == 1 ? "" : "s"),
            confidence: nil, rule: nil, from: nil, to: nil, approved: true)
        if let hash = FileScanner.hash(url) { try? await store.setHash(id, hash) }
        return result
    }

    func revertOptimization(ids: [Int64]) async -> Int {
        let fm = FileManager.default
        var count = 0
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
                continue
            }
            try? await store.logProcessing(docID: id, action: .revertedOptimization,
                                           detail: "Reverted to original pre-optimization file",
                                           confidence: nil, rule: nil, from: nil, to: saved.current.path,
                                           approved: true)
            count += 1
        }
        if count > 0 { onDataChanged() }
        return count
    }

    /// Every move of a document's file ends here: the file, its row, the folder
    /// it left, its event and its tag aliases.
    @discardableResult
    private func relocate(_ id: Int64, from url: URL, into folder: URL, named name: String,
                          action: EventAction?, detail: String?, rule: String? = nil,
                          confidence: Double? = nil, approved: Bool = true) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = Naming.uniqueURL(in: folder, filename: name)
        try FileManager.default.moveItem(at: url, to: target)
        try? await store.updatePath(id, to: target.path)
        FileScanner.pruneEmptyDirectories(startingFrom: url.deletingLastPathComponent(), upTo: store.root)
        if let action {
            try? await store.logProcessing(docID: id, action: action, detail: detail, confidence: confidence,
                                           rule: rule, from: url.path, to: target.path, approved: approved)
        }
        await syncAliases(docID: id, target: target)
        return target
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
        try? await store.deleteEvent(event.id)
        return true
    }

    struct RuleApplyResult: Sendable {
        var matched = 0
        var moved = 0
        var renamed = 0
        var tagged = 0
        var metadataUpdated = 0
    }

    /// A rule, saved or still a draft, applied to every document already in
    /// the library. Only ever done on request.
    func applyRule(_ rule: Rule) async -> RuleApplyResult {
        var result = RuleApplyResult()
        let router = Router(rules: [rule], threshold: 0, derivedTemplate: "", root: store.root,
                            deriveWhenNoRule: false)
        for doc in (try? await store.ruleTargets()) ?? [] where rule.matches(doc.subject) {
            result.matched += 1
            if !rule.tagNames.isEmpty {
                for tag in rule.tagNames {
                    if let tagID = try? await store.tagID(named: tag) {
                        try? await store.assign(tag: tagID, to: doc.id, auto: true)
                    }
                }
                result.tagged += 1
            }
            var patch = Store.MetadataPatch(docID: doc.id)
            patch.correspondent = rule.setCorrespondent
            patch.docType = rule.setDocType
            if patch.correspondent != nil || patch.docType != nil,
               (try? await store.storeMetadata(patch)) != nil {
                result.metadataUpdated += 1
            }

            var url = URL(fileURLWithPath: doc.path)
            let correspondent = rule.setCorrespondent ?? doc.subject.correspondent
            let docType = rule.setDocType ?? doc.subject.docType
            let date = doc.docDate ?? doc.created
            if let template = rule.destination {
                let folder = router.expand(template, correspondent: correspondent, docType: docType, date: date)
                if router.isInsideLibrary(folder),
                   url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL,
                   let target = try? await relocate(doc.id, from: url, into: folder, named: url.lastPathComponent,
                                                    action: .routed, detail: "Applied rule “\(rule.name)”",
                                                    rule: rule.name, confidence: 1) {
                    url = target
                    result.moved += 1
                }
            }
            if let template = rule.rename {
                let name = Naming.render(template, Naming.Context(
                    date: date, correspondent: correspondent, title: doc.title, docType: docType,
                    language: doc.language, counter: nil,
                    originalStem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension))
                if name != url.lastPathComponent,
                   (try? await relocate(doc.id, from: url, into: url.deletingLastPathComponent(), named: name,
                                        action: .renamed, detail: name, rule: rule.name)) != nil {
                    result.renamed += 1
                }
            }
        }
        onDataChanged()
        return result
    }
}
