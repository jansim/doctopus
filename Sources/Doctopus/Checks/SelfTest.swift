import Foundation
import AppKit

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
        let store: Store
        do {
            store = try Store(directory: container)
        } catch {
            print("✗ could not open store: \(error)")
            exit(1)
        }
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

        for rule in Rule.starters { _ = try? await store.upsertRule(rule) }

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
        let page1 = (try? await store.listDocuments(selection: .all, query: SearchQuery(""), sort: .added, ascending: false, limit: 3, offset: 0)) ?? []
        let page2 = (try? await store.listDocuments(selection: .all, query: SearchQuery(""), sort: .added, ascending: false, limit: 3, offset: 3)) ?? []
        Check.that("paging returns distinct slices", page1.count == 3 && page2.count == 3 && Set(page1.map(\.doc)).isDisjoint(with: Set(page2.map(\.doc))))
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
            print("    date:   \(row.docDate.map(DayDate.text) ?? "—") (\(detail.dateSource ?? "—"))")
            print("    ocr:    \(detail.ocrWords ?? 0) words via \(detail.ocrSource ?? "—")"
                  + (detail.ocrConfidence.map { String(format: ", %.0f%% confidence", $0 * 100) } ?? ""))
            if let amount = detail.amount { print("    amount: \(amount)") }
            if let summary = row.summary { print("    summary: \(summary)") }
            if !detail.tags.isEmpty { print("    tags:   \(detail.tags.map(\.name).joined(separator: ", "))") }
        }

        print("\nSEARCH")
        for probe in ["rechnung", "insurance polic", "type:Invoice", "\"net pay\"", "rechnung OR kontoauszug", "-type:Invoice", "date:2026", "date:2026-02"] {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(probe),
                                                       sort: .relevance, ascending: false)) ?? []
            Check.that("search \(probe) finds something", !hits.isEmpty, "\(hits.count) hit(s)")
        }
        for probe in ["rechnung", "insurance polic", "kontoauszug", "steuer", "type:Invoice", "is:pending", "\"net pay\"", "rechnung OR kontoauszug", "-type:Invoice", "date:2026", "date:2026-02"] {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(probe),
                                                       sort: .relevance, ascending: false)) ?? []
            let names = hits.prefix(3).map(\.filename).joined(separator: ", ")
            print("  \(probe.padded(24)) → \(hits.count) hit\(hits.count == 1 ? "" : "s")\(hits.isEmpty ? "" : ": \(names)")")
            if let snippet = hits.first?.snippet {
                print("  \("".padded(24))   …\(snippet.replacingOccurrences(of: "\n", with: " "))…")
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

        // A folder made in Finder (or from the sidebar's "New Subfolder…",
        // which does the same thing) has no document in it yet, but it is
        // still a real folder — it should show up rather than wait for one.
        //
        // `store.absPath` round-trips through the library's own canonical
        // root (e.g. /var → /private/var on macOS), which a path built
        // straight from the local `root` variable has not been through —
        // so node.path is compared against the same round-trip, not against
        // `emptyFolder.path` itself.
        let emptyFolder = root.appendingPathComponent("Empty Subfolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        let treeWithEmptyFolder = (try? await store.folderTree()) ?? []
        let emptyFolderPath = store.absPath(store.relPath(emptyFolder.path))
        Check.that("an empty folder on disk still shows in the tree",
                   findNode(path: emptyFolderPath, in: treeWithEmptyFolder)?.count == 0)

        // The default tag-mirror directory holds aliases, not documents, and
        // is a view of the library rather than a home — it must not ride the
        // disk walk above into a sidebar row of its own.
        let tagsMirror = root.appendingPathComponent("Tags", isDirectory: true)
            .appendingPathComponent("Some Tag", isDirectory: true)
        try? FileManager.default.createDirectory(at: tagsMirror, withIntermediateDirectories: true)
        let treeWithTagsMirror = (try? await store.folderTree()) ?? []
        let tagsMirrorPath = store.absPath(store.relPath(tagsMirror.path))
        Check.that("the Tags/ mirror is not promoted into the folder tree",
                   findNode(path: tagsMirrorPath, in: treeWithTagsMirror) == nil)

        print("\nRENAME PREVIEW (\(Naming.defaultTemplate))")
        for row in rows.prefix(4) {
            let ctx = Naming.Context(date: row.docDate ?? row.createdAt, correspondent: row.correspondent,
                                     title: row.title, docType: row.docType, language: row.language,
                                     counter: 1, originalStem: row.url.deletingPathExtension().lastPathComponent,
                                     ext: row.url.pathExtension)
            print("  \(row.filename.padded(38)) → \(Naming.render(Naming.defaultTemplate, ctx))")
        }
        let fallbackCtx = Naming.Context(date: nil, correspondent: nil, title: "..", docType: nil,
                                         language: nil, counter: nil, originalStem: ".hidden", ext: "pdf")
        let renderedDefault = Naming.render("{correspondent|Unknown}_{title}", fallbackCtx)
        Check.that("template conditional fallback renders default", renderedDefault.hasPrefix("Unknown"))
        Check.that("path safety cleans invalid or hidden stems", !renderedDefault.hasPrefix(".") && !renderedDefault.contains(".."))

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

        ruleMigration()

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
            // Point the lowest rule at the payslip's filename, then move it to
            // the top: the router has to pick up both the edit and the order.
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
            let decision = Router(rules: edited, threshold: settings.routingThreshold,
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

            // Tag union across multiple matching rules
            let ruleA = Rule(id: 0, name: "RuleA", priority: 100,
                             conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                             actions: [RuleAction(kind: .moveFile, value: "A/{year}"),
                                       RuleAction(kind: .addTags, value: "tagA, commonTag")])
            let ruleB = Rule(id: 0, name: "RuleB", priority: 90,
                             conditions: [RuleCondition(field: .filename, pattern: "februar")],
                             actions: [RuleAction(kind: .moveFile, value: "B/{year}"),
                                       RuleAction(kind: .addTags, value: "tagB, commonTag")])
            let unionDecision = Router(rules: [ruleA, ruleB], threshold: 0.5,
                                       derivedTemplate: "", root: root, deriveWhenNoRule: false)
                .evaluate(text: text, filename: payslip.filename, findings: findings, insight: nil,
                          currentDirectory: payslip.url.deletingLastPathComponent())
            Check.that("matching rules combine tags as a union",
                       unionDecision.tags.contains("tagA") && unionDecision.tags.contains("tagB") && unionDecision.tags.count == 3)

            await conditionsAndActions(store: store, root: root, text: text,
                                       findings: findings, payslip: payslip)

            // Metadata assignment via rule apply-to-existing
            let assignRule = Rule(id: 0, name: "SetPayroll", priority: 100,
                                  conditions: [RuleCondition(field: .filename, pattern: "gehaltsabrechnung")],
                                  actions: [RuleAction(kind: .addTags, value: "payroll"),
                                            RuleAction(kind: .setCorrespondent, value: "Acme HR"),
                                            RuleAction(kind: .setDocType, value: "Payslip")])
            let savedAssignID = (try? await store.upsertRule(assignRule)) ?? 0
            let applyResult = (try? await store.applyRuleToExisting(ruleID: savedAssignID)) ?? Store.RuleApplyResult()
            Check.that("rule can assign metadata and tags to existing documents",
                       applyResult.matched > 0 && applyResult.tagged > 0)
            try? await store.deleteRule(savedAssignID)
            if let payrollTag = try? await store.tagID(named: "payroll") {
                try? await store.deleteTag(payrollTag)
            }

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

        // A built-in field's value has to reach the list as well as the
        // inspector. They fold their values separately, and a column whose
        // value only the inspector knew about shows an em dash for every
        // document and sorts as if it were empty.
        if let subject = rows.first,
           let amount = fields.first(where: { $0.builtinColumn == "amount" }),
           let intent = fields.first(where: { $0.builtinColumn == "intent" }) {
            try? await store.setFieldValue(docID: subject.doc, field: amount, value: "€49,90")
            try? await store.setFieldValue(docID: subject.doc, field: intent, value: "pay")
            let listed = ((try? await store.listDocuments(
                selection: .all, query: SearchQuery(""), sort: .added, ascending: false)) ?? [])
                .first { $0.doc == subject.doc }
            let inspected = try? await store.detail(subject.doc)
            print("  in the list             \(listed?.values["amount"] ?? "—") / \(listed?.values["intent"] ?? "—")")
            Check.that("a built-in field's value reaches the list, not only the inspector",
                       listed?.values["amount"] == "€49,90" && listed?.values["intent"] == "pay",
                       "\(listed?.values["amount"] ?? "—"), \(listed?.values["intent"] ?? "—")")
            let disagreed = fields.filter { $0.isBuiltin }
                .filter { listed?.values[$0.key] != inspected?.row.values[$0.key] }
            Check.that("…and the two agree about every built-in field",
                       disagreed.isEmpty, disagreed.map(\.key).joined(separator: ", "))
            // Put it back as it was, so the sections below see the library the
            // fixture describes.
            try? await store.setFieldValue(docID: subject.doc, field: amount, value: nil)
            try? await store.setFieldValue(docID: subject.doc, field: intent, value: nil)
        }

        print("\nSAVED VIEWS (SMART FOLDERS)")
        let sv = SavedView(id: 0, name: "Invoices 2026", icon: "doc.text",
                           query: "type:Invoice date:2026", sortKey: "docDate", ascending: false,
                           viewMode: "List", position: 0)
        let savedVID = (try? await store.upsertSavedView(sv)) ?? 0
        let svList = (try? await store.savedViews()) ?? []
        Check.that("saved view is persisted", svList.contains { $0.id == savedVID && $0.name == "Invoices 2026" })
        if let foundSV = svList.first(where: { $0.id == savedVID }) {
            let hits = (try? await store.listDocuments(selection: .savedView(id: foundSV.id, query: foundSV.query),
                                                       query: SearchQuery(foundSV.query), sort: .added, ascending: false)) ?? []
            Check.that("saved view query returns matching documents", !hits.isEmpty)
        }
        try? await store.deleteSavedView(savedVID)
        let svAfter = (try? await store.savedViews()) ?? []
        Check.that("saved view can be deleted", !svAfter.contains { $0.id == savedVID })

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

        // Deleting a document that is filed in a second folder by hand is not
        // a delete at all: the nearest of those placements takes its place, so
        // the library keeps the document and loses only the folder it was
        // deleted from.
        if let source = rows.first(where: { $0.directory.hasSuffix("Inbox") }),
           let second = rows.first(where: { $0.directory.hasSuffix("Work") })?
               .url.deletingLastPathComponent(),
           let created = try? AliasManager.createAlias(to: source.url, in: second) {
            try? await store.recordAlias(docID: source.doc, tagID: nil, path: created.path)
            let landed = await indexer.promoteClosestAlias(docID: source.doc)
            print("  deleted \(source.filename.padded(32)) → "
                  + (landed?.deletingLastPathComponent().lastPathComponent ?? "the Trash"))
            Check.that("deleting an aliased document promotes the alias into the document",
                       landed?.deletingLastPathComponent().standardizedFileURL
                           == second.standardizedFileURL
                           && FileManager.default.fileExists(atPath: landed?.path ?? ""))
            // The document moves in under its own name, so it usually ends up
            // at the alias's exact path. What says the alias is gone is that
            // nothing standing there is one.
            Check.that("…and the alias it stood in for is gone",
                       !AliasManager.isAlias(URL(fileURLWithPath: created.path)))
            Check.that("…and nothing is left in the folder it was deleted from",
                       !FileManager.default.fileExists(atPath: source.path))
            Check.that("…and the registry no longer carries the promoted placement",
                       !((try? await store.aliases(for: source.doc)) ?? [])
                           .contains(where: { $0.path == created.path }))

            // Undo puts the delete back whole. Returning the document without
            // the alias would quietly unfile it from the folder it was also
            // in, which is not what was undone.
            let undone = try? await store.undoLastEvent()
            let restored = (try? await store.documentPath(source.doc)) ?? ""
            let placements = ((try? await store.aliases(for: source.doc)) ?? [])
                .filter { $0.tagID == nil }
            Check.that("undo returns a promoted document to the folder it was deleted from",
                       undone?.action == "promoted" && restored == source.path,
                       undone?.action ?? "nothing to undo")
            Check.that("…and writes the alias it stood in for again",
                       placements.contains(where: { alias in
                           let at = URL(fileURLWithPath: alias.path)
                           guard AliasManager.isAlias(at),
                                 let points = AliasManager.resolve(at) else { return false }
                           return Store.canonical(points.standardizedFileURL.path)
                               == Store.canonical(URL(fileURLWithPath: restored)
                                   .standardizedFileURL.path)
                       }),
                       "\(placements.count) placement(s)")

            // Leave the fixture library laid out the way this section found it.
            for alias in placements {
                AliasManager.removeAlias(at: alias.path,
                                         pointingTo: URL(fileURLWithPath: restored))
                try? await store.deleteAlias(id: alias.id)
            }
        }

        // Deleting an alias on its own is undone the other way round: nothing
        // moved, so the alias is written again where it was.
        if let doc = rows.first(where: { $0.directory.hasSuffix("Inbox") }),
           let elsewhere = rows.first(where: { $0.directory.hasSuffix("Work") })?
               .url.deletingLastPathComponent(),
           let created = try? AliasManager.createAlias(to: doc.url, in: elsewhere) {
            try? await store.recordAlias(docID: doc.doc, tagID: nil, path: created.path)
            let record = ((try? await store.aliases(for: doc.doc)) ?? [])
                .first(where: { $0.path == created.path })
            AliasManager.removeAlias(at: created.path, pointingTo: doc.url)
            if let record { try? await store.deleteAlias(id: record.id) }
            try? await store.logProcessing(
                docID: doc.doc, action: "unfiled",
                detail: "No longer filed under \(elsewhere.lastPathComponent)",
                confidence: nil, rule: nil, from: doc.path, to: created.path, approved: true)

            let undone = try? await store.undoLastEvent()
            let back = ((try? await store.aliases(for: doc.doc)) ?? []).filter { $0.tagID == nil }
            // `&&` takes its right side as a non-async autoclosure, so anything
            // awaited has to be in hand before the check, not inside it.
            let stillHome = (try? await store.documentPath(doc.doc)) ?? ""
            Check.that("undoing a deleted alias writes the alias again, and nothing else",
                       undone?.action == "unfiled"
                           && back.contains(where: { AliasManager.isAlias(URL(fileURLWithPath: $0.path)) })
                           && stillHome == doc.path,
                       undone?.action ?? "nothing to undo")

            for alias in back {
                AliasManager.removeAlias(at: alias.path, pointingTo: doc.url)
                try? await store.deleteAlias(id: alias.id)
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
        if let sample = rows.first, var data = try? Data(contentsOf: sample.url) {
            data.append(Data("\n% unique-\(UUID().uuidString)\n".utf8))
            try? data.write(to: outside)
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

            // Re-importing the same bytes must be detected as a duplicate and skipped
            let dupResult = await indexer.importFiles([outside], into: root.appendingPathComponent("Inbox"))
            Check.that("re-importing a byte-identical document is skipped as duplicate",
                       dupResult.imported == 0 && dupResult.duplicates == 1)

            if let copied { try? FileManager.default.removeItem(at: copied.url) }
            try? FileManager.default.removeItem(at: outside)
        }

        print("\nIMPORT (a folder from outside the library)")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-folder-\(UUID().uuidString)", isDirectory: true)
        let deeper = folder.appendingPathComponent("Receipts/2025", isDirectory: true)
        try? FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        let tag = UUID().uuidString.prefix(6)
        let top = folder.appendingPathComponent("top-\(tag).pdf")
        let nested = deeper.appendingPathComponent("nested-\(tag).pdf")
        if rows.count >= 2, var one = try? Data(contentsOf: rows[0].url),
           var two = try? Data(contentsOf: rows[1].url) {
            one.append(Data("\n% unique-top-\(tag)\n".utf8))
            two.append(Data("\n% unique-nested-\(tag)\n".utf8))
            try? one.write(to: top)
            try? two.write(to: nested)
            // Neither is a document: one is not a type Doctopus reads, the
            // other is hidden, the way a Finder or sync-tool leftover is.
            try? Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
            try? one.write(to: deeper.appendingPathComponent(".hidden-\(tag).pdf"))

            let inbox = root.appendingPathComponent("Inbox")
            let result = await indexer.importFiles([folder], into: inbox)
            let arrived = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                           sort: .added, ascending: false)) ?? [])
                .filter { $0.filename.contains(tag) }
            print("  imported \(result.imported): \(arrived.map(\.filename).sorted().joined(separator: ", "))")
            Check.that("importing a folder brings in the documents at every depth, and only those",
                       result.imported == 2 && arrived.count == 2
                           && arrived.allSatisfy { $0.directory == Store.canonical(inbox.path) },
                       "\(result.imported) imported, \(arrived.count) indexed")
            Check.that("importing a folder leaves the folder alone",
                       [top, nested].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            for row in arrived { try? FileManager.default.removeItem(at: row.url) }
        }
        try? FileManager.default.removeItem(at: folder)

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
                       && parsed?.tags == ["utilities", "gas"] && parsed?.source.hasPrefix("remote") == true)
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

        let testPrompt = LLMPrompt.user(text: "Sample Document", filename: "invoice.pdf", limit: 1000, candidateTags: ["finances", "invoices"])
        Check.that("prompt includes untrusted user data marker", testPrompt.contains("untrusted user data"))
        Check.that("prompt includes candidate taxonomy tags", testPrompt.contains("finances, invoices"))
        Check.that("a page image is only spoken of when one is attached",
                   !testPrompt.contains("attached image"))

        // What a vision-capable endpoint is asked: the same questions, plus the
        // page count and the first page itself.
        let visionPrompt = LLMPrompt.user(text: "Sample Document", filename: "invoice.pdf", limit: 1000,
                                          pageCount: 12, hasPageImage: true)
        Check.that("prompt states how many pages the document has", visionPrompt.contains("Pages: 12"))
        Check.that("prompt says the attached image is the document's first page",
                   visionPrompt.contains("first page of the document"))
        Check.that("the system message tells a vision model to read the page too",
                   LLMPrompt.instructions(withPageImage: true).contains("page image")
                       && !LLMPrompt.instructions().contains("page image"))
        Check.that("the system message asks for the document's own language",
                   LLMPrompt.instructions().contains("language the document"))

        // The first page, rendered from a fixture that is really on disk. Asked
        // for fresh: the rows read at the start of the run have been moved
        // around by everything between here and there.
        let pdfs = (try? await store.listDocuments(selection: .all, query: SearchQuery("ext:pdf"),
                                                   sort: .added, ascending: false)) ?? []
        if let pdf = pdfs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let rendered = PageImage.firstPage(of: pdf.url, maxDimension: 768)
            print("  page image: " + (rendered.map { "\($0.width)×\($0.height), \($0.kilobytes) KB, \($0.pageCount ?? 0) page(s)" } ?? "none"))
            Check.that("the first page of a PDF renders as a JPEG",
                       rendered?.jpeg.starts(with: [0xFF, 0xD8, 0xFF]) == true)
            Check.that("the rendered page fits the size it was asked for",
                       rendered.map { max($0.width, $0.height) <= 768 } ?? false,
                       rendered.map { "\($0.width)×\($0.height)" } ?? "—")
            Check.that("rendering the page also counts the document's pages",
                       (rendered?.pageCount ?? 0) >= 1)
            Check.that("the page travels as an inline data URL",
                       rendered?.dataURL.hasPrefix("data:image/jpeg;base64,") == true)
        } else {
            Check.that("a PDF fixture is there to render a page from", false)
        }

        // How that page is carried: one user turn, two content parts.
        let stubPage = PageImage.Rendered(jpeg: Data([0xFF, 0xD8, 0xFF]), width: 8, height: 8, pageCount: 3)
        let withImage = RemoteLLMService.userMessage(prompt: "prompt", image: stubPage)
        let parts = withImage["content"] as? [[String: Any]]
        Check.that("a page image travels beside the text as an image_url part",
                   parts?.count == 2 && parts?.first?["type"] as? String == "text"
                       && parts?.last?["type"] as? String == "image_url")
        Check.that("the image part carries the page inline",
                   ((parts?.last?["image_url"] as? [String: Any])?["url"] as? String)?
                       .hasPrefix("data:image/jpeg;base64,") == true)
        Check.that("with no image the user turn stays the plain string it always was",
                   RemoteLLMService.userMessage(prompt: "prompt", image: nil)["content"] as? String == "prompt")

        // Provenance: the inspector has to be able to say the model was shown
        // the page, long after the fact.
        let visionSource = RemoteLLMService.parse(#"{"title": "T"}"#, model: "qwen2.5-vl", vision: true)?.source
        Check.that("what a vision model answered is stored as its own source",
                   visionSource == "vlm:qwen2.5-vl:v\(LLMPrompt.promptVersion)", visionSource ?? "—")
        Check.that("a vision answer reads back as an API model that saw the page",
                   MetadataSource(visionSource ?? "") == .remote(model: "qwen2.5-vl", vision: true))
        Check.that("a vision answer is not stale under the current prompt",
                   !(visionSource ?? "").isEmpty
                       && (visionSource ?? "").hasSuffix(":v\(LLMPrompt.promptVersion)"))

        let staleHits = (try? await store.listDocuments(selection: .all, query: SearchQuery("is:stale-analysis"), sort: .added, ascending: false)) ?? []
        Check.that("is:stale-analysis returns heuristic documents needing model analysis", !staleHits.isEmpty)

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
            // DOCTOPUS_LLM_VISION=1 additionally sends the first page as an
            // image, which is how a vision model is verified before it is
            // configured in the app.
            live.remoteVision = env["DOCTOPUS_LLM_VISION"] == "1"
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
                       !enriched.isEmpty && enriched.allSatisfy {
                           if case .remote = MetadataSource($0.metadataSource ?? "") { return $0.row.summary != nil }
                           return false
                       })
        }

        print("\nURL SCHEMES & SHORTCUTS")
        if let searchURL = URL(string: "doctopus://search?q=rechnung") {
            let action = URLSchemeHandler.parse(searchURL)
            Check.that("URL scheme parses doctopus://search", action == .search("rechnung"))
        }
        if let importURL = URL(string: "doctopus://import?path=/tmp/scan.pdf") {
            let action = URLSchemeHandler.parse(importURL)
            Check.that("URL scheme parses doctopus://import", action == .import("/tmp/scan.pdf"))
        }

        print("\nAUTOCOMPLETE & GLOBAL SEARCH")
        let globalResults = (try? await store.listDocuments(selection: .all, query: SearchQuery("rechnung"), sort: .added, ascending: false)) ?? []
        Check.that("search suggestions and queries return hits for terms", !globalResults.isEmpty)

        print("\nENTITIES")
        // Correspondents and types are rows now, so renaming one is one row and
        // renaming it onto another is a merge — which two free-text columns
        // could not do at all.
        if let corrField = ((try? await store.fields()) ?? []).first(where: { $0.key == "correspondent" }) {
            let live = (try? await store.entities(builtin: "correspondent")) ?? []
            let listed: [String] = live.prefix(4).map { "\($0.name) (\($0.count))" }
            print("  correspondents          " + listed.joined(separator: ", "))
            Check.that("every correspondent in use is a row", !live.isEmpty)
            Check.that("…and each one exists exactly once",
                       Set(live.map { $0.name.lowercased() }).count == live.count)

            // Renaming and merging are done on values made up for the purpose,
            // so the fixture library is left exactly as the rest of the run
            // expects to find it.
            if rows.count >= 3 {
                let spellingA = "Doctopus Werke GmbH"
                let spellingB = "Doctopus Werke"
                try? await store.setFieldValue(docID: rows[0].doc, field: corrField, value: spellingA)
                try? await store.setFieldValue(docID: rows[1].doc, field: corrField, value: spellingA)
                try? await store.setFieldValue(docID: rows[2].doc, field: corrField, value: spellingB)
                try? await store.setValueIcon(field: corrField, value: spellingA, icon: "building.columns")

                let renamed = (try? await store.renameFieldValue(field: corrField, from: spellingA,
                                                                 to: "Doctopus Werke AG")) ?? 0
                var after = (try? await store.entities(builtin: "correspondent")) ?? []
                let moved = after.first { $0.name == "Doctopus Werke AG" }
                let movedCount: Int = moved?.count ?? 0
                print("  " + spellingA + " → Doctopus Werke AG   "
                      + "\(movedCount) document(s), \(renamed) row(s)")
                Check.that("renaming a correspondent takes every document with it",
                           moved?.count == 2, "\(moved?.count ?? -1)")
                Check.that("…and its icon comes along rather than being orphaned",
                           moved?.icon == "building.columns")
                Check.that("…leaving no trace of the old spelling",
                           !after.contains { $0.name == spellingA })
                let filtered = (try? await store.listDocuments(
                    selection: .field("correspondent", "Doctopus Werke AG"), query: SearchQuery(""),
                    sort: .added, ascending: false)) ?? []
                Check.that("…and the sidebar filter follows it", filtered.count == 2,
                           "\(filtered.count) documents")

                // The merge the string columns could never do.
                _ = try? await store.renameFieldValue(field: corrField, from: spellingB, to: "Doctopus Werke AG")
                after = (try? await store.entities(builtin: "correspondent")) ?? []
                let survivor = after.first { $0.name == "Doctopus Werke AG" }
                let survivorCount: Int = survivor?.count ?? 0
                print("  " + spellingB + " merged in       \(survivorCount) document(s)")
                Check.that("two spellings merge into one correspondent",
                           survivor?.count == 3 && !after.contains { $0.name == spellingB },
                           "\(survivor?.count ?? -1) of 3")

                // And it is findable as one thing, under its one name.
                let searched = (try? await store.listDocuments(
                    selection: .all, query: SearchQuery("Doctopus Werke AG"), sort: .relevance,
                    ascending: false)) ?? []
                Check.that("…searchable under the surviving name", searched.count >= 3,
                           "\(searched.count) hits")

                // Put the fixture back the way the rest of the run found it.
                for row in rows.prefix(3) {
                    try? await store.setFieldValue(docID: row.doc, field: corrField,
                                                   value: row.correspondent)
                }
                try? await store.deleteFieldValue(field: corrField, value: "Doctopus Werke AG")
            }

            // A correspondent that identifies itself, which is what having a
            // row it can carry a rule on is for.
            if let subject = rows.first {
                let made = (try? await store.entityID(named: "Selbsterkennung",
                                                      builtin: "correspondent")) ?? nil
                if let made {
                    try? await store.setEntityMatch(made, pattern: "doctopus-iban-de12")
                    let matching = (try? await store.matchingEntities()) ?? []
                    let picked = DocumentAnalyzer.analyze(
                        url: subject.url, text: "Kontoauszug für doctopus-iban-de12 im Januar",
                        fallbackDate: Date(), knownCorrespondents: [],
                        options: DocumentAnalyzer.Options(entityRules: matching)).correspondent
                    print("  identified by its own pattern → \(picked ?? "nothing")")
                    Check.that("a correspondent carrying a pattern identifies itself",
                               picked == "Selbsterkennung")
                    try? await store.deleteEntity(made, column: "correspondent")
                }
            }

            // The "AG" problem: a short known name matched as a plain substring
            // fires on very nearly every document there is.
            Check.that("a known correspondent only matches on a word boundary",
                       DocumentAnalyzer.correspondent(
                           text: "Gehaltsabrechnung von Northwind\nSehr geehrte Damen",
                           known: ["AG", "rech"]) != "AG")
        }

        print("\nMATCH MODES")
        // What used to be guessed from the punctuation is now said out loud.
        func hits(_ pattern: String, _ mode: MatchMode, _ subject: String,
                  insensitive: Bool = true) -> Bool {
            PatternMatcher.matches(pattern, mode: mode, insensitive: insensitive, in: subject)
        }
        Check.that("“Acme (UK) Ltd” is a name when the rule says it is one",
                   hits("Acme (UK) Ltd", .anyWord, "Invoice from Acme (UK) Ltd"))
        // …which is what a *new* rule gets. Migration deliberately does not:
        // the old router compiled that pattern as a regex, and whatever a rule
        // meant yesterday is what it goes on meaning.
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
                   PatternMatcher.openingEnds("invoice,  rechnung*, net pay") == "invoice*, rechnung*, net pay*")
        Check.that("all words needs every one of them",
                   hits("amount, due", .allWords, "the amount due is")
                       && !hits("amount, missing", .allWords, "the amount due is"))
        // The OCR line-wrap case, which is why the phrase mode exists at all.
        Check.that("a phrase matches across the line break OCR put in it",
                   hits("amount due", .exactPhrase, "Total\namount\n  due   today")
                       && !hits("amount due", .exactPhrase, "amount is overdue"))
        Check.that("a regex is one only when the rule says so",
                   hits("^inv-\\d+", .regex, "inv-4821")
                       && !hits("^inv-\\d+", .anyWord, "inv-4821"))
        Check.that("case can be insisted on",
                   hits("ACME", .anyWord, "acme corp")
                       && !hits("ACME", .anyWord, "acme corp", insensitive: false))
        // OCR noise: one substituted letter should not lose the match.
        Check.that("fuzzy survives a misread letter",
                   hits("rechnung", .fuzzy, "Rechnunq Nr. 42")
                       && !hits("rechnung", .fuzzy, "Kontoauszug"))
        for pattern in ["Acme (UK) Ltd", "^inv-\\d+", "inv(oice"] {
            print("  " + pattern.padded(20) + " → " + MatchMode.inferred(from: pattern).shortLabel)
        }
        Check.that("a pattern that was read as a regex keeps being one when migrated",
                   MatchMode.inferred(from: "^inv-\\d+") == .regex)
        Check.that("…and one that never compiled is migrated as the words it was matching",
                   MatchMode.inferred(from: "inv(oice") == .anyWord)

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

        print("\nNESTED TAGS")
        // Assigning a child assigns everything it sits under, which is what
        // makes filtering by the parent find what is filed under the child.
        let finances = (try? await store.tagID(named: "Finances")) ?? 0
        let invoices = (try? await store.tagID(named: "Finances Invoices")) ?? 0
        let statements = (try? await store.tagID(named: "Finances Statements")) ?? 0
        _ = try? await store.setTagParent(invoices, to: finances)
        _ = try? await store.setTagParent(statements, to: finances)
        if let subject = rows.first {
            try? await store.assign(tag: invoices, to: subject.doc)
            let carried = (try? await store.tags(for: subject.doc)) ?? []
            print("  tagged with Invoices → \(carried.map(\.name).joined(separator: ", "))")
            Check.that("assigning a child attaches its parent too",
                       carried.contains { $0.tagID == finances })
            let byParent = (try? await store.listDocuments(selection: .tag(TagRef(library: "", tag: finances)),
                                                           query: SearchQuery(""), sort: .added,
                                                           ascending: false)) ?? []
            Check.that("…so filtering by the parent finds it",
                       byParent.contains { $0.doc == subject.doc })
        }
        let shaped = (try? await store.tags()) ?? []
        for tag in shaped where tag.name.hasPrefix("Finances") {
            print("  \(String(repeating: "  ", count: tag.depth))\(tag.name) (\(tag.count))")
        }
        Check.that("children are drawn under their parent, one level in",
                   shaped.first { $0.tagID == invoices }?.depth == 1
                       && shaped.first { $0.tagID == finances }?.depth == 0)

        // A tag cannot sit inside itself, directly or round a loop.
        Check.that("a tag cannot be its own parent",
                   (try? await store.setTagParent(finances, to: finances)) == false)
        Check.that("a descendant cannot become the parent",
                   (try? await store.setTagParent(finances, to: invoices)) == false)

        // Re-parenting catches the documents up rather than being right only
        // for whatever is tagged next.
        let deep = (try? await store.tagID(named: "Household")) ?? 0
        if let subject = rows.first {
            _ = try? await store.setTagParent(finances, to: deep)
            let after = (try? await store.tags(for: subject.doc)) ?? []
            Check.that("re-parenting gives the documents the new ancestor",
                       after.contains { $0.tagID == deep },
                       after.map(\.name).joined(separator: ", "))
            _ = try? await store.setTagParent(finances, to: nil)
        }

        // Five deep, and no further.
        var chain: [Int64] = []
        for level in 1...6 {
            let id = (try? await store.tagID(named: "Level \(level)")) ?? 0
            chain.append(id)
            if level > 1 { _ = try? await store.setTagParent(id, to: chain[level - 2]) }
        }
        let levels = (try? await store.tags()) ?? []
        let deepest = levels.filter { $0.name.hasPrefix("Level ") }.map(\.depth).max() ?? 0
        print("  deepest nesting reached \(deepest + 1) level(s)")
        Check.that("tags nest no deeper than the cap", deepest < Tag.maxDepth,
                   "depth \(deepest)")
        for id in chain.reversed() { try? await store.deleteTag(id) }
        for id in [invoices, statements, finances, deep] { try? await store.deleteTag(id) }

        // A slash in a typed tag name is shorthand for nesting it by hand:
        // "tax/2025" should leave "2025" sitting under "tax" without anyone
        // touching "Move Under".
        let taxYear = (try? await store.tagID(named: "tax/2025")) ?? 0
        let taxRoot = (try? await store.tagID(named: "tax")) ?? 0
        let taxShaped = (try? await store.tags()) ?? []
        let taxYearTag = taxShaped.first { $0.tagID == taxYear }
        Check.that("a slash in the name nests the tag it makes",
                   taxYearTag?.parentID == taxRoot && taxYearTag?.name == "2025",
                   taxShaped.map(\.name).joined(separator: ", "))
        // Typing the same path again finds what is already there rather than
        // building a second "tax" or a second "2025".
        let taxYearAgain = (try? await store.tagID(named: "tax/2025")) ?? -1
        Check.that("typing the same nested path twice doesn't duplicate it",
                   taxYearAgain == taxYear)
        if let subject = rows.first {
            try? await store.assign(tag: taxYear, to: subject.doc)
            let carried = (try? await store.tags(for: subject.doc)) ?? []
            let pills = Tag.visible(in: carried)
            Check.that("the pill for a nested tag spells out its whole path",
                       pills.contains { $0.tag.tagID == taxYear && $0.path == "tax/2025" }
                           && !pills.contains { $0.tag.tagID == taxRoot },
                       pills.map(\.path).joined(separator: ", "))
        }
        try? await store.deleteTag(taxYear)
        try? await store.deleteTag(taxRoot)

        print("\nDATES")
        // The same numeric date, read two ways. Which one is right is the
        // library's business, not the Mac's — that is the whole setting.
        let ambiguous = "Rechnungsdatum: 03/04/2026"
        let asDMY = DocumentAnalyzer.dateInText(ambiguous,
            options: DocumentAnalyzer.Options(dateOrder: .dmy))
        let asMDY = DocumentAnalyzer.dateInText(ambiguous,
            options: DocumentAnalyzer.Options(dateOrder: .mdy))
        print("  03/04/2026 as D/M/Y    \(asDMY.map(DayDate.text) ?? "—")")
        print("  03/04/2026 as M/D/Y    \(asMDY.map(DayDate.text) ?? "—")")
        Check.that("an ambiguous date is read the way the library says",
                   asDMY.map(DayDate.text) == "2026-04-03" && asMDY.map(DayDate.text) == "2026-03-04")
        Check.that("automatic takes the order from the language, not from this Mac",
                   DateOrder.automatic.resolved(language: "en-US") == .mdy
                       && DateOrder.automatic.resolved(language: "de") == .dmy
                       && DateOrder.automatic.resolved(language: "ja") == .ymd)
        Check.that("a number over twelve settles the order whatever it is set to",
                   DocumentAnalyzer.dateInText("dated 25/12/2025",
                       options: DocumentAnalyzer.Options(dateOrder: .mdy)).map(DayDate.text)
                       == "2025-12-25")

        // A document is never issued in the future.
        let nextYear = DayDate.calendar.date(byAdding: .year, value: 1, to: Date())!
        let yetToCome = "Datum: \(DayDate.text(nextYear))"
        Check.that("a document is never issued in the future",
                   DocumentAnalyzer.dateInText(yetToCome) == nil,
                   DocumentAnalyzer.dateInText(yetToCome).map(DayDate.text) ?? "none")
        Check.that("…but a field holding a due date may still be",
                   DocumentAnalyzer.anyDate(in: yetToCome).map(DayDate.text) == DayDate.text(nextYear))

        // A date in the ignore list never counts, however well labelled.
        let letterhead = "Formular Stand: 12/01/2019 · Rechnungsdatum: 14/02/2024"
        let ignoring = DocumentAnalyzer.Options(dateOrder: .dmy, ignoredDays: ["2019-01-12"])
        Check.that("an ignored day is never taken as the document's date",
                   DocumentAnalyzer.datesInText(letterhead, source: "ocr", options: ignoring)
                       .allSatisfy { DayDate.text($0.date) != "2019-01-12" })

        // Everything found is kept, labelled ones first.
        let several = "Printed 01/02/2020. Rechnungsdatum: 14/02/2024. Paid 20/02/2024."
        let candidates = DocumentAnalyzer.rank(
            DocumentAnalyzer.datesInText(several, source: "ocr",
                                         options: DocumentAnalyzer.Options(dateOrder: .dmy)))
        let shownCandidates: [String] = candidates.map {
            DayDate.text($0.date) + ($0.labelled ? "*" : "")
        }
        print("  candidates             " + shownCandidates.joined(separator: ", "))
        Check.that("every plausible date is kept, the labelled one first",
                   candidates.count > 1 && candidates.first?.labelled == true
                       && candidates.first.map { DayDate.text($0.date) } == "2024-02-14",
                   "\(candidates.count) candidates")
        Check.that("a day the month does not have is a misread, not a date",
                   DocumentAnalyzer.dateInText("31/02/2024",
                       options: DocumentAnalyzer.Options(dateOrder: .dmy)) == nil)

        // Every stored document date is a day, so two Macs read it the same.
        let stored = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                      sort: .added, ascending: false)) ?? [])
            .compactMap(\.docDate)
        Check.that("every stored date is the start of a day",
                   stored.allSatisfy { $0 == DayDate.startOfDay($0) },
                   "\(stored.count) dates")

        if let subject = rows.first {
            let kept = (try? await store.dateCandidates(for: subject.doc)) ?? []
            print("  \(subject.filename.padded(38)) \(kept.count) candidate(s) kept")
            Check.that("the dates a document offered are kept for the review",
                       !kept.isEmpty || subject.docDate == nil)
        }

        print("\nREVERTIBLE OPTIMISATION")
        if let targetDoc = rows.first(where: { $0.ext == "pdf" }) {
            let origSize = targetDoc.size
            if let hash = FileScanner.hash(targetDoc.url) {
                try? await store.saveOriginalFile(for: targetDoc.doc, from: targetDoc.url, hash: hash)
                try? await store.setSizes(targetDoc.doc, size: origSize / 2, originalSize: origSize)
                let origURL = try? await store.originalFileURL(for: targetDoc.doc)
                Check.that("pre-optimization original file is preserved", origURL != nil && FileManager.default.fileExists(atPath: origURL!.path))
                let reverted = (try? await store.revertOptimization(targetDoc.doc)) ?? false
                Check.that("revert optimization restores document size and removes original_size", reverted)
            }
        }

        print("\nTYPED FIELDS")
        // Reading an amount as a number is the difference between €90 coming
        // before €1,200 and coming after it — and both conventions for writing
        // one have to land on the same value.
        let amounts: [(String, Double?)] = [
            ("€1.234,56", 1234.56), ("$1,234.56", 1234.56), ("1 234,56 EUR", 1234.56),
            ("90", 90), ("€90", 90), ("-12.50", -12.5), ("not a number", nil),
        ]
        var parsedRight = true
        for (raw, expected) in amounts {
            let got = FieldType.number(from: raw)
            if got != expected { parsedRight = false }
            let shown: String = got.map { "\($0)" } ?? "—"
            print("  " + raw.padded(20) + " → " + shown)
        }
        Check.that("an amount is read as a number however it is written", parsedRight)
        Check.that("yes and Yes and true are one answer",
                   FieldType.boolean(from: "yes") == true && FieldType.boolean(from: "Yes") == true
                       && FieldType.boolean(from: "true") == true && FieldType.boolean(from: "No") == false)

        if let id = try? await store.addCustomField(name: "Paid Amount", type: .monetary),
           let money = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }),
           rows.count >= 3 {
            let written = ["€1.234,56", "$90.00", "€12,00"]
            for (index, row) in rows.prefix(3).enumerated() {
                try? await store.setFieldValue(docID: row.doc, field: money, value: written[index])
            }
            let sorted = (try? await store.listDocuments(
                selection: .all, query: SearchQuery(""), sort: .field(money.key),
                ascending: true)) ?? []
            let order = sorted.compactMap { $0.values[money.key] }
            print("  sorted by amount      \(order.joined(separator: ", "))")
            Check.that("amounts sort by value, not by spelling",
                       Array(order.prefix(3)) == ["€12,00", "$90.00", "€1.234,56"],
                       order.joined(separator: ", "))
            Check.that("…and the currency is kept exactly as it was typed",
                       order.contains("€1.234,56"))

            // Changing the type re-reads what is already stored, so a field
            // does not sort correctly only for whatever is typed next.
            var asText = money
            asText.type = .string
            try? await store.updateField(asText)
            var back = money
            back.type = .monetary
            try? await store.updateField(back)
            let again = ((try? await store.listDocuments(
                selection: .all, query: SearchQuery(""), sort: .field(money.key),
                ascending: true)) ?? []).compactMap { $0.values[money.key] }
            Check.that("changing a field's type re-reads the values it already holds",
                       Array(again.prefix(3)) == ["€12,00", "$90.00", "€1.234,56"],
                       again.prefix(3).joined(separator: ", "))
            try? await store.deleteField(id)
        }

        if let id = try? await store.addCustomField(name: "Due", type: .date),
           let due = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }),
           let subject = rows.first {
            try? await store.setFieldValue(docID: subject.doc, field: due, value: "2026-03-04")
            let stored = (try? await store.detail(subject.doc))?.row.values[due.key]
            print("  date field            \(stored ?? "—")")
            Check.that("a date field stores a day, in one spelling", stored == "2026-03-04")
            try? await store.deleteField(id)
        }

        if let id = try? await store.addCustomField(name: "Settled", type: .boolean),
           let flag = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }),
           let subject = rows.first {
            try? await store.setFieldValue(docID: subject.doc, field: flag, value: "true")
            let first = (try? await store.detail(subject.doc))?.row.values[flag.key]
            try? await store.setFieldValue(docID: subject.doc, field: flag, value: "yes")
            let second = (try? await store.detail(subject.doc))?.row.values[flag.key]
            Check.that("a yes/no field has one spelling of yes",
                       first == "Yes" && second == "Yes", "\(first ?? "—"), \(second ?? "—")")
            try? await store.deleteField(id)
        }

        print("\nNOTES")
        if let subject = rows.first {
            let phrase = "cancelled by phone \(UUID().uuidString.prefix(6).lowercased())"
            let noteID = (try? await store.addNote(phrase, to: subject.doc)) ?? 0
            let listed = (try? await store.notes(for: subject.doc)) ?? []
            let found = (try? await store.listDocuments(selection: .all, query: SearchQuery(phrase),
                                                        sort: .relevance, ascending: false)) ?? []
            print("  " + subject.filename.padded(38)
                  + " \(listed.count) note(s), searchable: \(found.count) hit(s)")
            Check.that("a note is kept with the document", listed.contains { $0.id == noteID })
            Check.that("…and is searchable straight away", found.contains { $0.id == subject.id })

            try? await store.updateNote(noteID, body: "the original is in the red folder")
            let edited = (try? await store.notes(for: subject.doc)) ?? []
            Check.that("editing a note marks it edited",
                       edited.first { $0.id == noteID }?.edited == true)
            let stale = (try? await store.listDocuments(selection: .all, query: SearchQuery(phrase),
                                                        sort: .relevance, ascending: false)) ?? []
            Check.that("…and the old wording stops matching", stale.isEmpty, "\(stale.count) hit(s)")

            try? await store.deleteNote(noteID)
            Check.that("a note can be taken away again",
                       ((try? await store.notes(for: subject.doc)) ?? []).isEmpty)
        }

        print("\nRECENTLY DELETED")
        // A deleted document keeps its row, stays out of every listing but its
        // own, and comes back whole — with its tags, title and history — when
        // the file is put back.
        if let victim = rows.first(where: { $0.directory.hasSuffix("Personal") }) ?? rows.first {
            let tagID = (try? await store.tagID(named: "doctopus-restore")) ?? 0
            try? await store.assign(tag: tagID, to: victim.doc)
            try? await store.softDelete(victim.doc, trashPath: nil)

            let listed = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                         sort: .added, ascending: false)) ?? []
            let inTrash = (try? await store.listDocuments(selection: .deleted, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? []
            let after = (try? await store.stats()) ?? Store.Stats()
            print("  deleted \(victim.filename): \(after.deleted) in Recently Deleted, "
                  + "\(after.total) still listed")
            Check.that("a deleted document leaves every ordinary listing",
                       !listed.contains { $0.doc == victim.doc })
            Check.that("…and is exactly what Recently Deleted holds",
                       inTrash.contains { $0.doc == victim.doc } && after.deleted == 1)
            Check.that("…and stops being searchable",
                       !((try? await store.listDocuments(
                            selection: .all, query: SearchQuery(victim.filename),
                            sort: .relevance, ascending: false)) ?? []).contains { $0.doc == victim.doc })
            Check.that("…but its row, and everything on it, is still there",
                       ((try? await store.tags(for: victim.doc)) ?? []).contains { $0.tagID == tagID })

            // A document deleted on purpose is never swept up by the purge that
            // forgets files which simply vanished, however long ago it went.
            _ = try? await store.purgeMissing(olderThan: 0)
            let survived = (try? await store.listDocuments(selection: .deleted, query: SearchQuery(""),
                                                           sort: .added, ascending: false)) ?? []
            Check.that("the purge leaves a document that was deleted on purpose alone",
                       survived.contains { $0.doc == victim.doc })

            try? await store.restore(victim.doc)
            let back = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                       sort: .added, ascending: false)) ?? []
            let keptTags = (try? await store.tags(for: victim.doc)) ?? []
            Check.that("putting it back revives the row it always had",
                       back.contains { $0.doc == victim.doc }
                           && keptTags.contains { $0.tagID == tagID })
            try? await store.unassign(tag: tagID, from: victim.doc)
            try? await store.deleteTag(tagID)
        }

        print("\nHISTORY")
        // The queue is a bounded recency view; the history behind it is not.
        // Overflowing the queue has to leave the record of what happened
        // intact — that was the whole point of splitting the two.
        if let subject = rows.first {
            let firstEvents = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            let oldest = firstEvents.last
            for n in 0...Store.queueLength {
                try? await store.logProcessing(docID: subject.doc, action: "indexed",
                                               detail: "filler \(n)", confidence: nil, rule: nil,
                                               from: nil, to: nil, approved: true)
            }
            let queue = (try? await store.processingQueue(limit: 10_000)) ?? []
            let kept = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            let total = (try? await store.eventCount()) ?? 0
            print("  queue holds \(queue.count), history holds \(total) event(s), "
                  + "\(kept.count) of them for \(subject.filename)")
            Check.that("the queue stays bounded", queue.count <= Store.queueLength,
                       "\(queue.count) entries")
            Check.that("the history is not trimmed with it",
                       kept.count > queue.count, "\(kept.count) events kept")
            Check.that("the first thing that happened to a document is still on record",
                       oldest == nil || kept.contains { $0.id == oldest!.id })
            let detailed = try? await store.detail(subject.doc)
            Check.that("a document's history reaches the inspector",
                       (detailed?.history.count ?? 0) > 0)
            Check.that("history is newest first",
                       zip(kept, kept.dropFirst()).allSatisfy { $0.at >= $1.at })

            // A hand edit belongs in the record and nowhere else: nobody
            // signs off their own typing.
            let approvedBefore = (try? await store.detail(subject.doc))?.row.approved
            try? await store.logEdit(docID: subject.doc, detail: "Title → Typed by hand")
            let edited = (try? await store.history(for: subject.doc, limit: 10_000)) ?? []
            let queueAfterEdit = (try? await store.processingQueue(limit: 10_000)) ?? []
            Check.that("a hand edit is recorded in the history",
                       edited.contains { $0.action == "edited"
                                         && $0.detail == "Title → Typed by hand" })
            Check.that("a hand edit stays out of the review queue",
                       queueAfterEdit.count == queue.count,
                       "\(queueAfterEdit.count) entries, was \(queue.count)")
            Check.that("a hand edit does not put the document back into review",
                       (try? await store.detail(subject.doc))?.row.approved == approvedBefore)

            // Test undo of file move
            let origPath = subject.path
            let movedTarget = root.appendingPathComponent("Work/undotest-\(subject.filename)")
            if (try? FileManager.default.moveItem(at: subject.url, to: movedTarget)) != nil {
                try? await store.updatePath(subject.doc, to: movedTarget.path)
                try? await store.logProcessing(docID: subject.doc, action: "moved", detail: "test move",
                                               confidence: nil, rule: nil, from: origPath, to: movedTarget.path, approved: true)
                let undone = try? await store.undoLastEvent()
                Check.that("undo restores moved file to previous path",
                           undone != nil && FileManager.default.fileExists(atPath: origPath))
            }
        }

        if let sample = rows.first {
            let similar = (try? await store.similarDocuments(for: sample.doc, limit: 3)) ?? []
            Check.that("more-like-this finds similar documents without self", !similar.contains { $0.doc == sample.doc })
        }

        print("\nLOCAL CLASSIFIER")
        let classifier = DocumentClassifier(confidenceThreshold: 0.5)
        let sampleDocs = [
            DocumentClassifier.TrainingDoc(id: 1, text: "Rechnung Stadtwerke München Gas Strom Energie Abrechnung", correspondent: "Stadtwerke München", docType: "Invoice", tags: ["utilities", "bills"]),
            DocumentClassifier.TrainingDoc(id: 2, text: "Stadtwerke München Jahresabrechnung Strom Erdgas", correspondent: "Stadtwerke München", docType: "Invoice", tags: ["utilities", "bills"]),
            DocumentClassifier.TrainingDoc(id: 3, text: "Deutsche Bank Kontoauszug Finanzstatus Saldo Überweisung", correspondent: "Deutsche Bank AG", docType: "Bank Statement", tags: ["finance"]),
            DocumentClassifier.TrainingDoc(id: 4, text: "Kontoauszug Deutsche Bank Girokonto Buchung", correspondent: "Deutsche Bank AG", docType: "Bank Statement", tags: ["finance"])
        ]
        await classifier.train(docs: sampleDocs)
        let predCorr = await classifier.predictCorrespondent(text: "Stadtwerke München Abschlagszahlung Gas")
        let predType = await classifier.predictDocType(text: "Deutsche Bank Auszug Buchungsbestätigung")
        let predTags = await classifier.predictTags(text: "Rechnung Strom Energie")
        Check.that("classifier predicts correspondent on matching vocabulary", predCorr?.label == "Stadtwerke München")
        Check.that("classifier predicts doc_type on matching vocabulary", predType?.label == "Bank Statement")
        Check.that("classifier predicts multi-label tags", predTags.contains { $0.label == "utilities" || $0.label == "bills" })

        print("\nSEARCH INDEX")
        // Everything a person can see is a column of `doc_fts`, so each of
        // these is a ranked hit rather than an unindexed LIKE over the table.
        if let sample = rows.first(where: { $0.correspondent?.nilIfBlank != nil }),
           let correspondent = sample.correspondent?.nilIfBlank {
            let term = correspondent.split(separator: " ").first.map(String.init) ?? correspondent
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(term),
                                                       sort: .relevance, ascending: false)) ?? []
            print(("  correspondent “" + term + "”").padded(40) + "→ \(hits.count) hit(s)")
            Check.that("a correspondent is searchable without a LIKE fallback",
                       hits.contains { $0.id == sample.id })
        }
        if let sample = rows.first {
            let stem = sample.url.deletingPathExtension().lastPathComponent
            let term = stem.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? stem
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(term),
                                                       sort: .relevance, ascending: false)) ?? []
            print(("  filename “" + term + "”").padded(40) + "→ \(hits.count) hit(s)")
            Check.that("a filename is searchable", hits.contains { $0.id == sample.id })

            // A tag assigned now has to be searchable straight away: the index
            // row is rebuilt on assignment, not on the next full pass.
            let unique = "doctopusfts\(UUID().uuidString.prefix(6).lowercased())"
            let tagID = (try? await store.tagID(named: unique)) ?? 0
            try? await store.assign(tag: tagID, to: sample.doc)
            let tagged = (try? await store.listDocuments(selection: .all, query: SearchQuery(unique),
                                                         sort: .relevance, ascending: false)) ?? []
            Check.that("a tag is searchable as soon as it is assigned",
                       tagged.contains { $0.id == sample.id }, "\(tagged.count) hit(s)")
            try? await store.unassign(tag: tagID, from: sample.doc)
            let untagged = (try? await store.listDocuments(selection: .all, query: SearchQuery(unique),
                                                           sort: .relevance, ascending: false)) ?? []
            Check.that("…and stops being searchable when it is taken off", untagged.isEmpty,
                       "\(untagged.count) hit(s)")
            try? await store.deleteTag(tagID)

            // The text of one document is a keyed lookup now, not a scan.
            let text = (try? await store.ocrText(sample.doc)) ?? ""
            Check.that("a document's text is still readable from the index", !text.isEmpty,
                       "\(text.count) characters")
        }
        // A deleted document takes its searchable text with it: `doc_fts` is a
        // virtual table, so no foreign key does this for us. Done last, on the
        // index only — the file itself is never touched by `deleteDocument`.
        if let victim = rows.last, let word = ((try? await store.ocrText(victim.doc)) ?? "")
            .split(whereSeparator: { !$0.isLetter }).first.map(String.init) {
            try? await store.deleteDocument(victim.doc)
            let orphan = (try? await store.listDocuments(selection: .all, query: SearchQuery(word),
                                                         sort: .relevance, ascending: false)) ?? []
            Check.that("deleting a document removes it from the search index",
                       !orphan.contains { $0.doc == victim.doc })
            Check.that("…and the file it indexed is left on disk",
                       FileManager.default.fileExists(atPath: victim.path))
        }

        print("\nLIBRARY FORMAT")
        let metaURL = container.appendingPathComponent("meta.json")
        let stamped = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)))
            as? [String: Any]
        let stampedVersion: Int = (stamped?["formatVersion"] as? Int) ?? -1
        let stampedApp: String = (stamped?["appVersion"] as? String) ?? "—"
        print("  meta.json               formatVersion=\(stampedVersion) appVersion=" + stampedApp)
        Check.that("the writing app stamps the library format it understands",
                   stamped?["formatVersion"] as? Int == Store.formatVersion)

        // A library from a future version is refused rather than misread.
        let future = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-future-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.doctopus", isDirectory: true)
        try? FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
        let ahead: [String: Any] = ["id": UUID().uuidString,
                                    "formatVersion": Store.formatVersion + 1,
                                    "appVersion": "99.0"]
        try? JSONSerialization.data(withJSONObject: ahead)
            .write(to: future.appendingPathComponent("meta.json"))
        var refused: String?
        do { _ = try Store(directory: future) }
        catch let error as Store.OpenError { refused = error.description }
        catch { refused = nil }
        print("  a newer library         \(refused ?? "opened anyway")")
        Check.that("a library from a newer Doctopus is refused, with a reason",
                   refused?.contains("format version") == true)
        try? FileManager.default.removeItem(at: future.deletingLastPathComponent())

        print("\nSANITY CHECK / VERIFICATION")
        let healthyReport = (try? await LibraryVerifier.verify(store: store)) ?? VerificationReport()
        Check.that("verification of healthy library reports zero errors", healthyReport.errorsCount == 0)

        print("\nCONTENT HASHES")
        if let sample = rows.first, let detail = try? await store.detail(sample.doc),
           let hash = detail.hash {
            let found = (try? await store.documents(matchingHash: hash)) ?? []
            print("  " + sample.filename.padded(38) + " " + hash.prefix(12)
                  + "… → \(found.count) match(es)")
            Check.that("a document is findable by the hash of its bytes",
                       found.contains(sample.doc))
            Check.that("a hash nothing carries matches nothing",
                       ((try? await store.documents(matchingHash: "0")) ?? []).isEmpty)
        }

        Check.finish("pipeline self-test")
    }

    /// A rule someone wrote before rules had conditions still means what it
    /// meant. This is their filing, so the migration is checked against a
    /// database in the old shape rather than trusted.
    private static func ruleMigration() {
        print("\nRULE MIGRATION")
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-rules-v17-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = try? Database(path: path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        // The `rules` table exactly as version 17 left it.
        try? db.exec("""
        CREATE TABLE rules (
            id          INTEGER PRIMARY KEY,
            name        TEXT NOT NULL,
            pattern     TEXT NOT NULL,
            field       TEXT NOT NULL DEFAULT 'text',
            destination TEXT NOT NULL,
            tag_names   TEXT,
            weight      REAL NOT NULL DEFAULT 0.9,
            enabled     INTEGER NOT NULL DEFAULT 1,
            priority    INTEGER NOT NULL DEFAULT 0,
            match_mode        INTEGER NOT NULL DEFAULT 0,
            match_insensitive INTEGER NOT NULL DEFAULT 1,
            set_correspondent TEXT,
            set_doc_type      TEXT,
            set_fields        TEXT
        );
        INSERT INTO rules(name, pattern, field, destination, tag_names, weight, enabled,
                          priority, match_mode, match_insensitive, set_correspondent, set_doc_type)
        VALUES ('Filing', 'invoice, rechnung', 'text', 'Finances/Invoices/{year}', 'invoice, finances',
                0.92, 1, 100, 0, 1, NULL, NULL),
               ('Labelling', '^inv-\\d+', 'filename', '', NULL,
                0.8, 0, 10, 3, 0, 'Acme', 'Invoice');
        CREATE TABLE entities (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, match TEXT,
            match_mode INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO entities(name, match, match_mode)
        VALUES ('Stadtwerke', 'stadtwerke, swm', 0), ('Bank', 'DE12 3456', 2);
        PRAGMA user_version=17;
        """)
        try? Schema.migrate(db)

        let conditions = (try? db.map("""
            SELECT r.name, c.field, c.pattern, c.match_mode, c.match_insensitive
            FROM rules r JOIN rule_conditions c ON c.rule_id = r.id ORDER BY r.id
            """) { ($0.string(0), $0.string(1), $0.string(2), $0.int(3), $0.bool(4)) }) ?? []
        // Word patterns matched at the start of a word; `*` is how that is said now.
        Check.that("every rule becomes exactly one condition, reading its pattern as it always did",
                   conditions.count == 2
                       && conditions[0] == ("Filing", "text", "invoice*, rechnung*", 0, true)
                       && conditions[1] == ("Labelling", "filename", "^inv-\\d+", 3, false),
                   "\(conditions)")

        let actions = (try? db.map("""
            SELECT r.name, a.kind, a.value FROM rules r JOIN rule_actions a ON a.rule_id = r.id
            ORDER BY r.id, a.position
            """) { ($0.string(0), $0.string(1), $0.string(2)) }) ?? []
        Check.that("…and every column it had filled in becomes an action, in order",
                   actions.map { "\($0.1)=\($0.2)" } == ["move_file=Finances/Invoices/{year}",
                                                          "add_tags=invoice, finances",
                                                          "set_correspondent=Acme",
                                                          "set_doc_type=Invoice"],
                   "\(actions)")
        Check.that("a rule with no destination is not given one",
                   !actions.contains { $0.0 == "Labelling" && $0.1 == "move_file" })
        let kept = (try? db.map("SELECT name, enabled, priority, match_all FROM rules ORDER BY id") {
            ($0.string(0), $0.bool(1), $0.int(2), $0.bool(3))
        }) ?? []
        Check.that("the rule itself is untouched, and joins its conditions with “any”",
                   kept.count == 2 && kept[0].1 && kept[0].2 == 100 && !kept[1].1
                       && kept.allSatisfy { !$0.3 })
        let entityPatterns = (try? db.map("SELECT match FROM entities ORDER BY id") { $0.string(0) }) ?? []
        Check.that("a correspondent's own words keep matching what they matched, and a phrase is left alone",
                   entityPatterns == ["stadtwerke*, swm*", "DE12 3456"], "\(entityPatterns)")
    }

    /// What conditions and actions as lists buy: joins, exclusions, and rules
    /// that label or rename without moving anything.
    private static func conditionsAndActions(store: Store, root: URL, text: String,
                                             findings: DocumentAnalyzer.Findings,
                                             payslip: DocumentRow) async {
        func decide(_ rule: Rule) -> Router.Decision {
            Router(rules: [rule], threshold: 0.5, derivedTemplate: "", root: root,
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
        // row back onto the list, say — indexes it in place. The document used
        // is one in the Inbox the rules would route, so a real import of it
        // would be moved.
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        let router = Router(rules: (try? await store.rules()) ?? [], threshold: routing.routingThreshold,
                            derivedTemplate: routing.derivedTemplate, root: root, deriveWhenNoRule: true)
        var routable: DocumentRow?
        for row in rows where row.directory == inbox.path {
            let text = (try? await store.ocrText(row.doc)) ?? ""
            let findings = DocumentAnalyzer.analyze(url: row.url, text: text, fallbackDate: row.createdAt,
                                                    knownCorrespondents: [])
            if router.evaluate(text: text, filename: row.filename, findings: findings, insight: nil,
                               currentDirectory: inbox).shouldMove {
                routable = row
                break
            }
        }
        if let invoice = routable {
            let hash = FileScanner.hash(invoice.url)
            let result = await indexer.importFiles([invoice.url], into: inbox, route: true)
            let stillThere = fm.fileExists(atPath: invoice.path) && FileScanner.hash(invoice.url) == hash
            let path = try? await store.documentPath(invoice.doc)
            Check.that("importing a file already in the library neither moves nor rewrites it",
                       stillThere && path == invoice.path && result.alreadyInLibrary == 1 && result.imported == 0,
                       path ?? "gone")
        } else {
            Check.that("the fixtures have a document in the Inbox the rules would route", false)
        }

        // A document no existing rule matches, so only the test rules below
        // decide where its copies go.
        let existing = ((try? await store.rules()) ?? []).filter(\.enabled)
        var neutral: DocumentRow?
        for row in rows where row.ext == "pdf" {
            let text = (try? await store.ocrText(row.doc)) ?? ""
            let subject = Rule.Subject(text: text, filename: row.filename,
                                       correspondent: row.correspondent, docType: row.docType)
            let hit = existing.contains { $0.matches(subject) }
            if !hit { neutral = row; break }
        }

        // Test rules, first in line, keyed to filenames nothing else has.
        let outside = fm.temporaryDirectory.appendingPathComponent("doctopus-escape-\(UUID().uuidString)",
                                                                    isDirectory: true)
        func filingRule(_ name: String, _ pattern: String, _ folder: String,
                        priority: Int64) -> Rule {
            Rule(id: 0, name: name, priority: priority,
                 conditions: [RuleCondition(field: .filename, pattern: pattern)],
                 actions: [RuleAction(kind: .moveFile, value: folder)])
        }
        let testRules = [
            filingRule("Clear", "doctopus-clear", "Filed/Clear", priority: 1000),
            filingRule("Tie A", "doctopus-tie", "Filed/A", priority: 999),
            filingRule("Tie B", "doctopus-tie", "Filed/B", priority: 998),
            filingRule("Escape", "doctopus-escape", outside.path, priority: 997),
            Rule(id: 0, name: "Rename", priority: 996,
                 conditions: [RuleCondition(field: .filename, pattern: "doctopus-rename")],
                 actions: [RuleAction(kind: .moveFile, value: "Filed/Renamed"),
                           RuleAction(kind: .renameFile, value: "renamed-{original}")]),
        ]
        var ruleIDs: [Int64] = []
        for rule in testRules { if let id = try? await store.upsertRule(rule) { ruleIDs.append(id) } }

        /// A copy of a fixture from outside the library, under a chosen name.
        func stage(_ name: String) -> URL? {
            guard let sample = neutral, var data = try? Data(contentsOf: sample.url) else { return nil }
            data.append(Data("\n% unique-\(UUID().uuidString)\n".utf8))
            let url = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name).pdf")
            return (try? data.write(to: url)) != nil ? url : nil
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
            let waiting = ((try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                           sort: .added, ascending: false)) ?? [])
                .contains { $0.id == row?.id }
            Check.that("…and still waits in Needs Review for a look at what was read", waiting)
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

        // 6b. A rule that renames names the new file, and moves it under that name.
        if let named = stage("doctopus-rename") {
            await indexer.importFiles([named], into: inbox, route: true)
            let row = await imported("doctopus-rename")
            print("  rename and move    → \(row.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") } ?? "nowhere")")
            Check.that("a new document is renamed and moved by the rule that matched it",
                       row?.filename.hasPrefix("renamed-") == true
                           && row?.filename.hasSuffix("doctopus-rename.pdf") == true
                           && row?.directory == root.appendingPathComponent("Filed/Renamed").path,
                       row?.path ?? "nowhere")
            Check.that("…and the file it was copied from keeps its name", fm.fileExists(atPath: named.path))
            try? fm.removeItem(at: named)

            let again = Rule(id: 0, name: "Again",
                             conditions: [RuleCondition(field: .filename, pattern: "*doctopus-rename")],
                             actions: [RuleAction(kind: .renameFile, value: "again-{original}")])
            let applied = (try? await store.applyRuleToExisting(again)) ?? Store.RuleApplyResult()
            let after = await imported("doctopus-rename")
            Check.that("applying a rule to existing documents renames them in place",
                       applied.renamed == 1 && after?.filename.hasPrefix("again-renamed-") == true
                           && after.map { fm.fileExists(atPath: $0.path) } == true
                           && after?.directory == row?.directory,
                       after?.path ?? "nowhere")
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

        // 9. Pruning an emptied folder never takes a hidden file with it.
        // `removeItem` is recursive, so a folder still holding a dot-file is
        // not empty however little the Finder shows in it.
        let keepDir = root.appendingPathComponent("Work/prune-check", isDirectory: true)
        try? fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
        let hidden = keepDir.appendingPathComponent(".notes.md")
        try? Data("not the pruner's to delete".utf8).write(to: hidden)
        FileScanner.pruneEmptyDirectories(startingFrom: keepDir, upTo: root)
        Check.that("pruning leaves a folder that still holds a hidden file",
                   fm.fileExists(atPath: hidden.path))
        try? fm.removeItem(at: keepDir)

        // …and one holding nothing but a .DS_Store really does go.
        let goneDir = root.appendingPathComponent("Work/prune-empty", isDirectory: true)
        try? fm.createDirectory(at: goneDir, withIntermediateDirectories: true)
        try? Data().write(to: goneDir.appendingPathComponent(".DS_Store"))
        FileScanner.pruneEmptyDirectories(startingFrom: goneDir, upTo: root)
        Check.that("…and prunes one holding nothing but a .DS_Store",
                   !fm.fileExists(atPath: goneDir.path))

        print("\nHALF-TYPED SEARCHES")
        // FTS5 rejects a dangling operator outright, and the throw would blank
        // the whole list — so every state the field passes through on the way
        // to a real query has to stay runnable.
        for partial in ["rechnung and", "and", "not", "or kontoauszug", "(rechnung or",
                        "rechnung )", "(", "rechnung and or kontoauszug"] {
            let hits = try? await store.listDocuments(selection: .all, query: SearchQuery(partial),
                                                      sort: .added, ascending: false)
            Check.that("“\(partial)” is still a query the list can run", hits != nil,
                       SearchQuery(partial).ftsExpression ?? "no expression")
        }

        print("\nMETADATA SOURCE")
        // The string carries a prompt version, and may carry a model name with
        // colons of its own (`llama3:8b`), so it is never matched whole.
        Check.that("an on-device analysis is labelled as one",
                   MetadataSource("llm:v\(LLMPrompt.promptVersion)").label == "On-device model")
        Check.that("an API analysis is labelled as one, whatever its version",
                   MetadataSource("remote:v9").label == "API model")
        Check.that("a model name is read back out of the source",
                   MetadataSource("remote:llama3:8b:v2").model == "llama3:8b")
        Check.that("a source with no model names none",
                   MetadataSource("remote:v2").model == nil)
        Check.that("anything else is heuristics",
                   MetadataSource("heuristic").label == "Heuristics")

        print("\nCONTINUOUS SCANNING")
        // The device half cannot be checked without a device (`--scantest
        // loop` is for that), but the bookkeeping around it can: what the
        // counter says, and which interruptions a run comes back from by
        // itself.
        var session = ScanSession(device: "iPhone", action: "Scan Documents", destination: nil)
        Check.that("a run starts with nothing scanned, and running",
                   session.count == 0 && session.isRunning, session.label)
        session.received(1)
        session.received(1)
        Check.that("each capture counts the documents it carried",
                   session.count == 2, session.label)
        session.suspend(.lostFocus)
        Check.that("losing focus pauses the run and keeps the count",
                   !session.isRunning && session.count == 2, session.label)
        session.received(1)
        Check.that("a capture that lands after focus went is still filed, and the run stays paused",
                   session.count == 3 && !session.isRunning)
        session.resume()
        Check.that("resuming carries on from the count it had",
                   session.isRunning && session.count == 3)
        session.suspend(.timedOut)
        session.received(1)
        Check.that("a capture that arrives late un-pauses a run that had given up on it",
                   session.isRunning && session.count == 4, session.label)
        session.suspend(.deviceGone)
        Check.that("a device that left says so rather than just “paused”",
                   session.paused?.summary == "Device gone", session.label)

        print("\nFOLDER DROPS")
        Check.that("a drag with nothing held files the document in a second place",
                   FolderDropIntent.reading([]) == .alias)
        Check.that("⌘ moves the master file instead",
                   FolderDropIntent.reading([.command]) == .move)
        Check.that("⌘ still means move with other keys alongside it",
                   FolderDropIntent.reading([.command, .shift]) == .move)
        Check.that("⌥ on its own is not a move",
                   FolderDropIntent.reading([.option]) == .alias)
        func movesInto(_ intent: FolderDropIntent, _ folder: String) -> Bool {
            if case .move(let target) = intent.action(on: folder) { return target == folder }
            return false
        }
        Check.that("the intent carries the folder the drag was read over",
                   movesInto(.move, "/Documents/Taxes") && !movesInto(.alias, "/Documents/Taxes"))
        Check.that("the row says which of the two it would be",
                   FolderDropIntent.alias.label == "File Here"
                       && FolderDropIntent.move.label == "Move Here")

        for id in ruleIDs { try? await store.deleteRule(id) }
        await indexer.update(settings: settings)
    }

    private static func findNode(path: String, in nodes: [FolderNode]) -> FolderNode? {
        for node in nodes {
            if node.path == path { return node }
            if let hit = findNode(path: path, in: node.children) { return hit }
        }
        return nil
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
