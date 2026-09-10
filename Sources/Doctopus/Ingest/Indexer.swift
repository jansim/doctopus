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
///
/// Work is bounded by `settings.effectiveConcurrency`: OCR is CPU/ANE bound and
/// oversubscribing it makes the whole machine feel slow while making the batch
/// no faster.
actor Indexer {
    private let store: Store
    private let intelligence: Intelligence
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
        await intelligence.update(settings: settings)
    }
    func cancel() { cancelled = true }
    var isRunning: Bool { running }

    // MARK: - Scanning

    /// Full in-place pass over every root. Adds new files, notices changed ones,
    /// marks vanished ones missing, and relinks moves by content hash.
    ///
    /// Returns how many documents were (re)processed, or nil when a pass was
    /// already running and this call did nothing.
    @discardableResult
    func indexAll() async -> Int? {
        guard !running else { return nil }
        running = true
        cancelled = false
        defer { running = false; onProgress(IndexProgress()); onDataChanged() }

        onProgress(IndexProgress(phase: "Scanning", done: 0, total: 1))

        var toProcess: [(Int64, String)] = []
        let found = FileScanner.scan(root: store.root)
        var seen = Set<String>()
        seen.reserveCapacity(found.count)

        for f in found {
            if cancelled { return nil }
            seen.insert(f.url.path)
            let facts = Store.FileFacts(path: f.url.path,
                                        size: f.size, mtime: f.mtime, created: f.created)
            guard let result = try? await store.upsertDocument(facts) else { continue }
            if result.changed { toProcess.append((result.id, f.url.path)) }
        }
        _ = try? await store.reconcileMissing(seenPaths: seen)

        // Documents gone for over a week are not coming back as a move.
        _ = try? await store.purgeMissing(olderThan: 7 * 24 * 3600)

        // Anything still pending from a previous interrupted run.
        if let pending = try? await store.documentIDsNeedingOCR() {
            let known = Set(toProcess.map(\.0))
            toProcess.append(contentsOf: pending.filter { !known.contains($0.id) }.map { ($0.id, $0.path) })
        }

        onDataChanged()
        return await process(documents: toProcess, phase: "Indexing", isImport: false)
    }

    /// Targeted refresh for FSEvents batches — far cheaper than a full rescan.
    func handleChanges(paths: [String]) async {
        let rootPrefix = store.root.path + "/"
        let fm = FileManager.default

        var toProcess: [(Int64, String)] = []
        var touched = false

        for path in paths {
            guard path == store.root.path || path.hasPrefix(rootPrefix) else { continue }
            // Doctopus's own storage, not content.
            if FileScanner.isInsideLibraryContainer(URL(fileURLWithPath: path)) { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

            if isDir.boolValue {
                // A directory event means a subtree changed; rescan just that subtree.
                await rescan(directory: URL(fileURLWithPath: path), into: &toProcess)
                touched = true
                continue
            }

            let url = URL(fileURLWithPath: path)
            guard FileScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }

            if !exists {
                // Might be a move: mark it gone now and let the arrival of the
                // destination path relink it by hash.
                try? await store.markMissing(path: path)
                touched = true
                continue
            }

            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isAliasFileKey]),
                  v.isAliasFile != true else { continue }

            // A file appearing at a new path with a known hash is a Finder move.
            if let hash = FileScanner.hash(url),
               let movedID = try? await store.relinkByHash(hash: hash, newPath: path) {
                _ = movedID
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

    // MARK: - Processing

    /// Runs the per-document pipeline with bounded parallelism. Returns how
    /// many documents it got through before finishing or being cancelled.
    ///
    /// `isImport` marks files Doctopus itself just brought into the library —
    /// the only ones it may rewrite (optimize) unasked. `route` additionally
    /// lets it move them, and is only true when nobody said where they go.
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

    /// The whole per-document pipeline. Every stage degrades independently: a
    /// failed OCR still yields filesystem metadata, a missing LLM still yields
    /// heuristics, a failed optimization leaves the original untouched.
    ///
    /// Nothing here writes to a file the user already had. Only a fresh import
    /// — a copy Doctopus made, or a scan it received — is optimized, and only
    /// an import nobody gave a destination is routed.
    @discardableResult
    private func pipeline(id: Int64, path: String, isImport: Bool, route: Bool) async -> String? {
        var url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? await store.markOCR(id, state: .skipped)
            return name
        }

        if let hash = FileScanner.hash(url) { try? await store.setHash(id, hash) }

        // The Finder's tags are read straight off the file every pass, so the
        // index follows whatever was done in the Finder without owning it.
        try? await store.indexFinderTags(docID: id, entries: FinderTags.entries(url))

        // 1. Optimize before OCR so the indexed text matches the stored bytes.
        // Imports only: an existing file is rewritten only when someone picks
        // Optimize for it.
        var optimized: Optimizer.Result?
        if isImport && settings.optimizeOnImport {
            optimized = try? Optimizer.optimize(url: url, options: settings.optimizerOptions)
            if let optimized {
                try? await store.setSizes(id, size: optimized.newSize, originalSize: optimized.originalSize)
                try? await store.logProcessing(
                    docID: id, action: "optimized",
                    detail: String(format: "%.0f%% smaller (%d page%@ rasterized)",
                                   optimized.savings * 100, optimized.pagesRasterized,
                                   optimized.pagesRasterized == 1 ? "" : "s"),
                    confidence: nil, rule: nil, from: nil, to: nil, approved: true)
                if let hash = FileScanner.hash(url) { try? await store.setHash(id, hash) }
            }
        }

        // 2. Text.
        let extracted = (try? TextExtractor.extract(url: url)) ?? ExtractedText(source: "failed")
        if extracted.source == "failed" || extracted.source == "unreadable" {
            try? await store.markOCR(id, state: .failed)
        } else {
            try? await store.storeOCR(docID: id, text: extracted.text, confidence: extracted.confidence,
                                      words: extracted.words, source: extracted.source,
                                      elapsedMS: extracted.elapsedMS, pageCount: extracted.pageCount)
        }

        // 3. Deterministic findings.
        let known = (try? await store.facets(column: "correspondent"))?.map(\.value) ?? []
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let findings = DocumentAnalyzer.analyze(url: url, text: extracted.text,
                                                fallbackDate: created, knownCorrespondents: known)

        // 4. Optional model enrichment, on-device or over the network.
        var insight: DocumentInsight?
        if settings.llmBackend != .off, !extracted.text.isEmpty {
            insight = await intelligence.enrich(text: extracted.text, filename: name)
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

        // 5. Tags proposed by the model — staged as suggestions, not assigned
        // outright, unless they match a tag already in use and the setting
        // says to accept those automatically.
        for tag in (insight?.tags ?? []).prefix(4) {
            try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
        }

        // 6. Routing — undirected imports only; existing files are never moved
        // uninvited, and neither is anything imported into a chosen folder.
        if isImport, route, settings.autoRouteImports {
            await self.route(id: id, url: &url, text: extracted.text, findings: findings, insight: insight)
        }

        // 7. Mirror tag membership to disk if the user asked for that.
        await syncAliases(docID: id, target: url)

        if !isImport, optimized == nil {
            try? await store.logProcessing(docID: id, action: "indexed",
                                           detail: summaryLine(extracted, findings, insight),
                                           confidence: findings.confidence, rule: nil,
                                           from: nil, to: nil, approved: true)
        }
        return name
    }

    private func summaryLine(_ t: ExtractedText, _ f: DocumentAnalyzer.Findings, _ i: DocumentInsight?) -> String {
        var parts: [String] = []
        parts.append("\(t.words) words via \(t.source)")
        if let type = i?.docType ?? f.docType { parts.append(type) }
        if let c = i?.correspondent ?? f.correspondent { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Routing & aliases

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
        // Every candidate is kept, moved or not, so the review can offer the
        // alternatives — and so an ambiguous document has its choices waiting.
        try? await store.setPathSuggestions(decision.candidates, for: id)

        for tag in decision.tags {
            if decision.tagsFromRule {
                if let tagID = try? await store.tagID(named: tag) {
                    try? await store.assign(tag: tagID, to: id, auto: true)
                }
            } else {
                try? await store.suggestTag(tag, for: id, autoAcceptMatching: settings.autoAcceptMatchingTagSuggestions)
            }
        }

        guard let destination = decision.destination else {
            try? await store.logProcessing(docID: id, action: "imported", detail: decision.explanation,
                                           confidence: decision.confidence, rule: decision.rule,
                                           from: nil, to: url.path, approved: false)
            return
        }

        let from = url.path
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let target = Naming.uniqueURL(in: destination, filename: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            try? await store.updatePath(id, to: target.path)
            url = target
            try? await store.logProcessing(docID: id, action: "routed", detail: decision.explanation,
                                           confidence: decision.confidence, rule: decision.rule,
                                           from: from, to: target.path,
                                           approved: decision.confidence >= 0.9)
        } catch {
            try? await store.logProcessing(docID: id, action: "imported",
                                           detail: "Could not move: \(error.localizedDescription)",
                                           confidence: decision.confidence, rule: decision.rule,
                                           from: from, to: from, approved: false)
        }
    }

    /// Brings the on-disk aliases in line with the document's mirroring tags.
    ///
    /// Only tag aliases are Doctopus's to prune. An alias someone made by
    /// dragging a document onto a folder has no tag and is left alone here —
    /// it goes when they remove it — and nothing is deleted unless it is still
    /// an alias to this document (see `AliasManager.removeAlias`).
    func syncAliases(docID: Int64, target: URL) async {
        let tags = (try? await store.tags(for: docID)) ?? []
        let mirroring = tags.filter { $0.mirrors || settings.mirrorTagsAsAliases }
        let existing = (try? await store.aliases(for: docID)) ?? []
        let root = store.root

        var wanted: [Int64: URL] = [:]
        for tag in mirroring { wanted[tag.tagID] = AliasManager.tagFolder(root: root, tag: tag) }

        // Prune aliases for tags that are gone, or whose file vanished.
        for alias in existing {
            guard let tagID = alias.tagID else {
                // A folder placement the user made. Only forget it once the
                // alias itself has gone from disk.
                if !FileManager.default.fileExists(atPath: alias.path) {
                    try? await store.deleteAlias(id: alias.id)
                }
                continue
            }
            let stillThere = FileManager.default.fileExists(atPath: alias.path)
            if wanted[tagID] == nil || !stillThere {
                // Something that is no longer our alias stays on disk, but the
                // registry lets go of it either way.
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

    // MARK: - On-demand operations

    /// Re-runs the pipeline for specific documents (context menu "Reprocess").
    @discardableResult
    func reprocess(ids: [Int64], asImport: Bool = false) async -> Int {
        var work: [(Int64, String)] = []
        for id in ids {
            if let path = try? await store.documentPath(id) { work.append((id, path)) }
        }
        return await process(documents: work, phase: "Reprocessing", isImport: asImport)
    }

    // MARK: - Model enrichment

    /// What a manual enrichment pass did, for the message the UI shows after it.
    struct AnalyzeSummary: Sendable {
        var updated = 0
        var skipped = 0
        var failed = 0
        /// Set when the pass never started, carrying the reason verbatim.
        var blocked: String?
    }

    private enum AnalyzeOutcome: Sendable {
        case updated(String)
        case skipped
        case failed
    }

    /// Re-runs the model pass alone, over text that is already in the index.
    ///
    /// This is the manual trigger. Nothing on disk is read or written, no OCR
    /// runs and no file moves — a document with no indexed text is reported as
    /// skipped rather than quietly re-read, because Reprocess is the action for
    /// that. It is the one way to enrich a library that was indexed before a
    /// model was configured, or to ask a better model the same question again.
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
        let name = URL(fileURLWithPath: path).lastPathComponent
        let text = (try? await store.ocrText(id)) ?? ""
        guard text.count >= LLMPrompt.minimumCharacters else { return .skipped }
        guard let insight = await intelligence.enrich(text: text, filename: name) else { return .failed }

        // Dates, their provenance and amounts belong to the deterministic
        // analyzer, which has the file itself to work from; passing nil here
        // leaves whatever it found in place.
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
        try? await store.logProcessing(docID: id, action: "analyzed", detail: analysisLine(insight),
                                       confidence: insight.confidence, rule: nil,
                                       from: nil, to: nil, approved: true)
        return .updated(name)
    }

    private func analysisLine(_ i: DocumentInsight) -> String {
        var parts = [i.source == "remote" ? "API model" : "On-device model"]
        if let type = i.docType { parts.append(type) }
        if let c = i.correspondent { parts.append(c) }
        if !i.tags.isEmpty { parts.append(i.tags.prefix(4).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// What an import did, for the message the UI shows after it.
    struct ImportSummary: Sendable {
        /// Files brought into the library — copied in, or a scan received.
        var imported = 0
        /// Of `imported`, how many the router moved on to a folder.
        var routed = 0
        /// Files that were already inside the library and were only indexed.
        var alreadyInLibrary = 0
        var failed = 0
    }

    /// Imports files that arrived from a scan or a drop into `destination`.
    ///
    /// Only a file new to the library is an import. One from anywhere else is
    /// copied in and the original left exactly where it was — `movingSource` is
    /// only ever true for files the app itself produced, such as a scan staged
    /// in the temporary directory. A file that is already inside the library is
    /// indexed where it lies, exactly as a rescan would: it is the user's, so it
    /// is neither optimized nor routed, whatever the import was asked to do.
    ///
    /// `route` is true only when nobody chose where the files go. With an
    /// explicit destination — scan into this folder, import here — they stay
    /// where they were put.
    @discardableResult
    func importFiles(_ urls: [URL], into destination: URL,
                     movingSource: Bool = false, route: Bool = false) async -> ImportSummary {
        var summary = ImportSummary()
        var imported: [(Int64, String)] = []
        var inPlace: [(Int64, String)] = []
        let rootPath = store.root.path
        var madeDestination = false

        for url in urls {
            let path = Store.canonical(url.standardizedFileURL.path)
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                guard let facts = Self.facts(URL(fileURLWithPath: path)),
                      let r = try? await store.upsertDocument(facts) else { summary.failed += 1; continue }
                summary.alreadyInLibrary += 1
                if r.changed { inPlace.append((r.id, path)) }
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

    /// Applies a naming template to documents on demand. Never automatic.
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
            let target = Naming.uniqueURL(in: url.deletingLastPathComponent(), filename: newName)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                try? await store.updatePath(id, to: target.path)
                try? await store.logProcessing(docID: id, action: "renamed", detail: newName,
                                               confidence: nil, rule: template,
                                               from: url.path, to: target.path, approved: true)
                await syncAliases(docID: id, target: target)
                renamed += 1
            } catch { continue }
        }
        onDataChanged()
        return renamed
    }

    /// Moves documents to a folder the user picked. Explicit, never inferred.
    func move(ids: [Int64], to destination: URL) async -> Int {
        var moved = 0
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for id in ids {
            guard let path = try? await store.documentPath(id) else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().path != destination.path else { continue }
            let target = Naming.uniqueURL(in: destination, filename: url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                try? await store.updatePath(id, to: target.path)
                try? await store.logProcessing(docID: id, action: "moved", detail: destination.lastPathComponent,
                                               confidence: nil, rule: nil, from: path, to: target.path, approved: true)
                await syncAliases(docID: id, target: target)
                moved += 1
            } catch { continue }
        }
        onDataChanged()
        return moved
    }

    func optimize(ids: [Int64]) async -> (count: Int, saved: Int64) {
        var count = 0
        var saved: Int64 = 0
        for id in ids {
            guard let path = try? await store.documentPath(id) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let result = try? Optimizer.optimize(url: url, options: settings.optimizerOptions) else { continue }
            try? await store.setSizes(id, size: result.newSize, originalSize: result.originalSize)
            try? await store.logProcessing(docID: id, action: "optimized",
                                           detail: String(format: "%.0f%% smaller", result.savings * 100),
                                           confidence: nil, rule: nil, from: nil, to: nil, approved: true)
            count += 1
            saved += result.originalSize - result.newSize
        }
        onDataChanged()
        return (count, saved)
    }
}
