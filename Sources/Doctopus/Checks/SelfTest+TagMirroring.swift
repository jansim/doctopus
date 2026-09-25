import Foundation

extension SelfTest {
    /// Tags used to be mirrorable to disk as Finder aliases. A library that
    /// had it on has to open as it was, less the mirroring, and the aliases it
    /// made are only forgotten by the index, never deleted.
    static func tagMirroringRemoved() {
        print("\nTAG MIRRORING REMOVED")

        let stored = Data(#"{"mirrorTagsAsAliases": true, "scanDestination": "Post"}"#.utf8)
        let decoded = LibrarySettings.decodedIfReadable(from: stored)
        Check.that("library settings saved with tag mirroring on still load, and keep the rest",
                   decoded?.scanDestination == "Post", decoded.map { "\($0.scanDestination)" } ?? "unreadable")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-mirrors-v24-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mirrored = folder.appendingPathComponent("Tags/Tax/lease.pdf")
        try? FileManager.default.createDirectory(at: mirrored.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("stands in for the alias a mirrored tag made".utf8).write(to: mirrored)

        guard let db = try? Database(path: folder.appendingPathComponent("index.sqlite").path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        // The tables as version 24 left them: tags that mirror, and aliases
        // registered against the tag that made them.
        try? db.exec("""
        CREATE TABLE documents (id INTEGER PRIMARY KEY);
        INSERT INTO documents(id) VALUES (1);
        CREATE TABLE tags (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            color INTEGER NOT NULL DEFAULT 0, mirrors INTEGER NOT NULL DEFAULT 0, folder TEXT,
            parent_id INTEGER REFERENCES tags(id) ON DELETE SET NULL
        );
        INSERT INTO tags(id, name, mirrors, folder) VALUES (7, 'Tax', 1, '~/Elsewhere');
        CREATE TABLE aliases (
            id INTEGER PRIMARY KEY,
            doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            tag_id INTEGER REFERENCES tags(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE, created_at REAL NOT NULL
        );
        INSERT INTO aliases(id, doc_id, tag_id, path, created_at)
        VALUES (3, 1, NULL, 'Work/lease.pdf', 10), (4, 1, 7, 'Tags/Tax/lease.pdf', 20);
        PRAGMA user_version=24;
        """)
        do { try Schema.migrate(db) } catch {
            Check.that("an index that mirrored tags migrates", false, "\(error)"); return
        }

        let tagColumns = (try? db.map("SELECT name FROM pragma_table_info('tags')") { $0.string(0) }) ?? []
        let aliasColumns = (try? db.map("SELECT name FROM pragma_table_info('aliases')") { $0.string(0) }) ?? []
        Check.that("tags lose their mirroring columns, and aliases the tag that made them",
                   !tagColumns.contains("mirrors") && !tagColumns.contains("folder")
                       && tagColumns.contains("parent_id") && !aliasColumns.contains("tag_id"),
                   "tags: \(tagColumns), aliases: \(aliasColumns)")
        let kept = (try? db.map("SELECT id, path FROM aliases ORDER BY id") { "\($0.int(0)) \($0.string(1))" }) ?? []
        Check.that("an alias filed by hand stays registered, a mirrored tag's is forgotten",
                   kept == ["3 Work/lease.pdf"], "\(kept)")
        let tags = (try? db.map("SELECT name FROM tags") { $0.string(0) }) ?? []
        Check.that("…the tag itself stays", tags == ["Tax"], "\(tags)")
        Check.that("…and the mirrored alias is left on disk",
                   FileManager.default.fileExists(atPath: mirrored.path))
    }
}
