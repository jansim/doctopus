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

        await overview(store: store, rows: rows, stats: stats)
        await search(store: store)
        await folderTree(store: store, root: root, rows: rows, stats: stats)
        refiledRules(store: store)
        renamePreview(rows: rows)
        await routing(store: store, settings: settings, root: root, rows: rows)
        ruleMigration()
        noteMigration()
        await ruleEditing(store: store, indexer: indexer, settings: settings, root: root, rows: rows,
                          stats: stats)
        let fields = await fieldValues(store: store, rows: rows)
        await savedViews(store: store)
        await renameAndMerge(store: store, rows: rows, fields: fields)
        await finderTags(store: store, rows: rows)
        await valueIcons(store: store, fields: fields)
        await tagMerge(store: store, rows: rows)
        await aliasInAFolder(store: store, rows: rows)
        await promotedAlias(store: store, indexer: indexer, rows: rows)
        await undoneAlias(store: store, indexer: indexer, rows: rows)
        await recentlyReviewed(store: store)
        await recentlyReviewedPeriods(store: store)
        await queue(store: store)
        await importAFile(store: store, indexer: indexer, settings: settings, root: root, rows: rows)
        await importAFolder(store: store, indexer: indexer, root: root, rows: rows)
        await fileSafety(store: store, indexer: indexer, settings: settings)
        await halfTypedSearches(store: store)
        metadataSource()
        scanCaptures()
        continuousScanning()
        continuousScanEnds()
        folderDrops()
        endpoints()
        await replies(indexer: indexer, settings: settings, rows: rows)
        prompts()
        await pageImages(store: store)
        await liveModel(store: store, indexer: indexer, intelligence: intelligence, settings: settings,
                        rows: rows)
        await shortcuts(store: store)
        await entities(store: store, rows: rows)
        await matchModes(store: store)
        await nestedTags(store: store, rows: rows)
        await dates(store: store, rows: rows)
        await revertibleOptimisation(store: store, indexer: indexer, rows: rows)
        await typedFields(store: store, rows: rows)
        await notes(store: store, rows: rows)
        await recentlyDeleted(store: store, rows: rows)
        await history(store: store, indexer: indexer, root: root, rows: rows)
        await localClassifier()
        await searchIndex(store: store, rows: rows)
        libraryFormat(container: container)
        await verification(store: store)
        await contentHashes(store: store, rows: rows)
        await fileIDs(store: store, indexer: indexer)

        await filingExamples(store: store, rows: rows)
        await failuresAreSaid(store: store, indexer: indexer)
        await unreadableFolders(store: store)
        await droppedEvents(store: store)
        await oneWriterAtATime()
        if let template = rows.first(where: { $0.ext == "pdf" && FileManager.default.fileExists(atPath: $0.path) }) {
            await indexBackups(template: template.url)
        }
        if let scanned = rows.first(where: { $0.filename == "scan 003.pdf" && FileManager.default.fileExists(atPath: $0.path) }) {
            await passwordProtectedPDFs(store: store, scanned: scanned.url)
        }
        await filenameEnforcement(store: store)

        Check.finish("pipeline self-test")
    }

    private static func overview(store: Store, rows: [DocumentRow], stats: Store.Stats) async {
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
        let typed = rows.filter { $0.docType != nil }.count
        Check.that("most documents get a type",
                   Double(typed) >= Double(rows.count) * 0.8, "\(typed)/\(rows.count)")
        Check.that("both text paths exercised", sources.contains("pdf-layer") && sources.contains("vision"),
                   sources.sorted().joined(separator: ", "))

        print("\nDOCUMENTS")
        for row in rows {
            guard let detail = try? await store.detail(row.doc) else { continue }
            print("  \(row.filename)")
            print("    title:  \(row.title ?? "—")")
            print("    from:   \(row.correspondent ?? "—")   type: \(row.docType ?? "—")   lang: \(row.language ?? "—")")
            print("    date:   \(row.docDate.map(DayDate.text) ?? "—") (\(detail.dateSource ?? "—"))")
            print("    ocr:    \(detail.ocrWords ?? 0) words via \(detail.ocrSource ?? "—")")
            if let amount = detail.amount { print("    amount: \(amount)") }
            if let summary = row.summary { print("    summary: \(summary)") }
            if !detail.tags.isEmpty { print("    tags:   \(detail.tags.map(\.name).joined(separator: ", "))") }
        }
    }

    private static func folderTree(store: Store, root: URL, rows: [DocumentRow], stats: Store.Stats) async {
        print("\nFOLDER TREE")
        let tree = (try? await store.folderTree()) ?? []
        Check.that("folder tree built", !tree.isEmpty && tree[0].deepCount == stats.total)
        printTree(tree, depth: 0)

        let emptyFolder = root.appendingPathComponent("Empty Subfolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        let treeWithEmptyFolder = (try? await store.folderTree()) ?? []
        let emptyFolderPath = store.absPath(store.relPath(emptyFolder.path))
        Check.that("an empty folder on disk still shows in the tree",
                   findNode(path: emptyFolderPath, in: treeWithEmptyFolder)?.count == 0)

        let tagsMirror = root.appendingPathComponent("Tags", isDirectory: true)
            .appendingPathComponent("Some Tag", isDirectory: true)
        try? FileManager.default.createDirectory(at: tagsMirror, withIntermediateDirectories: true)
        let treeWithTagsMirror = (try? await store.folderTree()) ?? []
        let tagsMirrorPath = store.absPath(store.relPath(tagsMirror.path))
        Check.that("the Tags/ mirror is not promoted into the folder tree",
                   findNode(path: tagsMirrorPath, in: treeWithTagsMirror) == nil)

        if let sample = rows.first(where: { store.relPath($0.path).contains("/") }) {
            let folder = (sample.path as NSString).deletingLastPathComponent
            let renamed = folder + " Renamed"
            try? await store.moveFolder(from: folder, to: renamed)
            try? FileManager.default.moveItem(atPath: folder, toPath: renamed)
            let followed = try? await store.documentPath(sample.doc)
            let name = (sample.path as NSString).lastPathComponent
            let movedFile = renamed + "/" + name
            var rescan: (id: Int64, isNew: Bool, changed: Bool)?
            if let f = FileScanner.scan(root: URL(fileURLWithPath: renamed)).found.first(where: { $0.url.lastPathComponent == name }) {
                rescan = try? await store.upsertDocument(
                    Store.FileFacts(path: f.url.path, size: f.size, mtime: f.mtime, created: f.created,
                                    fileID: f.fileID), origin: .inLibrary)
            }
            Check.that("a renamed folder takes its documents' index entries along",
                       followed == movedFile && rescan?.isNew == false, followed ?? "gone")
            try? await store.moveFolder(from: renamed, to: folder)
            try? FileManager.default.moveItem(atPath: renamed, toPath: folder)
        }
    }

    /// Failures that used to pass for success. Each is forced here, and what
    /// is checked is that it is said, and that nothing changed on the way.
    private static func failuresAreSaid(store: Store, indexer: Indexer) async {
        print("\nFAILURES ARE SAID")
        let fm = FileManager.default
        let root = store.root
        let rows = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                    sort: .added, ascending: false)) ?? [])
            .filter { $0.ext == "pdf" && fm.fileExists(atPath: $0.path) }
        guard rows.count >= 2 else {
            Check.that("the fixtures have two PDFs to fail with", false)
            return
        }
        let (subject, mover) = (rows[0], rows[1])

        // A file where the originals folder should be: the copy cannot be made.
        let originals = await store.originalsDirectory
        let aside = originals.deletingLastPathComponent().appendingPathComponent("originals-aside")
        let hadOriginals = fm.fileExists(atPath: originals.path)
        if hadOriginals { try? fm.moveItem(at: originals, to: aside) }
        fm.createFile(atPath: originals.path, contents: Data())
        let hashBefore = FileScanner.hash(subject.url)
        let optimized = await indexer.optimize(ids: [subject.doc])
        try? fm.removeItem(at: originals)
        if hadOriginals { try? fm.moveItem(at: aside, to: originals) }
        print("  optimize, no originals  \(optimized.failures.first ?? "no reason given")")
        Check.that("an optimization whose original cannot be kept is refused, with a reason",
                   optimized.count == 0 && optimized.failures.count == 1)
        Check.that("…and leaves the file as it was",
                   hashBefore != nil && FileScanner.hash(subject.url) == hashBefore)

        Check.that("a Trash that cannot be listed is not taken for an empty one",
                   Store.filenames(in: root.appendingPathComponent("No Such Folder \(UUID().uuidString)")) == nil)

        // A forgotten row still holding the path the move would land on.
        let away = root.appendingPathComponent("Unrecorded", isDirectory: true)
        let clash = away.appendingPathComponent(mover.filename)
        let stale = try? await store.upsertDocument(
            Store.FileFacts(path: clash.path, size: 1, mtime: Date(), created: Date()), origin: .inLibrary)
        try? await store.markMissing(path: clash.path)
        let moved = await indexer.move(ids: [mover.doc], to: away)
        let stillAt = (try? await store.documentPath(mover.doc)) ?? ""
        print("  move, unrecordable      \(moved.failures.first ?? "no reason given")")
        Check.that("a move the index cannot record is taken back, with a reason",
                   stale != nil && moved.done == 0 && moved.failures.count == 1)
        Check.that("…so the file is where its row says it is",
                   stillAt == mover.path && fm.fileExists(atPath: mover.path) && !fm.fileExists(atPath: clash.path))
        if let stale { try? await store.deleteDocument(stale.id) }
        try? fm.removeItem(at: away)

        // A home folder that cannot be written to: the document cannot leave it.
        let home = subject.url.deletingLastPathComponent()
        let elsewhere = root.appendingPathComponent("Also Filed", isDirectory: true)
        if let alias = try? AliasManager.createAlias(to: subject.url, in: elsewhere) {
            try? await store.recordAlias(docID: subject.doc, tagID: nil, path: alias.path)
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
            var refusal: String?
            do { _ = try await indexer.promoteClosestAlias(docID: subject.doc) }
            catch { refusal = error.localizedDescription }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            let placements = ((try? await store.aliases(for: subject.doc)) ?? []).filter { $0.tagID == nil }
            let master = Store.canonical(subject.url.standardizedFileURL.path)
            let refiled = placements.contains { placement in
                guard let points = AliasManager.resolve(URL(fileURLWithPath: placement.path)) else { return false }
                return Store.canonical(points.standardizedFileURL.path) == master
            }
            print("  delete, cannot rehome   \(refusal ?? "went ahead")")
            Check.that("a document that cannot move into its other placement says so", refusal != nil)
            Check.that("…and stays where it was, still filed in the other folder",
                       fm.fileExists(atPath: subject.path) && refiled, "\(placements.count) placement(s)")
            for placement in placements {
                AliasManager.removeAlias(at: placement.path, pointingTo: subject.url)
                try? await store.deleteAlias(id: placement.id)
            }
            try? fm.removeItem(at: elsewhere)
        } else {
            Check.that("an alias can be made to fail a promotion with", false)
        }

        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let outside = fm.temporaryDirectory.appendingPathComponent("doctopus-unique-\(UUID().uuidString).pdf")
        var bytes = (try? Data(contentsOf: subject.url)) ?? Data()
        bytes.append(Data("\n% \(UUID().uuidString)\n".utf8))
        try? bytes.write(to: outside)
        let imported = await indexer.importFiles([outside], into: locked)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        print("  import, locked folder   \(imported.failures.first ?? "no reason given")")
        Check.that("an import that fails says why",
                   imported.failed == 1 && imported.failures.first?.contains(outside.lastPathComponent) == true)
        try? fm.removeItem(at: outside)
        try? fm.removeItem(at: locked)

        let broken = root.appendingPathComponent("Broken \(UUID().uuidString.prefix(8)).pdf")
        try? Data("not a PDF".utf8).write(to: broken)
        _ = await indexer.importFiles([broken], into: root)
        let brokenRow = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                         sort: .added, ascending: false)) ?? [])
            .first { $0.path == broken.path }
        if let brokenRow {
            let history = (try? await store.history(for: brokenRow.doc)) ?? []
            let said = history.first { $0.detail?.hasPrefix("Indexed with problems") == true }?.detail
            print("  unreadable file         \(said ?? "nothing said")")
            Check.that("a file whose text cannot be read says so in its history", said != nil)
            try? await store.deleteDocument(brokenRow.doc)
        } else {
            Check.that("an unreadable file is still indexed", false)
        }
        try? fm.removeItem(at: broken)

        let garbled = fm.temporaryDirectory
            .appendingPathComponent("doctopus-garbled-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.doctopus", isDirectory: true)
        let garbledMeta = garbled.appendingPathComponent("meta.json")
        try? fm.createDirectory(at: garbled, withIntermediateDirectories: true)
        try? Data("{ not json".utf8).write(to: garbledMeta)
        var refusedGarbled = false
        do { _ = try Store(directory: garbled) } catch Store.OpenError.unreadableMeta { refusedGarbled = true } catch {}
        Check.that("a library whose meta.json does not read is refused, not given a new identity",
                   refusedGarbled)
        Check.that("…and its meta.json is left as it was",
                   (try? String(contentsOf: garbledMeta, encoding: .utf8)) == "{ not json")
        try? fm.removeItem(at: garbled.deletingLastPathComponent())

        Check.that("settings that do not decode are told apart from none at all",
                   LibrarySettings.decodedIfReadable(from: Data("[1, 2".utf8)) == nil
                       && LibrarySettings.decodedIfReadable(from: Data()) != nil)
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

extension String {
    func padded(_ n: Int) -> String {
        count >= n ? String(prefix(n)) : self + String(repeating: " ", count: n - count)
    }
}
