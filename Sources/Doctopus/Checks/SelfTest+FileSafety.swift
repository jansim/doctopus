import Foundation

/// The file safety rules, driven through real imports.
extension SelfTest {
    /// Doctopus may only ever move or rewrite a file it just brought in itself,
    /// and only when nobody said where it should go. Everything else — files
    /// already in the library, imports into a chosen folder, the user's own
    /// aliases — it must leave exactly as it found them.
    static func fileSafety(store: Store, indexer: Indexer, settings: AppSettings) async {
        print("\nFILE SAFETY")
        let root = store.root
        let fm = FileManager.default
        var routing = settings
        routing.autoRouteImports = true
        routing.deriveWhenNoRule = true
        routing.optimizeOnImport = true
        await indexer.update(settings: routing)

        func snapshot() -> [String: String] {
            var out: [String: String] = [:]
            for f in FileScanner.scan(root: root).found { out[f.url.path] = FileScanner.hash(f.url) ?? "" }
            return out
        }

        let before = snapshot()
        let ids = (try? await store.allDocumentIDs()) ?? []
        await indexer.reprocess(ids: ids)
        await indexer.indexAll()
        let after = snapshot()
        Check.that("reprocessing leaves every file where it was, byte for byte",
                   before == after, "\(before.count) before, \(after.count) after")

        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        await alreadyInLibrary(store: store, indexer: indexer, routing: routing, inbox: inbox, rows: rows)

        let existing = ((try? await store.rules()) ?? []).filter(\.enabled)
        var neutral: DocumentRow?
        for row in rows where row.ext == "pdf" {
            let text = (try? await store.ocrText(row.doc)) ?? ""
            let subject = Rule.Subject(text: text, filename: row.filename,
                                       correspondent: row.correspondent, docType: row.docType)
            let hit = existing.contains { $0.matches(subject) }
            if !hit { neutral = row; break }
        }

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

        let arrival = Arrival(store: store, neutral: neutral)

        await clearMatch(store: store, indexer: indexer, inbox: inbox, arrival: arrival)
        await chosenFolder(store: store, indexer: indexer, inbox: inbox, arrival: arrival)
        await foundInLibrary(store: store, indexer: indexer, inbox: inbox, arrival: arrival)
        await twoEqualHomes(store: store, indexer: indexer, inbox: inbox, arrival: arrival)
        await routingStaysInside(store: store, indexer: indexer, inbox: inbox, arrival: arrival,
                                 outside: outside)
        await renamedByRule(store: store, indexer: indexer, inbox: inbox, arrival: arrival)
        await usersOwnFiles(store: store, indexer: indexer, rows: rows)

        for id in ruleIDs { try? await store.deleteRule(id) }
        await indexer.update(settings: settings)
    }

