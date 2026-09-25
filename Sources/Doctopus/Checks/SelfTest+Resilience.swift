import Foundation

/// What the pipeline does when the disk does not answer the way it should.
extension SelfTest {
    /// Collects what an indexer says went wrong, from whichever thread says it.
    final class Problems: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ text: String) { lock.withLock { said.append(text) } }
        var all: [String] { lock.withLock { said } }
    }

    static func indexer(for store: Store, problems: Problems) -> Indexer {
        var settings = AppSettings()
        settings.llmBackend = .off
        return Indexer(store: store, intelligence: Intelligence(), settings: settings,
                       onProgress: { _ in }, onDataChanged: {},
                       onProblem: { problems.add($0) })
    }

    /// Nil when the row is gone altogether. The document list leaves missing
    /// rows out, so a row that exists but is not listed is the missing one.
    static func isMissing(_ id: Int64, in store: Store) async -> Bool? {
        guard (try? await store.documentPath(id)) ?? nil != nil else { return nil }
        let listed = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                      sort: .added, ascending: false)) ?? [])
        return !listed.contains { $0.doc == id }
    }

    static func unreadableFolders(store: Store) async {
        print("\nUNREADABLE FOLDERS")
        let fm = FileManager.default
        let problems = Problems()
        let indexer = indexer(for: store, problems: problems)
        guard let subject = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                             sort: .added, ascending: false)) ?? [])
            .first(where: { $0.ext == "pdf" && !$0.missing && fm.fileExists(atPath: $0.path) })
        else {
            Check.that("the fixtures have a PDF to shut away", false)
            return
        }

        let shut = store.root.appendingPathComponent("Shut Away", isDirectory: true)
        try? fm.createDirectory(at: shut, withIntermediateDirectories: true)
        _ = await indexer.move(ids: [subject.doc], to: shut)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: shut.path)
        let scan = FileScanner.scan(root: store.root)
        await indexer.indexAll()
        let report = (try? await LibraryVerifier.verify(store: store)) ?? VerificationReport()
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shut.path)

        print("  scan                    \(scan.unreadable.map(\.lastPathComponent)) unreadable")
        Check.that("a folder that will not open is reported by the scan, not read as empty",
                   scan.couldNotSee(Store.canonical(shut.appendingPathComponent(subject.filename).path)))
        Check.that("a document in an unreadable folder is not marked missing",
                   await isMissing(subject.doc, in: store) == false)
        let said = problems.all.first { $0.contains("Shut Away") }
        print("  said                    \(said ?? "nothing")")
        Check.that("…and the unreadable folder is named to the user", said != nil)
        Check.that("verification reports the folder it could not look in",
                   report.issues.contains { $0.title == "Unreadable folder" })

        _ = await indexer.move(ids: [subject.doc], to: subject.url.deletingLastPathComponent())
        try? fm.removeItem(at: shut)

        await libraryThatLooksEmpty(template: subject.url)
    }

    /// A drive that dropped away mid-scan leaves a library that lists as empty.
    private static func libraryThatLooksEmpty(template: URL) async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("doctopus-empty-\(UUID().uuidString)", isDirectory: true)
        let aside = fm.temporaryDirectory.appendingPathComponent("doctopus-aside-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: aside) }
        let file = root.appendingPathComponent("Only.pdf")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.copyItem(at: template, to: file)
        guard let store = try? Store(directory: root.appendingPathComponent("library.doctopus")) else {
            Check.that("a second library can be made", false)
            return
        }
        let problems = Problems()
        let indexer = indexer(for: store, problems: problems)
        await indexer.indexAll()
        let id = ((try? await store.allDocumentIDs()) ?? []).first

        try? fm.moveItem(at: file, to: aside)
        await indexer.indexAll()
        let missing = if let id { await isMissing(id, in: store) } else { Bool?.none }
        let said = problems.all.first { $0.contains("looked empty") }
        print("  library read as empty   \(said ?? "nothing said")")
        Check.that("a library that suddenly lists as empty does not mark its documents missing",
                   id != nil && missing == false)
        Check.that("…and says why", said != nil)
    }

    static func droppedEvents(store: Store) async {
        print("\nDROPPED EVENTS")
        let fm = FileManager.default
        let problems = Problems()
        let indexer = indexer(for: store, problems: problems)
        guard let subject = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                             sort: .added, ascending: false)) ?? [])
            .first(where: { $0.ext == "pdf" && !$0.missing && fm.fileExists(atPath: $0.path) })
        else {
            Check.that("the fixtures have a PDF to lose an event for", false)
            return
        }

        // FSEvents coalesced the folder's events: all it says is "look in here".
        let folder = store.root.appendingPathComponent("Coalesced", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = await indexer.move(ids: [subject.doc], to: folder)
        let moved = folder.appendingPathComponent(subject.filename)
        let aside = fm.temporaryDirectory.appendingPathComponent("doctopus-dropped-\(UUID().uuidString).pdf")
        try? fm.moveItem(at: moved, to: aside)
        await indexer.handleChanges(paths: [], rescanning: [folder.path])
        Check.that("a document deleted where events were dropped is marked missing on the rescan",
                   await isMissing(subject.doc, in: store) == true)

        try? fm.moveItem(at: aside, to: moved)
        await indexer.handleChanges(paths: [], rescanning: [folder.path])
        Check.that("…and one that came back is found again",
                   await isMissing(subject.doc, in: store) == false)

        let elsewhere = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                         sort: .added, ascending: false)) ?? [])
            .filter { !$0.missing && !$0.path.hasPrefix(folder.path + "/") }.count
        await indexer.handleChanges(paths: [], rescanning: [folder.path])
        let stillThere = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? [])
            .filter { !$0.missing && !$0.path.hasPrefix(folder.path + "/") }.count
        Check.that("a rescan of one folder marks nothing outside it missing", elsewhere == stillThere,
                   "\(elsewhere) → \(stillThere)")

        _ = await indexer.move(ids: [subject.doc], to: subject.url.deletingLastPathComponent())
        try? fm.removeItem(at: folder)

        await watchedRootMoves()
    }

    /// The watcher has to say when the folder it watches goes, since every
    /// event after that is for a path outside it.
    private static func watchedRootMoves() async {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("doctopus-watch-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Library", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }

        let heard = Problems()
        let watcher = FileWatcher(onChange: { _ in }, onRootChanged: { heard.add("root") })
        watcher.start(paths: [Store.canonical(root.path)])
        try? await Task.sleep(for: .milliseconds(500))
        try? fm.moveItem(at: root, to: parent.appendingPathComponent("Renamed", isDirectory: true))
        for _ in 0..<50 where heard.all.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        watcher.stop()
        print("  watched folder renamed  \(heard.all.isEmpty ? "not heard" : "heard")")
        Check.that("renaming the watched folder is reported as the root changing", !heard.all.isEmpty)
    }
}
