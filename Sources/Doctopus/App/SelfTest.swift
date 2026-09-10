import Foundation

/// Headless exercise of the full ingest pipeline: scan → OCR → analyze →
/// enrich → index → search. Run with `Doctopus --selftest <folder>`.
enum SelfTest {
    static func run(path: String?) {
        let raw = path ?? "Testing/DemoLibrary"
        let source = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await execute(source: source)
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// `Doctopus --new-library <folder>` — creates a `library.doctopus` in a
    /// folder without opening the UI, and marks it as the library to open next
    /// launch.
    static func newLibrary(_ path: String) {
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let container = folder.appendingPathComponent("library.doctopus", isDirectory: true)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            guard (try? Store(directory: container)) != nil else {
                print("✗ could not create library"); return
            }
            if let bookmark = try? folder.bookmarkData(
                includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set([bookmark], forKey: "openLibraries_v1")
            }
            print("Created \(container.path)")
        }
        semaphore.wait()
    }

    private static func execute(source: URL) async {
        // Work on a throwaway copy so the checked-in fixture is never written to
        // and its library.doctopus does not end up in the tree.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try FileManager.default.copyItem(at: source, to: root) }
        catch { print("✗ could not stage library: \(error)"); exit(1) }

        let container = root.appendingPathComponent("library.doctopus", isDirectory: true)
        guard let store = try? Store(directory: container) else { print("✗ could not open store"); exit(1) }
        print("Library: \(container.lastPathComponent)")
        print("Root:   \(root.path)\n")

        var settings = AppSettings()

        let intelligence = Intelligence()
        await intelligence.update(settings: settings)
        let status = await intelligence.status()
        print("Model:  \(status.label)\n")
        // A backend that cannot answer would only add latency to every
        // document; the checks below cover the heuristic path either way.
        if !status.isReady { settings.llmBackend = .off }
        await intelligence.update(settings: settings)

        let indexer = Indexer(store: store, intelligence: intelligence, settings: settings,
                              onProgress: { p in
                                  if p.total > 0 && p.done == p.total {
                                      print("  \(p.phase): \(p.done)/\(p.total)")
                                  }
                              },
                              onDataChanged: {})

        for rule in Router.starterRules { _ = try? await store.upsertRule(rule) }

        let clock = Date()
        await indexer.indexAll()
        let elapsed = Date().timeIntervalSince(clock)

        let stats = (try? await store.stats()) ?? Store.Stats()
        print(String(format: "\nIndexed %d documents in %.2fs (%.0f ms/doc)\n",
                     stats.total, elapsed, elapsed * 1000 / Double(max(stats.total, 1))))

        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        print("CHECKS")
        Check.that("documents indexed", stats.total > 0, "\(stats.total)")
        var sources: Set<String> = []
        var textless: [String] = []
        for row in rows {
            let detail = try? await store.detail(row.doc)
            if let source = detail?.ocrSource { sources.insert(source) }
            if detail?.ocrWords ?? 0 == 0 { textless.append(row.filename) }
        }
        Check.that("every document has extracted text", textless.isEmpty, textless.joined(separator: ", "))
        let undated = rows.filter { $0.docDate == nil }
        Check.that("every document has a date", undated.isEmpty,
                   undated.map(\.filename).joined(separator: ", "))
        // A type is a guess from the text, and a document the heuristics have
        // no rule for — a certificate, say — legitimately has none.
        let typed = rows.filter { $0.docType != nil }.count
        Check.that("most documents get a type",
                   Double(typed) >= Double(rows.count) * 0.8, "\(typed)/\(rows.count)")
        // The fixtures deliberately include pages with no text layer, so both
        // extraction paths have to have run.
        Check.that("both text paths exercised", sources.contains("pdf-layer") && sources.contains("vision"),
                   sources.sorted().joined(separator: ", "))

        print("\nDOCUMENTS")
        for row in rows {
            guard let detail = try? await store.detail(row.doc) else { continue }
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
        for probe in ["rechnung", "insurance polic", "type:Invoice", "\"net pay\""] {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(probe),
                                                       sort: .relevance, ascending: false)) ?? []
            Check.that("search \(probe) finds something", !hits.isEmpty, "\(hits.count) hit(s)")
        }
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
        let tree = (try? await store.folderTree()) ?? []
        Check.that("folder tree built", !tree.isEmpty && tree[0].deepCount == stats.total)
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
            let text = (try? await store.ocrText(row.doc)) ?? ""
            let findings = DocumentAnalyzer.analyze(url: row.url, text: text, fallbackDate: row.createdAt,
                                                    knownCorrespondents: [])
            let decision = router.evaluate(text: text, filename: row.filename, findings: findings,
                                           insight: nil, currentDirectory: row.url.deletingLastPathComponent())
            let target = decision.destination.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") } ?? "(stays put)"
            print("  \(row.filename.padded(38)) → \(target.padded(28)) \(Int(decision.confidence * 100))%  [\(decision.rule)]")
        }

        print("\nRULE EDITING")
        let samples = (try? await store.ruleSamples()) ?? []
        Check.that("every document is a rule sample", samples.count == stats.total,
                   "\(samples.count)/\(stats.total)")
        Check.that("a pattern is read the way the router will read it",
                   Router.kind(of: "invoice, rechnung") == .words(["invoice", "rechnung"])
                       && Router.kind(of: "^inv.*") == .regex
                       && { if case .invalidRegex = Router.kind(of: "inv(oice") { return true }; return false }())
        if var rule = ((try? await store.rules()) ?? []).last,
           let payslip = rows.first(where: { $0.filename.lowercased().contains("gehalt") }) {
            let original = rule
            // Point the lowest rule at the payslip's filename, then move it to
            // the top: the router has to pick up both the edit and the order.
            rule.name = "Edited"
            rule.field = "filename"
            rule.pattern = "gehaltsabrechnung"
            rule.destination = "Edited/{year}"
            rule.weight = 0.99
            _ = try? await store.upsertRule(rule)
            let others = ((try? await store.rules()) ?? []).map(\.id).filter { $0 != rule.id }
            try? await store.reorderRules([rule.id] + others)
            let edited = (try? await store.rules()) ?? []
            Check.that("an edited rule is saved and can be moved to the top",
                       edited.first?.id == rule.id && edited.first?.pattern == "gehaltsabrechnung"
                           && edited.first?.field == "filename")
            let text = (try? await store.ocrText(payslip.doc)) ?? ""
            let findings = DocumentAnalyzer.analyze(url: payslip.url, text: text,
                                                    fallbackDate: payslip.createdAt, knownCorrespondents: [])
            let decision = Router(rules: edited, threshold: settings.routingThreshold,
                                  derivedTemplate: settings.derivedTemplate, root: root,
                                  deriveWhenNoRule: true)
                .evaluate(text: text, filename: payslip.filename, findings: findings, insight: nil,
                          currentDirectory: payslip.url.deletingLastPathComponent())
            print("  \(payslip.filename) → \(decision.destination?.path.replacingOccurrences(of: root.path + "/", with: "") ?? "(stays put)") [\(decision.rule)]")
            Check.that("routing follows the edited rule", decision.rule == "Edited"
                       && decision.destination?.path.contains("/Edited/") == true)
            _ = try? await store.upsertRule(original)
            try? await store.reorderRules(((try? await store.rules()) ?? [])
                .sorted { $0.priority > $1.priority }.map(\.id))
        }

        print("\nFIELDS")
        let fields = (try? await store.fields()) ?? []
        for field in fields {
            let count = ((try? await store.facets(field: field)) ?? []).count
            print("  \(field.name.padded(16)) key=\(field.key.padded(14)) "
                  + "\(field.isBuiltin ? "built-in" : "custom  ") "
                  + "sidebar=\(field.showInSidebar ? "y" : "n") list=\(field.showInList ? "y" : "n") "
                  + "values=\(count)")
        }

        print("\nRENAME + MERGE")
        if let typeField = fields.first(where: { $0.key == "doc_type" }) {
            var n = (try? await store.renameFieldValue(field: typeField, from: "Invoice", to: "Bill")) ?? 0
            print("  Invoice → Bill                        \(n) document(s)")
            n = (try? await store.renameFieldValue(field: typeField, from: "Contract", to: "Bill")) ?? 0
            let after = ((try? await store.facets(field: typeField)) ?? [])
                .first { $0.value == "Bill" }?.count ?? 0
            print("  Contract → Bill (merge)               \(n) document(s); “Bill” now holds \(after)")
            Check.that("renaming two values to one merges them", after >= 2, "“Bill” holds \(after)")
            n = (try? await store.renameFieldValue(field: typeField, from: "Bill", to: "Invoice")) ?? 0
            print("  Bill → Invoice (restore)              \(n) document(s)")
        }

        // A custom field behaves the same way, including the merge.
        if let id = try? await store.addCustomField(name: "Project"),
           let project = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }) {
            for (index, row) in rows.prefix(3).enumerated() {
                try? await store.setFieldValue(docID: row.doc, field: project,
                                               value: index == 0 ? "Alpha" : "Beta")
            }
            let before = (try? await store.facets(field: project)) ?? []
            print("  custom “Project” values               \(before.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
            _ = try? await store.renameFieldValue(field: project, from: "Alpha", to: "Beta")
            let merged = (try? await store.facets(field: project)) ?? []
            print("  Alpha → Beta (merge)                  \(merged.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
            let filtered = (try? await store.listDocuments(selection: .field("project", "Beta"),
                                                           query: SearchQuery(""), sort: .added,
                                                           ascending: false)) ?? []
            print("  filter project:Beta                   \(filtered.count) hit(s)")
            Check.that("custom field merges and filters", merged.count == 1 && filtered.count == 3,
                       "\(merged.count) value(s), \(filtered.count) hit(s)")
            try? await store.deleteField(id)
        }

        print("\nFINDER TAGS (written to the files themselves)")
        if let sample = rows.first {
            let before = FinderTags.entries(sample.url)
            _ = FinderTags.add("Doctopus Test", to: sample.url)
            let entries = FinderTags.entries(sample.url)
            let onDisk = entries.map(\.name)
            try? await store.indexFinderTags(docID: sample.doc, entries: entries)
            let listed = (try? await store.finderTags()) ?? []
            let filtered = (try? await store.listDocuments(selection: .finderTag("Doctopus Test"),
                                                           query: SearchQuery(""), sort: .added,
                                                           ascending: false)) ?? []
            print("  \(sample.filename) → \(onDisk.joined(separator: ", "))")
            print("  library-wide            \(listed.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
            Check.that("a Finder tag is written to the file and indexed",
                       onDisk.contains("Doctopus Test")
                           && listed.contains { $0.value == "Doctopus Test" }
                           && filtered.contains { $0.id == sample.id })
            let searched = (try? await store.listDocuments(selection: .all,
                                                           query: SearchQuery("finder:\"Doctopus Test\""),
                                                           sort: .added, ascending: false)) ?? []
            Check.that("finder: searches the Finder's tags", searched.contains { $0.id == sample.id })

            // Colours: a tag named after one of the Finder's own gets that
            // label, and adding a second tag leaves the first one's colour be.
            _ = FinderTags.add("Blue", to: sample.url)
            _ = FinderTags.add("Doctopus Colour", to: sample.url)
            let coloured = FinderTags.entries(sample.url)
            print("  colours                 " + coloured.map { "\($0.name)=\($0.label)" }.joined(separator: ", "))
            Check.that("a Finder colour tag keeps macOS's own label",
                       coloured.contains { $0.name == "Blue" && $0.label == 4 },
                       coloured.map { "\($0.name)=\($0.label)" }.joined(separator: ", "))
            Check.that("adding a tag preserves the colours already on the file",
                       coloured.first { $0.name == "Blue" }?.label == 4)

            // Put the file back exactly as it was found, colours included.
            _ = FinderTags.write(before, to: sample.url)
            Check.that("removing them leaves the file as it was",
                       FinderTags.entries(sample.url) == before)
            try? await store.indexFinderTags(docID: sample.doc, entries: FinderTags.entries(sample.url))
        }

        print("\nVALUE ICONS")
        if let typeField = fields.first(where: { $0.key == "doc_type" }),
           let first = ((try? await store.facets(field: typeField)) ?? []).first {
            try? await store.setValueIcon(field: typeField, value: first.value, icon: "banknote")
            let withIcon = ((try? await store.facets(field: typeField)) ?? [])
                .first { $0.value == first.value }
            print("  \(first.value.padded(20)) icon=\(withIcon?.icon ?? "—") (field default \(typeField.icon))")
            Check.that("a value can carry its own icon", withIcon?.icon == "banknote")

            // Renaming carries the icon across with the value.
            _ = try? await store.renameFieldValue(field: typeField, from: first.value, to: "Icon Test")
            let renamed = ((try? await store.facets(field: typeField)) ?? []).first { $0.value == "Icon Test" }
            Check.that("the icon follows a renamed value", renamed?.icon == "banknote")
            _ = try? await store.renameFieldValue(field: typeField, from: "Icon Test", to: first.value)
            try? await store.setValueIcon(field: typeField, value: first.value, icon: nil)
        }

        print("\nTAG MERGE")
        let invoiceTag = (try? await store.tagID(named: "invoice")) ?? 0
        let billTag = (try? await store.tagID(named: "bills")) ?? 0
        for row in rows.prefix(2) { try? await store.assign(tag: invoiceTag, to: row.doc) }
        for row in rows.prefix(3) { try? await store.assign(tag: billTag, to: row.doc) }
        try? await store.setTagColor(billTag, 3)
        let before = (try? await store.tags()) ?? []
        print("  before  \(before.map { "\($0.name) (\($0.count), colour \($0.color))" }.joined(separator: ", "))")
        _ = try? await store.renameTag(invoiceTag, to: "bills")
        let after = (try? await store.tags()) ?? []
        print("  after   \(after.map { "\($0.name) (\($0.count), colour \($0.color))" }.joined(separator: ", "))")
        Check.that("merged tag keeps the target's colour and documents",
                   after.count == 1 && after[0].name == "bills" && after[0].count == 3 && after[0].color == 3)

        print("\nALIASES (drag onto a folder)")
        if let target = rows.first(where: { $0.directory.hasSuffix("Work") })?.url.deletingLastPathComponent(),
           let source = rows.first(where: { $0.directory.hasSuffix("Inbox") }) {
            if let created = try? AliasManager.createAlias(to: source.url, in: target) {
                try? await store.recordAlias(docID: source.doc, tagID: nil, path: created.path)
                let listed = (try? await store.listDocuments(selection: .folder(target.path),
                                                             query: SearchQuery(""), sort: .added,
                                                             ascending: false)) ?? []
                print("  aliased \(source.filename) into \(target.lastPathComponent)")
                for row in listed {
                    print("    \(row.filename.padded(40)) \(row.isAliasHere ? "alias → \((row.directory as NSString).lastPathComponent)" : "master")")
                }
                print("  resolves back to: \(AliasManager.resolve(created)?.lastPathComponent ?? "✗ broken")")
                Check.that("alias is listed in its folder and resolves to the master",
                           listed.contains { $0.isAliasHere && $0.id == source.id }
                               && AliasManager.resolve(created) == source.url)
                AliasManager.removeAlias(at: created.path)
            }
        }

        print("\nQUEUE MODE (same browser, review columns)")
        let queued = (try? await store.listDocuments(selection: .queue, query: SearchQuery(""),
                                                     sort: .added, ascending: false)) ?? []
        Check.that("queue mode carries a processing row per document",
                   queued.count == rows.count && queued.allSatisfy { $0.queue != nil })
        for row in queued.prefix(4) {
            guard let q = row.queue else { continue }
            print("  \(row.filename.padded(36)) \(q.action.padded(10)) "
                  + "\(q.approved ? "approved    " : "needs review") \(q.detail ?? "")")
        }

        print("\nQUEUE")
        for entry in ((try? await store.processingQueue(limit: 8)) ?? []) {
            print("  \(entry.action.padded(10)) \(entry.filename.padded(34)) \(entry.detail ?? "")")
        }
        print("\nIMPORT (a file from outside the library)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-import-\(UUID().uuidString).pdf")
        if let sample = rows.first, let data = try? Data(contentsOf: sample.url),
           (try? data.write(to: outside)) != nil {
            // No auto-routing: routing has its own dry run above, and this
            // should not scatter folders through the fixture library.
            var quiet = settings
            quiet.autoRouteImports = false
            quiet.deriveWhenNoRule = false
            await indexer.update(settings: quiet)
            await indexer.importFiles([outside], into: root.appendingPathComponent("Inbox"))
            let copied = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? [])
                .first { $0.filename == outside.lastPathComponent }
            print("  imported \(outside.lastPathComponent) → \(copied?.directory ?? "nowhere")")
            // The disk outside the library is never the app's to change: an
            // import copies, and the original stays where the user left it.
            Check.that("importing copies and leaves the original alone",
                       FileManager.default.fileExists(atPath: outside.path) && copied != nil)
            if let copied { try? FileManager.default.removeItem(at: copied.url) }
            try? FileManager.default.removeItem(at: outside)
        }

        await fileSafety(store: store, indexer: indexer, settings: settings, root: root)

        print("\nMODEL BACKENDS")
        // The address people actually paste, from four different places.
        let pasted = [
            "http://localhost:1234": "http://localhost:1234/v1",
            "http://localhost:1234/": "http://localhost:1234/v1",
            "http://localhost:1234/v1": "http://localhost:1234/v1",
            "http://localhost:1234/v1/chat/completions": "http://localhost:1234/v1",
            "localhost:11434/v1": "http://localhost:11434/v1",
        ]
        var normalized = true
        for (input, expected) in pasted.sorted(by: { $0.key < $1.key }) {
            let got = RemoteLLMConfig(endpoint: input).baseURL?.absoluteString
            if got != expected { normalized = false }
            print("  \(input.padded(46)) → \(got ?? "nothing")")
        }
        Check.that("an endpoint is normalized however it was pasted", normalized)
        Check.that("an empty endpoint is not a URL", RemoteLLMConfig(endpoint: " ").baseURL == nil)

        // Servers wrap their JSON in a code fence often enough that re-prompting
        // would be the more expensive answer.
        let fenced = """
        Here you go:
        ```json
        {"summary": "A gas bill.", "correspondent": "Stadtwerke", "documentType": "Invoice",
         "language": "DE", "intent": "Pay", "title": "Gas bill", "tags": ["utilities", "#GAS"]}
        ```
        """
        let parsed = RemoteLLMService.parse(fenced)
        print("  parsed: \(parsed?.docType ?? "—") · \(parsed?.correspondent ?? "—") · \(parsed.map { $0.tags.joined(separator: ", ") } ?? "")")
        Check.that("a fenced, chatty JSON reply still parses",
                   parsed?.correspondent == "Stadtwerke" && parsed?.docType == "Invoice"
                       && parsed?.language == "de" && parsed?.intent == "pay"
                       && parsed?.tags == ["utilities", "gas"] && parsed?.source == "remote")
        Check.that("a reply with nothing in it is a failure, not empty metadata",
                   RemoteLLMService.parse("{\"summary\": \"\", \"tags\": []}") == nil)
        Check.that("prose with no JSON in it is a failure",
                   RemoteLLMService.parse("I could not read that document.") == nil)

        // A reasoning model that writes its trace into the content rather than
        // into a field of its own drafts objects on the way to the answer, so
        // the first pair of braces in the reply is not the answer.
        let thinking = """
        <think>
        Let me draft this: {"summary": "unsure", "title": ""} — no, that is wrong,
        the letterhead says Northwind. The braces above should not be my answer.
        </think>
        {"summary": "An insurance policy renewal.", "correspondent": "Northwind Insurance Ltd",
         "documentType": "Insurance", "language": "German", "intent": "file",
         "title": "Policy renewal", "tags": ["insurance"]}
        """
        let thought = RemoteLLMService.parse(thinking)
        print("  through a thinking trace: \(thought?.correspondent ?? "—") · \(thought?.language ?? "—")")
        Check.that("a thinking trace in the content does not become the answer",
                   thought?.correspondent == "Northwind Insurance Ltd"
                       && thought?.title == "Policy renewal")
        // Asked for a code, a model will sometimes answer with the name; a
        // truncated "germa" in the sidebar next to real codes is worse than none.
        Check.that("a language given by name is stored as its code", thought?.language == "de")
        Check.that("a language that is neither is dropped",
                   RemoteLLMService.parse(#"{"title": "T", "language": "Klingon-ish"}"#)?.language == nil)

        // The manual trigger says why it did nothing rather than looking like
        // it worked. With no backend configured that reason is the settings.
        var noModel = settings
        noModel.llmBackend = .off
        await indexer.update(settings: noModel)
        let blocked = await indexer.analyze(ids: rows.map(\.doc))
        print("  analyze with no backend: \(blocked.blocked ?? "ran anyway")")
        Check.that("a manual run with no model reports why", blocked.blocked != nil)

        // A live run against a real server, when one is pointed at. This is how
        // a configuration is verified without the UI:
        //   DOCTOPUS_LLM_ENDPOINT=http://localhost:1234/v1 DOCTOPUS_LLM_MODEL=… --selftest …
        let env = ProcessInfo.processInfo.environment
        if let endpoint = env["DOCTOPUS_LLM_ENDPOINT"]?.nilIfBlank {
            print("\nLIVE MODEL (\(endpoint))")
            var live = settings
            live.llmBackend = .remote
            live.remoteEndpoint = endpoint
            live.remoteModel = env["DOCTOPUS_LLM_MODEL"] ?? ""
            live.remoteAPIKey = env["DOCTOPUS_LLM_API_KEY"] ?? ""
            live.remoteTimeout = 60
            await intelligence.update(settings: live)

            let offered = await intelligence.models(live.remoteConfig)
            print("  models: \(offered.isEmpty ? "none listed" : offered.joined(separator: ", "))")
            if live.remoteModel.isEmpty, let first = offered.first { live.remoteModel = first }
            await intelligence.update(settings: live)

            let reachable = await intelligence.refreshStatus()
            print("  status: \(reachable.label)")
            Check.that("the configured endpoint is reachable", reachable.isReady, reachable.label)

            await indexer.update(settings: live)
            let subject = Array(rows.prefix(2).map(\.doc))
            let run = await indexer.analyze(ids: subject)
            print("  analyzed \(run.updated), skipped \(run.skipped), failed \(run.failed)"
                  + (run.blocked.map { " — blocked: \($0)" } ?? ""))
            Check.that("the manual run enriched documents over the API",
                       run.updated == subject.count && run.blocked == nil)

            var enriched: [DocumentDetail] = []
            for id in subject {
                if let d = try? await store.detail(id) { enriched.append(d) }
            }
            for d in enriched {
                print("  \(d.row.filename.padded(40)) \(d.metadataSource ?? "—")  \(d.row.summary ?? "no summary")")
            }
            Check.that("what the API returned is stored as its own source",
                       !enriched.isEmpty && enriched.allSatisfy { $0.metadataSource == "remote" && $0.row.summary != nil })
        }

        Check.finish("pipeline self-test")
    }

    /// Doctopus may only ever move or rewrite a file it just brought in itself,
    /// and only when nobody said where it should go. Everything else — files
    /// already in the library, imports into a chosen folder, the user's own
    /// aliases — it must leave exactly as it found them.
    private static func fileSafety(store: Store, indexer: Indexer, settings: AppSettings, root staged: URL) async {
        print("\nFILE SAFETY")
        // The store's own root, with `/var` resolved to `/private/var`, so
        // paths compare equal to the ones it hands back.
        let root = store.root
        _ = staged
        let fm = FileManager.default
        var routing = settings
        routing.autoRouteImports = true
        routing.deriveWhenNoRule = true
        routing.optimizeOnImport = true
        await indexer.update(settings: routing)

        /// Every document file under the root, with its content hash.
        func snapshot() -> [String: String] {
            var out: [String: String] = [:]
            for f in FileScanner.scan(root: root) { out[f.url.path] = FileScanner.hash(f.url) ?? "" }
            return out
        }

        // 1. Rescanning and reprocessing every document touches no file.
        let before = snapshot()
        let ids = (try? await store.allDocumentIDs()) ?? []
        await indexer.reprocess(ids: ids)
        await indexer.indexAll()
        let after = snapshot()
        Check.that("reprocessing leaves every file where it was, byte for byte",
                   before == after, "\(before.count) before, \(after.count) after")

        // 2. "Importing" a file that is already in the library — a drop of a
        // row back onto the list, say — indexes it in place. The invoice in the
        // Inbox matches a starter rule, so a real import of it would be moved.
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        if let invoice = rows.first(where: { $0.directory == inbox.path && $0.filename.contains("Invoice") }) {
            let hash = FileScanner.hash(invoice.url)
            let result = await indexer.importFiles([invoice.url], into: inbox, route: true)
            let stillThere = fm.fileExists(atPath: invoice.path) && FileScanner.hash(invoice.url) == hash
            let path = try? await store.documentPath(invoice.doc)
            Check.that("importing a file already in the library neither moves nor rewrites it",
                       stillThere && path == invoice.path && result.alreadyInLibrary == 1 && result.imported == 0,
                       path ?? "gone")
        } else {
            Check.that("the fixtures have an invoice in the Inbox", false)
        }

        // A document no existing rule matches, so only the test rules below
        // decide where its copies go.
        let existing = ((try? await store.rules()) ?? []).filter(\.enabled)
        var neutral: DocumentRow?
        for row in rows where row.ext == "pdf" {
            let text = (try? await store.ocrText(row.doc)) ?? ""
            let hit = existing.contains {
                Router.matches($0.pattern, in: Router.subject(for: $0.field, text: text, filename: row.filename,
                                                              correspondent: row.correspondent, docType: row.docType))
            }
            if !hit { neutral = row; break }
        }

        // Test rules, first in line, keyed to filenames nothing else has.
        let outside = fm.temporaryDirectory.appendingPathComponent("doctopus-escape-\(UUID().uuidString)",
                                                                    isDirectory: true)
        let testRules = [
            Rule(id: 0, name: "Clear", pattern: "doctopus-clear", field: "filename",
                 destination: "Filed/Clear", tagNames: nil, weight: 0.99, enabled: true, priority: 1000),
            Rule(id: 0, name: "Tie A", pattern: "doctopus-tie", field: "filename",
                 destination: "Filed/A", tagNames: nil, weight: 0.95, enabled: true, priority: 999),
            Rule(id: 0, name: "Tie B", pattern: "doctopus-tie", field: "filename",
                 destination: "Filed/B", tagNames: nil, weight: 0.94, enabled: true, priority: 998),
            Rule(id: 0, name: "Escape", pattern: "doctopus-escape", field: "filename",
                 destination: outside.path, tagNames: nil, weight: 0.99, enabled: true, priority: 997),
        ]
        var ruleIDs: [Int64] = []
        for rule in testRules { if let id = try? await store.upsertRule(rule) { ruleIDs.append(id) } }

        /// A copy of a fixture from outside the library, under a chosen name.
        func stage(_ name: String) -> URL? {
            guard let sample = neutral else { return nil }
            let url = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name).pdf")
            return (try? fm.copyItem(at: sample.url, to: url)) != nil ? url : nil
        }
        func imported(_ name: String) async -> DocumentRow? {
            ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                             sort: .added, ascending: false)) ?? [])
                .first { $0.filename.contains(name) }
        }

        // 3. A new file with one clear home is filed there.
        if let clear = stage("doctopus-clear") {
            await indexer.importFiles([clear], into: inbox, route: true)
            let row = await imported("doctopus-clear")
            print("  clear match        → \(row?.directory.replacingOccurrences(of: root.path + "/", with: "") ?? "nowhere")")
            Check.that("a new document with one clear home is filed there",
                       row?.directory == root.appendingPathComponent("Filed/Clear").path)
            Check.that("…and the file it was copied from is left alone", fm.fileExists(atPath: clear.path))
            try? fm.removeItem(at: clear)
        }

        // 4. The same new file into a folder someone chose stays there.
        if let chosen = stage("doctopus-clear-chosen") {
            let folder = root.appendingPathComponent("Work", isDirectory: true)
            await indexer.importFiles([chosen], into: folder, route: false)
            let row = await imported("doctopus-clear-chosen")
            Check.that("an import into a chosen folder is never routed away",
                       row?.directory == folder.path, row?.directory ?? "nowhere")
            try? fm.removeItem(at: chosen)
        }

        // 5. Two equally good homes: it waits in the Inbox with both on offer.
        if let tie = stage("doctopus-tie") {
            await indexer.importFiles([tie], into: inbox, route: true)
            let row = await imported("doctopus-tie")
            var offered: [PathSuggestion] = []
            var queued = false
            if let row {
                offered = (try? await store.pathSuggestions(for: row.doc)) ?? []
                queued = ((try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? [])
                    .contains { $0.id == row.id }
            }
            print("  two equal homes    → \(row?.directory.replacingOccurrences(of: root.path + "/", with: "") ?? "nowhere"); offered \(offered.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") })")
            Check.that("a new document with two equally good homes stays in the Inbox",
                       row?.directory == inbox.path)
            Check.that("…with both homes kept as suggestions",
                       offered.map(\.path).contains(root.appendingPathComponent("Filed/A").path)
                           && offered.map(\.path).contains(root.appendingPathComponent("Filed/B").path))
            Check.that("…and waits in Needs Review", queued)
            try? fm.removeItem(at: tie)
        }

        // 6. A rule pointing outside the library moves nothing out of it.
        if let escape = stage("doctopus-escape") {
            await indexer.importFiles([escape], into: inbox, route: true)
            let row = await imported("doctopus-escape")
            let inside = row.map { $0.directory == root.path || $0.directory.hasPrefix(root.path + "/") } ?? false
            Check.that("routing never moves a file outside its library",
                       inside && !fm.fileExists(atPath: outside.path), row?.directory ?? "nowhere")
            try? fm.removeItem(at: escape)
        }

        // 7. A folder alias the user made survives a reprocess.
        if let doc = rows.first(where: { $0.directory.hasSuffix("Personal") }) {
            let folder = root.appendingPathComponent("Work", isDirectory: true)
            if let alias = try? AliasManager.createAlias(to: doc.url, in: folder) {
                try? await store.recordAlias(docID: doc.doc, tagID: nil, path: alias.path)
                await indexer.reprocess(ids: [doc.doc])
                await indexer.syncAliases(docID: doc.doc, target: doc.url)
                Check.that("a folder alias the user made survives reprocessing",
                           fm.fileExists(atPath: alias.path))
                AliasManager.removeAlias(at: alias.path, pointingTo: doc.url)
            }
        }

        // 8. Something that is no longer an alias is never deleted as one.
        let impostor = root.appendingPathComponent("Work/not-an-alias.txt")
        try? Data("the user's own file".utf8).write(to: impostor)
        let removed = AliasManager.removeAlias(at: impostor.path)
        Check.that("removing an alias never deletes a real file in its place",
                   !removed && fm.fileExists(atPath: impostor.path))
        try? fm.removeItem(at: impostor)

        for id in ruleIDs { try? await store.deleteRule(id) }
        await indexer.update(settings: settings)
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
