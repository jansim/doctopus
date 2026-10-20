import Foundation

extension Indexer {
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
        let status = await intelligence.recheckStatus()
        guard status.isReady else {
            let hint = settings.llmBackend == .remote
                ? "Make sure the server is running and reachable and its details in Settings › Intelligence are right, then try again."
                : "Check the model in Settings › Intelligence, then try again."
            return AnalyzeSummary(blocked: "\(status.label). \(hint)")
        }
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
        let examples = (try? await store.filingExamples(for: id, limit: settings.llmExampleCount)) ?? []
        guard let insight = await intelligence.enrich(text: text, filename: name, url: url,
                                                      pageCount: pages, examples: examples)
        else { return .failed }

        let patch = Store.MetadataPatch(
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
            amount: nil)
        let tags = Array(insight.tags.prefix(4))
        let autoAccept = settings.autoAcceptMatchingTagSuggestions
        // One change, so reverting it from the history takes back what the model said.
        try? await store.logProcessing(docID: id, action: .analyzed, detail: analysisLine(insight),
                                       approved: true) { store in
            try store.storeMetadata(patch)
            for tag in tags { try? store.suggestTag(tag, for: id, autoAcceptMatching: autoAccept) }
        }
        return .updated(name)
    }

    private func analysisLine(_ i: DocumentInsight) -> String {
        var parts = [MetadataSource(i.source).detailedLabel]
        if let type = i.docType { parts.append(type) }
        if let c = i.correspondent { parts.append(c) }
        if !i.tags.isEmpty { parts.append(i.tags.prefix(4).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
