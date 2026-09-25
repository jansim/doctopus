import Foundation

/// The library on disk: its format, its migrations, and how its files are known.
extension SelfTest {
    static func ruleMigration() {
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

    static func noteMigration() {
        print("\nNOTE MIGRATION")
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-notes-v23-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = try? Database(path: path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        // The `notes` table as version 23 left it: any number per document.
        try? db.exec("""
        CREATE TABLE documents (id INTEGER PRIMARY KEY);
        INSERT INTO documents(id) VALUES (1), (2);
        CREATE TABLE notes (
            id INTEGER PRIMARY KEY, doc_id INTEGER NOT NULL REFERENCES documents(id), body TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL
        );
        INSERT INTO notes(doc_id, body, created_at, updated_at)
        VALUES (1, 'second', 20, NULL), (1, 'first', 10, 30), (2, 'only', 5, NULL);
        PRAGMA user_version=23;
        """)
        try? Schema.migrate(db)
        let notes = (try? db.map("SELECT doc_id, body, updated_at FROM notes ORDER BY doc_id") {
            ($0.int(0), $0.string(1), $0.double(2))
        }) ?? []
        Check.that("a document's notes become one, oldest first, and keep when they were last touched",
                   notes.count == 2
                       && notes[0] == (1, "first\n\nsecond", 30) && notes[1] == (2, "only", 5),
                   "\(notes)")
    }

    static func libraryFormat(container: URL) {
        print("\nLIBRARY FORMAT")
        let metaURL = container.appendingPathComponent("meta.json")
        let stamped = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)))
            as? [String: Any]
        let stampedVersion: Int = (stamped?["formatVersion"] as? Int) ?? -1
        let stampedApp: String = (stamped?["appVersion"] as? String) ?? "—"
        print("  meta.json               formatVersion=\(stampedVersion) appVersion=" + stampedApp)
        Check.that("the writing app stamps the library format it understands",
                   stamped?["formatVersion"] as? Int == Store.formatVersion)

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
                   refused?.contains("99.0") == true)
        try? FileManager.default.removeItem(at: future.deletingLastPathComponent())

        let newerIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-newer-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("library.doctopus", isDirectory: true)
        let indexPath = newerIndex.appendingPathComponent("index.sqlite").path
        func indexVersion() -> Int {
            (try? Database(path: indexPath).first("PRAGMA user_version") { Int($0.int(0)) }) ?? -1
        }
        _ = try? Store(directory: newerIndex)
        Check.that("a new index is stamped with every migration", indexVersion() == Schema.current)
        try? Database(path: indexPath).exec("PRAGMA user_version=\(Schema.current + 1)")
        var refusedIndex = false
        do { _ = try Store(directory: newerIndex) } catch Store.OpenError.newer { refusedIndex = true } catch {}
        Check.that("an index migrated by a newer build is refused, even at the same format",
                   refusedIndex)
        Check.that("…and is not stamped back down to this build's version",
                   indexVersion() == Schema.current + 1)
        try? FileManager.default.removeItem(at: newerIndex.deletingLastPathComponent())
    }

    static func verification(store: Store) async {
        print("\nSANITY CHECK / VERIFICATION")
        let healthyReport = (try? await LibraryVerifier.verify(store: store)) ?? VerificationReport()
        Check.that("verification of healthy library reports zero errors", healthyReport.errorsCount == 0,
                   healthyReport.issues.filter { $0.severity == .error }
                       .map { "\($0.title): \($0.detail ?? "")" }.joined(separator: "; "))
    }

    static func contentHashes(store: Store, rows: [DocumentRow]) async {
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
    }

    static func fileIDs(store: Store, indexer: Indexer) async {
        print("\nFILE IDS")
        let fm = FileManager.default
        let present = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                       sort: .added, ascending: false)) ?? [])
            .filter { $0.ext == "pdf" && fm.fileExists(atPath: $0.path) }
        if present.count >= 2 {
            let (edited, moved) = (present[0], present[1])
            Check.that("files carry the file system's ID for them", FileScanner.fileID(edited.url) != nil)

            // Edited after the move, so only the file ID can find it.
            let away = store.root.appendingPathComponent("Moved Away", isDirectory: true)
            let editedTarget = away.appendingPathComponent(edited.filename)
            try? fm.createDirectory(at: away, withIntermediateDirectories: true)
            try? fm.moveItem(at: edited.url, to: editedTarget)
            if let handle = try? FileHandle(forWritingTo: editedTarget) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("\n% edited\n".utf8))
                try? handle.close()
            }
            await indexer.indexAll()
            let editedPath = try? await store.documentPath(edited.doc)
            Check.that("a full scan takes a moved and edited file's document along",
                       editedPath == editedTarget.path, editedPath ?? "gone")

            // The watcher only hears about the folder the file landed in.
            let into = store.root.appendingPathComponent("Picked Up", isDirectory: true)
            let movedTarget = into.appendingPathComponent(moved.filename)
            try? fm.createDirectory(at: into, withIntermediateDirectories: true)
            try? fm.moveItem(at: moved.url, to: movedTarget)
            await indexer.handleChanges(paths: [moved.path, into.path])
            let movedPath = try? await store.documentPath(moved.doc)
            Check.that("the watcher takes a moved file's document along",
                       movedPath == movedTarget.path, movedPath ?? "gone")
        } else {
            Check.that("the fixtures have two PDFs to move", false)
        }
    }
}
