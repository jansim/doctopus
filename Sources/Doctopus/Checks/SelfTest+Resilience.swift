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

    static func oneWriterAtATime() async {
        print("\nONE WRITER AT A TIME")
        let fm = FileManager.default
        let container = fm.temporaryDirectory
            .appendingPathComponent("doctopus-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.doctopus", isDirectory: true)
        defer { try? fm.removeItem(at: container.deletingLastPathComponent()) }

        let first = try? LibraryLock.acquire(in: container)
        var refusal: String?
        do { _ = try LibraryLock.acquire(in: container) } catch { refusal = "\(error)" }
        print("  second open             \(refusal ?? "allowed")")
        Check.that("a library held open is refused to a second opener", first != nil && refusal != nil)
        Check.that("the holder is recorded for other Macs to see",
                   LibraryLock.owner(in: container)?.machine == LibraryLock.thisMachine)
        Check.that("the same library reached twice is recognised by its lock file",
                   first?.identity != nil && first?.identity == LibraryLock.identity(in: container))

        first?.release()
        let again = try? LibraryLock.acquire(in: container)
        Check.that("released, it opens again at once, and the owner record is cleared on the way",
                   again != nil)
        again?.release()
        Check.that("…and a released lock names nobody", LibraryLock.owner(in: container) == nil)

        // Another Mac, through a synced folder, where flock does not reach.
        func elsewhere(_ age: TimeInterval) {
            let owner = LibraryLock.Owner(machine: "another-mac", name: "Other Mac", pid: 1,
                                          heartbeat: Date().addingTimeInterval(-age))
            try? JSONEncoder().encode(owner).write(to: container.appendingPathComponent(LibraryLock.filename))
        }
        elsewhere(30)
        var foreign: String?
        do { _ = try LibraryLock.acquire(in: container) } catch { foreign = "\(error)" }
        print("  open on another Mac     \(foreign ?? "allowed")")
        Check.that("a library another Mac renewed recently is refused, naming that Mac",
                   foreign?.contains("Other Mac") == true)
        elsewhere(LibraryLock.staleAfter + 60)
        let takenOver = try? LibraryLock.acquire(in: container)
        Check.that("…but one it stopped renewing is taken over", takenOver != nil)
        takenOver?.release()

        let store = try? Store(directory: container, lock: try? LibraryLock.acquire(in: container))
        var storeRefusal: LibraryLock.Refusal?
        do { _ = try Store(directory: container, lock: LibraryLock.acquire(in: container)) }
        catch let error as LibraryLock.Refusal { storeRefusal = error } catch {}
        Check.that("a second store is refused before it touches the index", store != nil && storeRefusal != nil)

        let home = fm.homeDirectoryForCurrentUser
        let cases: [(String, String?)] = [
            (home.path + "/Library/Mobile Documents/com~apple~CloudDocs/Docs", "iCloud Drive"),
            (home.path + "/Library/CloudStorage/Dropbox/Docs", "Dropbox"),
            (home.path + "/Library/CloudStorage/OneDrive-Personal/Docs", "OneDrive"),
            (home.path + "/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive", "Google Drive"),
            (container.deletingLastPathComponent().path, nil),
        ]
        let wrong = cases.filter { SyncedFolder.service(for: URL(fileURLWithPath: $0.0)) != $0.1 }
        Check.that("synced folders are recognised by service, and a local one is not", wrong.isEmpty,
                   wrong.map(\.0).joined(separator: ", "))
        let legacy = container.deletingLastPathComponent().appendingPathComponent("Old Dropbox/Docs")
        try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        fm.createFile(atPath: legacy.deletingLastPathComponent().appendingPathComponent(".dropbox").path,
                      contents: Data())
        Check.that("the older Dropbox client's marked folder counts too",
                   SyncedFolder.service(for: legacy) == "Dropbox")
    }

    static func indexBackups(template: URL) async {
        print("\nINDEX BACKUPS")
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("doctopus-backups-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.copyItem(at: template, to: root.appendingPathComponent("Kept.pdf"))
        let container = root.appendingPathComponent("library.doctopus")
        guard let store = try? Store(directory: container) else {
            Check.that("a library to back up can be made", false)
            return
        }
        await indexer(for: store, problems: Problems()).indexAll()
        guard let id = ((try? await store.allDocumentIDs()) ?? []).first else {
            Check.that("the library to back up has a document", false)
            return
        }
        _ = try? await store.setNote("Written before the backup", for: id)

        let now = Date()
        let first = try? await store.backUpIfDue(now: now)
        let second = try? await store.backUpIfDue(now: now.addingTimeInterval(3600))
        let third = try? await store.backUpIfDue(now: now.addingTimeInterval(Store.backupEvery + 60))
        func made(_ o: Store.BackupOutcome?) -> Bool { if case .made = o { return true }; return false }
        func notDue(_ o: Store.BackupOutcome?) -> Bool { if case .notDue = o { return true }; return false }
        Check.that("a library with no backup is backed up", made(first))
        Check.that("…not again within the day", notDue(second))
        Check.that("…and again once a day has passed", made(third))

        guard case .made(let backup) = first else { return }
        let standalone = !fm.fileExists(atPath: backup.url.path + "-wal")
        // Read from a copy: opening one with `Database` would turn it to WAL.
        let probe = root.appendingPathComponent("probe.sqlite")
        try? fm.copyItem(at: backup.url, to: probe)
        let copied = (try? Database(path: probe.path).first("SELECT COUNT(*) FROM documents") { $0.int(0) }) ?? nil
        Check.that("a backup is a standalone index holding the documents",
                   copied == 1 && standalone, "\(copied.map(String.init) ?? "unreadable"), standalone: \(standalone)")

        _ = try? await store.setNote("Written after the backup", for: id)
        var setAside: Store.Backup?
        do { setAside = try await store.restore(from: backup, now: now.addingTimeInterval(7200)) }
        catch { print("  restore failed          \(error)") }
        let note = (try? await store.note(for: id)) ?? ""
        print("  note after restore      \(note)")
        Check.that("restoring puts the index back as it was", note == "Written before the backup")
        Check.that("…keeping the index it replaced among the backups",
                   setAside.map { fm.fileExists(atPath: $0.url.path) } == true
                       && store.backups().contains { $0.url == setAside?.url })

        for day in 2...12 {
            _ = try? await store.backUp(now: now.addingTimeInterval(Double(day) * Store.backupEvery))
        }
        let kept = store.backups()
        let scheduled = kept.filter { $0.url.lastPathComponent.hasPrefix("index-") }
        Check.that("only the newest \(Store.backupsKept) scheduled backups are kept",
                   scheduled.count == Store.backupsKept, "\(scheduled.count)")
        Check.that("…and what a restore set aside is never pruned", kept.contains { $0.url == setAside?.url })
        var healthy = false
        do { healthy = try await store.integrityProblem() == nil } catch {}
        Check.that("a healthy index passes its check", healthy)

        // Garbage over the pages past the header: the kind of damage a sync
        // service copying mid-write leaves behind.
        let damagedRoot = root.appendingPathComponent("Damaged", isDirectory: true)
        let damagedContainer = damagedRoot.appendingPathComponent("library.doctopus", isDirectory: true)
        try? fm.createDirectory(at: damagedContainer, withIntermediateDirectories: true)
        try? fm.copyItem(at: container.appendingPathComponent("meta.json"),
                         to: damagedContainer.appendingPathComponent("meta.json"))
        let damagedIndex = damagedContainer.appendingPathComponent("index.sqlite")
        try? fm.copyItem(at: scheduled.last!.url, to: damagedIndex)
        if var bytes = try? Data(contentsOf: damagedIndex), bytes.count > 8192 {
            let pages = bytes.count / 4096
            for page in stride(from: 2, to: pages, by: 2) {
                let start = page * 4096 + 64
                bytes.replaceSubrange(start..<(start + 512), with: Data(repeating: 0xA5, count: 512))
            }
            try? bytes.write(to: damagedIndex)
        }
        var outcome = "refused at open"
        if let damaged = try? Store(directory: damagedContainer) {
            switch try? await damaged.backUp() {
            case .damaged(let problem)?: outcome = "damaged: \(problem)"
            case .made?: outcome = "backed up anyway"
            default: outcome = "failed"
            }
            Check.that("a damaged index is never backed up over the good copies",
                       outcome.hasPrefix("damaged") && damaged.backups().isEmpty, outcome)
        } else {
            var refusal: Error?
            do { _ = try Store(directory: damagedContainer) } catch { refusal = error }
            outcome = refusal.map { "\($0)" } ?? "opened"
            Check.that("an index too damaged to open is recognised as damage", refusal.map(Store.isDamage) == true,
                       outcome)
            try? fm.createDirectory(at: Store.backupsDirectory(in: damagedContainer), withIntermediateDirectories: true)
            let good = scheduled[0].url
            try? fm.copyItem(at: good, to: Store.backupsDirectory(in: damagedContainer)
                .appendingPathComponent(good.lastPathComponent))
            if let good = Store.backups(in: damagedContainer).first {
                try? Store.replaceUnopenableIndex(in: damagedContainer, with: good)
            }
            let reopened = try? Store(directory: damagedContainer)
            let keptDamaged = ((try? fm.contentsOfDirectory(atPath: Store.backupsDirectory(in: damagedContainer).path)) ?? [])
                .contains { $0.hasPrefix("damaged-") }
            Check.that("…and is replaced from a backup, with the damaged files kept aside",
                       reopened != nil && keptDamaged)
        }
        print("  damaged index           \(outcome)")
    }
}