    private static func alreadyInLibrary(store: Store, indexer: Indexer, routing: AppSettings,
                                         inbox: URL, rows: [DocumentRow]) async {
        let root = store.root
        let fm = FileManager.default
        let router = Router(rules: (try? await store.rules()) ?? [],
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
    }

    /// Import fixtures copied from a document no rule matches.
    private struct Arrival {
        let store: Store
        let neutral: DocumentRow?

        func stage(_ name: String) -> URL? {
            let fm = FileManager.default
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
    }

    private static func clearMatch(store: Store, indexer: Indexer, inbox: URL, arrival: Arrival) async {
        let root = store.root
        let fm = FileManager.default
        if let clear = arrival.stage("doctopus-clear") {
            await indexer.importFiles([clear], into: inbox, route: true)
            let row = await arrival.imported("doctopus-clear")
            print("  clear match        → \(row?.directory.replacingOccurrences(of: root.path + "/", with: "") ?? "nowhere")")
            Check.that("a new document with one clear home is filed there",
                       row?.directory == root.appendingPathComponent("Filed/Clear").path)
            Check.that("…and the file it was copied from is left alone", fm.fileExists(atPath: clear.path))
            let waiting = ((try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                           sort: .added, ascending: false)) ?? [])
                .contains { $0.id == row?.id }
            Check.that("…and still waits in Needs Review for a look at what was read", waiting)
            var fromOutside = false
            if let row { fromOutside = (try? await store.detail(row.doc))?.row.fromOutside == true }
            Check.that("…as a new arrival, not one found in the library", fromOutside)
            try? fm.removeItem(at: clear)
        }
    }

    private static func chosenFolder(store: Store, indexer: Indexer, inbox: URL, arrival: Arrival) async {
        let root = store.root
        let fm = FileManager.default
        if let chosen = arrival.stage("doctopus-clear-chosen") {
            let folder = root.appendingPathComponent("Work", isDirectory: true)
            await indexer.importFiles([chosen], into: folder, route: false)
            let row = await arrival.imported("doctopus-clear-chosen")
            Check.that("an import into a chosen folder is never routed away",
                       row?.directory == folder.path, row?.directory ?? "nowhere")
            var offered: [PathSuggestion] = []
            if let row { offered = (try? await store.pathSuggestions(for: row.doc)) ?? [] }
            Check.that("…but is still offered the folder the rules would pick",
                       offered.map(\.path).contains(root.appendingPathComponent("Filed/Clear").path))
            Check.that("…after the folder that was chosen, so the review keeps it there",
                       offered.first?.path == folder.path, offered.first?.path ?? "no suggestions")
            try? fm.removeItem(at: chosen)
        }
    }

    private static func foundInLibrary(store: Store, indexer: Indexer, inbox: URL, arrival: Arrival) async {
        let root = store.root
        let fm = FileManager.default
        if let staged = arrival.stage("doctopus-clear-found") {
            let placed = inbox.appendingPathComponent(staged.lastPathComponent)
            try? fm.moveItem(at: staged, to: placed)
            let hash = FileScanner.hash(placed)
            await indexer.importFiles([placed], into: inbox, route: true)
            let row = await arrival.imported("doctopus-clear-found")
            var offered: [PathSuggestion] = []
            if let row { offered = (try? await store.pathSuggestions(for: row.doc)) ?? [] }
            let waiting = ((try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                           sort: .added, ascending: false)) ?? [])
                .contains { $0.id == row?.id }
            Check.that("a new file found in the library stays where it is, byte for byte",
                       row?.path == placed.path && FileScanner.hash(placed) == hash,
                       row?.path ?? "nowhere")
            Check.that("…is offered the folder the rules would pick",
                       offered.map(\.path).contains(root.appendingPathComponent("Filed/Clear").path))
            Check.that("…and waits in Needs Review", waiting)
            Check.that("…without being optimized", row?.originalSize == nil)
            let listed = ((try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? [])
                .first { $0.id == row?.id }
            Check.that("…and is marked as already in the library", listed?.fromOutside == false)
        }
    }

    private static func twoEqualHomes(store: Store, indexer: Indexer, inbox: URL, arrival: Arrival) async {
        let root = store.root
        let fm = FileManager.default
        if let tie = arrival.stage("doctopus-tie") {
            await indexer.importFiles([tie], into: inbox, route: true)
            let row = await arrival.imported("doctopus-tie")
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
            let listed = ((try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? [])
                .first { $0.id == row?.id }
            Check.that("…marked as a new arrival", listed?.fromOutside == true)
            if let row, let detail = try? await store.detail(row.doc) {
                Check.that("…whose review starts on a suggested home",
                           detail.defaultFolder != inbox.path, detail.defaultFolder)
                let picked = root.appendingPathComponent("Filed/B", isDirectory: true)
                _ = await indexer.move(ids: [row.doc], to: picked)
                let moved = try? await store.detail(row.doc)
                Check.that("…but once moved by hand, starts where it was put",
                           moved?.row.fromOutside == true && moved?.defaultFolder == picked.path,
                           moved?.defaultFolder ?? "no detail")
                _ = await indexer.move(ids: [row.doc], to: inbox)
                let back = try? await store.detail(row.doc)
                Check.that("…and back in the Inbox, starts on a suggestion again",
                           back?.defaultFolder != inbox.path, back?.defaultFolder ?? "no detail")
            }
            if let row {
                // Approved, it is in the library; anything later is about a document already there.
                try? await store.setDocumentApproved(row.doc, true)
                try? await store.logProcessing(docID: row.doc, action: .optimized, detail: nil, rule: nil,
                                               from: nil, to: nil, approved: false)
                let again = ((try? await store.listDocuments(selection: .needsReview, query: SearchQuery(""),
                                                             sort: .added, ascending: false)) ?? [])
                    .first { $0.id == row.id }
                Check.that("…and once approved, back in review as one already in the library",
                           again != nil && again?.fromOutside == false)
            }
            try? fm.removeItem(at: tie)
        }
    }

    private static func routingStaysInside(store: Store, indexer: Indexer, inbox: URL, arrival: Arrival,
                                           outside: URL) async {
        let root = store.root
        let fm = FileManager.default
        if let escape = arrival.stage("doctopus-escape") {
            await indexer.importFiles([escape], into: inbox, route: true)
            let row = await arrival.imported("doctopus-escape")
            let inside = row.map { $0.directory == root.path || $0.directory.hasPrefix(root.path + "/") } ?? false
            Check.that("routing never moves a file outside its library",
                       inside && !fm.fileExists(atPath: outside.path), row?.directory ?? "nowhere")
            try? fm.removeItem(at: escape)
        }
    }

    private static func renamedByRule(store: Store, indexer: Indexer, inbox: URL, arrival: Arrival) async {
        let root = store.root
        let fm = FileManager.default
        if let named = arrival.stage("doctopus-rename") {
            await indexer.importFiles([named], into: inbox, route: true)
            let row = await arrival.imported("doctopus-rename")
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
            let applied = await indexer.applyRule(again)
            let after = await arrival.imported("doctopus-rename")
            Check.that("applying a rule to existing documents renames them in place",
                       applied.renamed == 1 && after?.filename.hasPrefix("again-renamed-") == true
                           && after.map { fm.fileExists(atPath: $0.path) } == true
                           && after?.directory == row?.directory,
                       after?.path ?? "nowhere")
        }
    }

    private static func usersOwnFiles(store: Store, indexer: Indexer, rows: [DocumentRow]) async {
        let root = store.root
        let fm = FileManager.default
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

        let impostor = root.appendingPathComponent("Work/not-an-alias.txt")
        try? Data("the user's own file".utf8).write(to: impostor)
        let removed = AliasManager.removeAlias(at: impostor.path)
        Check.that("removing an alias never deletes a real file in its place",
                   !removed && fm.fileExists(atPath: impostor.path))
        try? fm.removeItem(at: impostor)

        let keepDir = root.appendingPathComponent("Work/prune-check", isDirectory: true)
        try? fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
        let hidden = keepDir.appendingPathComponent(".notes.md")
        try? Data("not the pruner's to delete".utf8).write(to: hidden)
        FileScanner.pruneEmptyDirectories(startingFrom: keepDir, upTo: root)
        Check.that("pruning leaves a folder that still holds a hidden file",
                   fm.fileExists(atPath: hidden.path))
        try? fm.removeItem(at: keepDir)

        let goneDir = root.appendingPathComponent("Work/prune-empty", isDirectory: true)
        try? fm.createDirectory(at: goneDir, withIntermediateDirectories: true)
        try? Data().write(to: goneDir.appendingPathComponent(".DS_Store"))
        FileScanner.pruneEmptyDirectories(startingFrom: goneDir, upTo: root)
        Check.that("…and prunes one holding nothing but a .DS_Store",
                   !fm.fileExists(atPath: goneDir.path))
    }
}
