import Foundation

/// How far a library holds its filenames to its naming template, level by
/// level: what is pointed out, what is suppressed, and which names follow a
/// change to a document's fields.
extension SelfTest {
    static func filenameEnforcement(store: Store) async {
        print("\nFILENAME ENFORCEMENT")
        let fm = FileManager.default
        let template = "{title}"

        func indexer(_ level: Naming.Enforcement, template: String = template) -> Indexer {
            var settings = AppSettings()
            settings.llmBackend = .off
            settings.namingTemplate = template
            settings.namingEnforcement = level
            return Indexer(store: store, intelligence: Intelligence(), settings: settings,
                           onProgress: { _ in }, onDataChanged: {})
        }

        Check.that("a number added to avoid a clash still counts as the template's name",
                   Naming.isRendering("A 2.pdf", of: "A.pdf") && Naming.isRendering("A_12.pdf", of: "A.pdf")
                       && !Naming.isRendering("A copy.pdf", of: "A.pdf")
                       && !Naming.isRendering("A 2.png", of: "A.pdf"))

        _ = try? await store.ruleMatches()
        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        var subject: DocumentRow?
        for row in rows where row.ext == "pdf" && fm.fileExists(atPath: row.path)
            && !row.filename.contains("doctopus-") {
            if (try? await store.isRuleRenamed(row.doc)) == false { subject = row; break }
        }
        guard let doc = subject else {
            Check.that("a document to check naming with", false)
            return
        }
        let id = doc.doc
        let ext = doc.url.pathExtension
        let mark = (try? await store.latestEventID()) ?? 0

        func name() async -> String {
            (try? await store.documentPath(id)).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        }
        func setTitle(_ title: String?) async {
            try? await store.overwriteMetadataField(id, column: "title", value: title)
        }
        func mismatch() async -> NamingMismatch? {
            ((try? await store.namingMismatches(template: template, options: Naming.Options())) ?? [:])[id]
        }
        func autoNamed() async -> Bool {
            (try? await store.namingState(id))?.autoNamed == true
        }
        func follow(_ level: Naming.Enforcement) async -> String {
            _ = await indexer(level).followNaming([id])
            return await name()
        }

        await setTitle("Naming Check A")
        let pointed = await mismatch()
        Check.that("a name the template would not give is pointed out, with the one it would",
                   pointed?.expected == "Naming Check A.\(ext)" && pointed?.isPending == true,
                   pointed?.expected ?? "not pointed out")

        try? await store.setNamingSuppressed(true, doc: id)
        let suppressed = await mismatch()
        Check.that("a suppressed name is still listed, but no longer pending",
                   suppressed?.suppressed == true && suppressed?.isPending == false)
        let keptWhenSuppressed = await follow(.automatic)
        Check.that("renaming automatically leaves a suppressed name alone",
                   keptWhenSuppressed == doc.filename, keptWhenSuppressed)
        try? await store.setNamingSuppressed(false, doc: id)
        let handedBack = await mismatch()
        Check.that("a suppressed name can be handed back to the template", handedBack?.isPending == true)

        let keptManual = await follow(.manual)
        let keptHighlight = await follow(.highlight)
        Check.that("renaming only when asked, or only pointing names out, renames nothing",
                   keptManual == doc.filename && keptHighlight == doc.filename, keptHighlight)

        let untouched = await follow(.followTemplateNames)
        let wasAutoNamed = await autoNamed()
        Check.that("a name the template never gave is left alone when following template names",
                   untouched == doc.filename && !wasAutoNamed, untouched)

        _ = await indexer(.followTemplateNames).rename(ids: [id], template: template)
        let renamed = await name()
        let recorded = await autoNamed()
        let settled = await mismatch()
        Check.that("renaming by the library's template records the name as the template's",
                   renamed == "Naming Check A.\(ext)" && recorded && settled == nil, renamed)

        await setTitle("Naming Check B")
        let followed = await follow(.followTemplateNames)
        let stillAutoNamed = await autoNamed()
        Check.that("a name the template gave follows a change to the document's fields",
                   followed == "Naming Check B.\(ext)" && stillAutoNamed, followed)

        _ = await indexer(.followTemplateNames).rename(ids: [id], template: "Typed By Hand")
        let typedAutoNamed = await autoNamed()
        await setTitle("Naming Check C")
        let typed = await follow(.followTemplateNames)
        Check.that("a name given by hand is never renamed when following template names",
                   typed == "Typed By Hand.\(ext)" && !typedAutoNamed, typed)

        let automatic = await follow(.automatic)
        let automaticRecorded = await autoNamed()
        Check.that("renaming automatically brings any name in line when the fields change",
                   automatic == "Naming Check C.\(ext)" && automaticRecorded, automatic)

        let ruled = Rule(id: 0, name: "Naming Check Rule", priority: 995,
                         conditions: [RuleCondition(field: .filename, pattern: "naming check c", mode: .exactPhrase)],
                         actions: [RuleAction(kind: .renameFile, value: "ruled-{original}")])
        if let ruleID = try? await store.upsertRule(ruled) {
            _ = try? await store.ruleMatches()
            await setTitle("Naming Check D")
            let ruleMismatch = await mismatch()
            let ruleKept = await follow(.automatic)
            Check.that("a document a rule renames is left to the rule",
                       ruleMismatch == nil && ruleKept == "Naming Check C.\(ext)", ruleKept)
            try? await store.deleteRule(ruleID)
            _ = try? await store.ruleMatches()
        } else {
            Check.that("a rule to check naming against is saved", false)
        }

        await indexer(.automatic).undo([id], since: mark)
        let restored = await name()
        let restoredAutoNamed = await autoNamed()
        Check.that("Undo takes every rename back to the name the file had",
                   restored == doc.filename && !restoredAutoNamed, restored)
        await setTitle(doc.title)

        guard let bytes = try? Data(contentsOf: doc.url) else { return }
        var unique = bytes
        unique.append(Data("\n% unique-\(UUID().uuidString)\n".utf8))
        let staged = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-naming.pdf")
        guard (try? unique.write(to: staged)) != nil else { return }
        defer { try? fm.removeItem(at: staged) }
        let arriving = indexer(.automatic, template: "doctopus-named-{original}")
        await arriving.importFiles([staged], into: store.root.appendingPathComponent("Inbox"), route: true)
        let arrived = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                       sort: .added, ascending: false)) ?? [])
            .first { $0.filename.hasPrefix("doctopus-named-") }
        var arrivedAutoNamed = false
        if let arrived { arrivedAutoNamed = (try? await store.namingState(arrived.doc))?.autoNamed == true }
        Check.that("a new arrival is named by the template when renaming automatically",
                   arrived != nil && arrivedAutoNamed, arrived?.filename ?? "not imported")
    }
}
