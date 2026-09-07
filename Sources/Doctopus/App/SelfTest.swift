import Foundation

/// Headless exercise of the full ingest pipeline: scan → OCR → analyze →
/// enrich → index → search. Run with `Doctopus --selftest <folder>`.
enum SelfTest {
    static func run(path: String?) {
        let raw = path ?? "Testing/DemoLibrary"
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await execute(root: root)
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// `Doctopus --add-root <folder>` — registers a folder without opening the UI.
    static func addRoot(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dbURL = support.appendingPathComponent("Doctopus/index.sqlite")
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            guard let store = try? Store(url: dbURL) else { print("✗ could not open index"); return }
            _ = try? await store.addRoot(path: url.path, bookmark: nil)
            print("Added \(url.path) to the index.")
        }
        semaphore.wait()
    }

    private static func execute(root: URL) async {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-selftest-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        guard let store = try? Store(url: dbURL) else { print("✗ could not open store"); return }
        print("Index:  \(dbURL.lastPathComponent)")
        print("Root:   \(root.path)\n")

        let llm = LLMService()
        let status = await llm.probe()
        print("Model:  \(status.label)\n")

        var settings = AppSettings()
        settings.optimizeExisting = false
        settings.useOnDeviceModel = status.isReady

        let indexer = Indexer(store: store, llm: llm, settings: settings,
                              onProgress: { p in
                                  if p.total > 0 && p.done == p.total {
                                      print("  \(p.phase): \(p.done)/\(p.total)")
                                  }
                              },
                              onDataChanged: {})

        _ = try? await store.addRoot(path: root.path, bookmark: nil)
        for rule in Router.starterRules { _ = try? await store.upsertRule(rule) }

        let clock = Date()
        await indexer.indexAll()
        let elapsed = Date().timeIntervalSince(clock)

        let stats = (try? await store.stats()) ?? Store.Stats()
        print(String(format: "\nIndexed %d documents in %.2fs (%.0f ms/doc)\n",
                     stats.total, elapsed, elapsed * 1000 / Double(max(stats.total, 1))))

        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        print("DOCUMENTS")
        for row in rows {
            guard let detail = try? await store.detail(row.id) else { continue }
            print("  \(row.filename)")
            print("    title:  \(row.title ?? "—")")
            print("    from:   \(row.correspondent ?? "—")   type: \(row.docType ?? "—")   lang: \(row.language ?? "—")")
            print("    date:   \(row.docDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—") (\(detail.dateSource ?? "—"))")
            print("    ocr:    \(detail.ocrWords ?? 0) words via \(detail.ocrSource ?? "—")"
                  + (detail.ocrConfidence.map { String(format: ", %.0f%% confidence", $0 * 100) } ?? ""))
            if let amount = detail.amount { print("    amount: \(amount)") }
            if let summary = row.summary { print("    summary: \(summary)") }
            if !detail.tags.isEmpty { print("    tags:   \(detail.tags.map(\.name).joined(separator: ", "))") }
        }

        print("\nSEARCH")
        for probe in ["rechnung", "insurance polic", "kontoauszug", "steuer", "type:Invoice", "is:pending", "\"net pay\""] {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(probe),
                                                       sort: .relevance, ascending: false)) ?? []
            let names = hits.prefix(3).map(\.filename).joined(separator: ", ")
            print("  \(probe.padded(22)) → \(hits.count) hit\(hits.count == 1 ? "" : "s")\(hits.isEmpty ? "" : ": \(names)")")
            if let snippet = hits.first?.snippet {
                print("  \("".padded(22))   …\(snippet.replacingOccurrences(of: "\n", with: " "))…")
            }
        }

        print("\nFACETS")
        for (label, column) in [("correspondents", "correspondent"), ("types", "doc_type"), ("languages", "language")] {
            let facets = (try? await store.facets(column: column)) ?? []
            print("  \(label.padded(16)) \(facets.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
        }

        print("\nFOLDER TREE")
        let tree = (try? await store.folderTree(roots: [root.path])) ?? []
        printTree(tree, depth: 0)

        print("\nRENAME PREVIEW (\(Naming.defaultTemplate))")
        for row in rows.prefix(4) {
            let ctx = Naming.Context(date: row.docDate ?? row.createdAt, correspondent: row.correspondent,
                                     title: row.title, docType: row.docType, language: row.language,
                                     counter: 1, originalStem: row.url.deletingPathExtension().lastPathComponent,
                                     ext: row.url.pathExtension)
            print("  \(row.filename.padded(38)) → \(Naming.render(Naming.defaultTemplate, ctx))")
        }

        print("\nROUTING (dry run against starter rules)")
        let router = Router(rules: (try? await store.rules()) ?? [], threshold: settings.routingThreshold,
                            derivedTemplate: settings.derivedTemplate, root: root, deriveWhenNoRule: true)
        for row in rows {
            let text = (try? await store.ocrText(row.id)) ?? ""
            let findings = DocumentAnalyzer.analyze(url: row.url, text: text, fallbackDate: row.createdAt,
                                                    knownCorrespondents: [])
            let decision = router.evaluate(text: text, filename: row.filename, findings: findings,
                                           insight: nil, currentDirectory: row.url.deletingLastPathComponent())
            let target = decision.destination.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") } ?? "(stays put)"
            print("  \(row.filename.padded(38)) → \(target.padded(28)) \(Int(decision.confidence * 100))%  [\(decision.rule)]")
        }

        print("\nQUEUE")
        for entry in ((try? await store.processingQueue(limit: 8)) ?? []) {
            print("  \(entry.action.padded(10)) \(entry.filename.padded(34)) \(entry.detail ?? "")")
        }
        print("\n✓ self-test complete")
    }

    private static func printTree(_ nodes: [FolderNode], depth: Int) {
        for node in nodes {
            print("  \(String(repeating: "  ", count: depth))\(node.isRoot ? node.path : node.name) (\(node.deepCount))")
            printTree(node.children, depth: depth + 1)
        }
    }
}

private extension String {
    func padded(_ n: Int) -> String {
        count >= n ? String(prefix(n)) : self + String(repeating: " ", count: n - count)
    }
}
