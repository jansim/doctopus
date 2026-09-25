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

    static func isMissing(_ id: Int64, in store: Store) async -> Bool? {
        ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                         sort: .added, ascending: false)) ?? [])
            .first { $0.doc == id }?.missing
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
}
