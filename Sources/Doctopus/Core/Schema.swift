import Foundation

/// Versioned schema. Migrations are append-only: bump `current` and add a case.
enum Schema {
    static let current = 9

    static func migrate(_ db: Database) throws {
        let version = try db.first("PRAGMA user_version") { Int($0.int(0)) } ?? 0
        if version < 1 { try v1(db) }
        if version < 2 { try v2(db) }
        if version < 3 { try v3(db) }
        if version < 4 { try v4(db) }
        if version < 5 { try v5(db) }
        if version < 6 { try v6(db) }
        if version < 7 { try v7(db) }
        if version < 8 { try v8(db) }
        if version < 9 { try v9(db) }
        try db.exec("PRAGMA user_version=\(current)")
    }

    /// Adds a column for a column-adding migration, once. SQLite has no
    /// `ADD COLUMN IF NOT EXISTS`, and a migration can be re-entered when an
    /// older build wrote the table but not the `user_version`.
    private static func addColumn(_ db: Database, table: String, column: String,
                                  declaration: String) throws {
        let present = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?",
            [.text(table), .text(column)]) { $0.int(0) } ?? 0
        guard present == 0 else { return }
        try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(declaration)")
    }

    /// History, split from the review queue.
    ///
    /// `processing` was doing two jobs and doing the second one badly: it was
    /// the recency view the review reads, *and* the only record of what
    /// happened to a document — while being trimmed to 500 rows on every
    /// insert. So the 501st import silently erased the first, and there was no
    /// answer to "why is this file here", let alone an undo.
    ///
    /// `events` is that record: append-only, never trimmed, ~100 bytes a row.
    /// `processing` keeps only what is actually its own — which event is on
    /// show and whether it has been signed off — and reads the rest back
    /// through `event_id`.
    private static func v9(_ db: Database) throws {
        let alreadyThere = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('processing') WHERE name='event_id'") { $0.int(0) } ?? 0
        guard alreadyThere == 0 else { return }

        try db.exec("""
        CREATE TABLE IF NOT EXISTS events (
            id          INTEGER PRIMARY KEY,
            doc_id      INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            at          REAL NOT NULL,
            action      TEXT NOT NULL,  -- 'imported' | 'routed' | 'indexed' | 'optimized' | 'renamed' | 'moved' | 'analyzed'
            detail      TEXT,
            confidence  REAL,
            rule        TEXT,
            from_path   TEXT,
            to_path     TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_events_doc ON events(doc_id, at DESC);
        CREATE INDEX IF NOT EXISTS idx_events_at  ON events(at DESC);
        """)

        // The existing queue is the history we have; carry it over keeping the
        // row ids, so the rebuilt `processing` can point straight at it.
        let hadQueue = try db.first(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='processing'") { $0.int(0) } ?? 0
        if hadQueue > 0 {
            try db.exec("""
            INSERT OR IGNORE INTO events(id, doc_id, at, action, detail, confidence, rule, from_path, to_path)
            SELECT id, doc_id, at, action, detail, confidence, rule, from_path, to_path FROM processing;
            """)
        }

        try db.exec("""
        CREATE TABLE processing_v9 (
            id       INTEGER PRIMARY KEY,
            event_id INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
            doc_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            status   INTEGER NOT NULL DEFAULT 0 -- 0 needs review, 1 approved
        );
        """)
        if hadQueue > 0 {
            try db.exec("""
            INSERT INTO processing_v9(id, event_id, doc_id, status)
            SELECT p.id, p.id, p.doc_id, p.status FROM processing p
            WHERE EXISTS (SELECT 1 FROM events e WHERE e.id = p.id);
            """)
            try db.exec("DROP TABLE processing")
        }
        try db.exec("""
        ALTER TABLE processing_v9 RENAME TO processing;
        CREATE INDEX IF NOT EXISTS idx_processing_doc   ON processing(doc_id);
        CREATE INDEX IF NOT EXISTS idx_processing_event ON processing(event_id);
        """)
    }

    /// The search index, rebuilt as a real one.
    ///
    /// `ocr_content` had three problems: its `doc_id` was `UNINDEXED`, so
    /// fetching one document's text scanned the whole corpus; it held only the
    /// OCR text, leaving title, correspondent, tags and filename to an
    /// unindexable `LIKE '%…%'`; and its rows had no key a delete could find
    /// cheaply. `doc_fts` fixes all three by keying on `rowid = documents.id`
    /// and giving every searchable surface its own column, which also makes
    /// `bm25()` weights — a title hit outranking a body hit — possible.
    ///
    /// `notes` is written blank for now; the notes themselves are a separate
    /// change, and adding the column here saves rebuilding the index twice.
    private static func v8(_ db: Database) throws {
        let alreadyThere = try db.first(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='doc_fts'") { $0.int(0) } ?? 0
        guard alreadyThere == 0 else { return }

        try db.exec("""
        CREATE VIRTUAL TABLE doc_fts USING fts5(
            title, correspondent, doc_type, tags, fields, notes, filename, body,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)

        let hasOld = try db.first(
            "SELECT COUNT(*) FROM sqlite_master WHERE name='ocr_content'") { $0.int(0) } ?? 0
        let body = hasOld > 0
            ? "COALESCE((SELECT c.text FROM ocr_content c WHERE c.doc_id = d.id), '')"
            : "''"
        try db.exec("""
        INSERT INTO doc_fts(rowid, title, correspondent, doc_type, tags, fields, notes, filename, body)
        SELECT d.id,
               COALESCE(m.title, ''), COALESCE(m.correspondent, ''), COALESCE(m.doc_type, ''),
               COALESCE((SELECT group_concat(t.name, ' ') FROM document_tags dt
                          JOIN tags t ON t.id = dt.tag_id WHERE dt.doc_id = d.id), ''),
               COALESCE((SELECT group_concat(v.value, ' ') FROM field_values v
                          WHERE v.doc_id = d.id), ''),
               '',
               d.filename,
               \(body)
        FROM documents d LEFT JOIN metadata m ON m.doc_id = d.id;
        """)
        if hasOld > 0 { try db.exec("DROP TABLE ocr_content") }
    }

    /// The hash of the bytes as they arrived, before any optimization rewrote
    /// them. `documents.hash` tracks what is on disk now, so re-importing the
    /// same original matches nothing once Doctopus has re-encoded it; the
    /// pre-optimization hash is what a duplicate check has to compare against.
    private static func v7(_ db: Database) throws {
        try addColumn(db, table: "documents", column: "original_hash", declaration: "TEXT")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_documents_original_hash ON documents(original_hash)")
    }

    /// Folders the router thought a new document could go in, kept whether or
    /// not it moved it. They are what the review offers as a choice — and all
    /// there is to go on when two were equally good and it moved nothing.
    /// `path` is relative to the library root, like every other path.
    private static func v6(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS path_suggestions (
            doc_id      INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            path        TEXT NOT NULL,
            confidence  REAL NOT NULL,
            source      TEXT NOT NULL,   -- rule name, or 'derived'
            explanation TEXT,
            rank        INTEGER NOT NULL,
            PRIMARY KEY (doc_id, path)
        );
        CREATE INDEX IF NOT EXISTS idx_path_suggestions_doc ON path_suggestions(doc_id);
        """)
    }

    /// Tags the model proposed but nobody has accepted yet. Kept apart from
    /// `document_tags` so a suggestion never counts toward a tag's sidebar
    /// total, or shows up anywhere a real assignment would, until someone
    /// accepts it.
    private static func v5(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS tag_suggestions (
            doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            name   TEXT NOT NULL COLLATE NOCASE,
            PRIMARY KEY (doc_id, name)
        );
        CREATE INDEX IF NOT EXISTS idx_tag_suggestions_doc ON tag_suggestions(doc_id);
        """)
    }

    /// The colour label macOS gives each Finder tag, so the sidebar can draw a
    /// tag in its own colour without re-reading every file at launch.
    private static func v4(_ db: Database) throws {
        let present = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('finder_tags') WHERE name='label'") { $0.int(0) } ?? 0
        guard present == 0 else { return }
        try db.exec("ALTER TABLE finder_tags ADD COLUMN label INTEGER NOT NULL DEFAULT 0")
    }

    /// Per-value icons, and the mirror of the Finder's own tags. Finder tags
    /// live on the file itself, in extended attributes; this table is only an
    /// index of them so they can be counted and filtered without touching the
    /// disk for every query.
    private static func v3(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS value_icons (
            field_id INTEGER NOT NULL REFERENCES fields(id) ON DELETE CASCADE,
            value    TEXT NOT NULL,
            icon     TEXT NOT NULL,
            PRIMARY KEY (field_id, value)
        );
        CREATE TABLE IF NOT EXISTS finder_tags (
            doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            name   TEXT NOT NULL,
            PRIMARY KEY (doc_id, name)
        );
        CREATE INDEX IF NOT EXISTS idx_finder_tags_name ON finder_tags(name);
        """)
    }

    /// Configurable fields. Built-ins keep their dedicated `metadata` column so
    /// the list query stays one statement; user-defined fields live in
    /// `field_values`. The UI treats both through a single `Field` model.
    private static func v2(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS fields (
            id              INTEGER PRIMARY KEY,
            key             TEXT NOT NULL UNIQUE,
            name            TEXT NOT NULL,
            builtin_column  TEXT,          -- non-null => stored in metadata.<column>
            icon            TEXT NOT NULL DEFAULT 'tag',
            show_in_sidebar INTEGER NOT NULL DEFAULT 1,
            show_in_list    INTEGER NOT NULL DEFAULT 0,
            position        INTEGER NOT NULL DEFAULT 0,
            enabled         INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS field_values (
            doc_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            field_id INTEGER NOT NULL REFERENCES fields(id) ON DELETE CASCADE,
            value    TEXT NOT NULL,
            PRIMARY KEY (doc_id, field_id)
        );
        CREATE INDEX IF NOT EXISTS idx_field_values ON field_values(field_id, value);
        """)

        // Correspondent ships demoted: still extracted and shown in the
        // inspector, but no longer taking up a sidebar section and a column.
        let seed: [(String, String, String, String, Int, Int, Int)] = [
            ("doc_type",      "Document Type", "doc_type",      "doc.on.doc",        1, 1, 10),
            ("correspondent", "Correspondent", "correspondent", "building.2",        0, 0, 20),
            ("language",      "Language",      "language",      "character.bubble",  1, 0, 30),
            ("amount",        "Amount",        "amount",        "eurosign.circle",   0, 0, 40),
            ("intent",        "Intent",        "intent",        "arrow.turn.down.right", 0, 0, 50),
        ]
        for (key, name, column, icon, sidebar, list, position) in seed {
            try db.run("""
                INSERT OR IGNORE INTO fields(key, name, builtin_column, icon, show_in_sidebar, show_in_list, position)
                VALUES(?,?,?,?,?,?,?)
                """, [.text(key), .text(name), .text(column), .text(icon),
                      .int(sidebar), .int(list), .int(position)])
        }
    }

    private static func v1(_ db: Database) throws {
        try db.exec("""
        -- One row per physical file on disk. `path` and `directory` are stored
        -- relative to the library root (the folder that holds library.doctopus),
        -- so the whole library can be moved or copied and still resolve. `Store`
        -- translates to and from absolute URLs at its boundary.
        CREATE TABLE IF NOT EXISTS documents (
            id            INTEGER PRIMARY KEY,
            path          TEXT NOT NULL UNIQUE,
            directory     TEXT NOT NULL,
            filename      TEXT NOT NULL,
            ext           TEXT NOT NULL,
            hash          TEXT,               -- SHA-256 of file contents
            size          INTEGER NOT NULL,
            original_size INTEGER,            -- pre-optimization size, if optimized
            mtime         REAL NOT NULL,
            created_at    REAL NOT NULL,
            indexed_at    REAL,
            ocr_state     INTEGER NOT NULL DEFAULT 0, -- 0 pending 1 done 2 failed 3 skipped
            page_count    INTEGER,
            approved      INTEGER NOT NULL DEFAULT 1,
            missing       INTEGER NOT NULL DEFAULT 0,
            missing_since REAL
        );
        CREATE INDEX IF NOT EXISTS idx_documents_dir     ON documents(directory);
        CREATE INDEX IF NOT EXISTS idx_documents_hash    ON documents(hash);
        CREATE INDEX IF NOT EXISTS idx_documents_state   ON documents(ocr_state);
        CREATE INDEX IF NOT EXISTS idx_documents_created ON documents(created_at DESC);

        -- Full-text index. Contentless-adjacent: we keep the text so snippets work,
        -- but strip it from the row payload of `documents` to keep scans tight.
        CREATE VIRTUAL TABLE IF NOT EXISTS ocr_content USING fts5(
            text,
            doc_id UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS ocr_stats (
            doc_id     INTEGER PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
            confidence REAL,      -- mean Vision confidence across observations
            words      INTEGER,
            source     TEXT,      -- 'pdf-layer' | 'vision' | 'mixed'
            engine_ms  INTEGER
        );

        CREATE TABLE IF NOT EXISTS metadata (
            doc_id        INTEGER PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
            title         TEXT,
            correspondent TEXT,
            doc_type      TEXT,
            language      TEXT,
            summary       TEXT,
            intent        TEXT,
            doc_date      REAL,
            date_source   TEXT,   -- 'ocr' | 'pdf' | 'exif' | 'filename' | 'fs'
            confidence    REAL,
            source        TEXT,   -- 'llm' | 'heuristic'
            amount        TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_metadata_corr ON metadata(correspondent);
        CREATE INDEX IF NOT EXISTS idx_metadata_type ON metadata(doc_type);
        CREATE INDEX IF NOT EXISTS idx_metadata_lang ON metadata(language);
        CREATE INDEX IF NOT EXISTS idx_metadata_date ON metadata(doc_date DESC);

        CREATE TABLE IF NOT EXISTS tags (
            id        INTEGER PRIMARY KEY,
            name      TEXT NOT NULL UNIQUE COLLATE NOCASE,
            color     INTEGER NOT NULL DEFAULT 0,
            mirrors   INTEGER NOT NULL DEFAULT 0, -- per-tag Finder alias mirroring
            folder    TEXT                        -- alias destination override
        );
        CREATE TABLE IF NOT EXISTS document_tags (
            doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            auto   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (doc_id, tag_id)
        );
        CREATE INDEX IF NOT EXISTS idx_document_tags_tag ON document_tags(tag_id);

        -- Every alias we generated, so we can prune exactly what we own.
        CREATE TABLE IF NOT EXISTS aliases (
            id         INTEGER PRIMARY KEY,
            doc_id     INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            tag_id     INTEGER REFERENCES tags(id) ON DELETE CASCADE,
            path       TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL
        );

        -- Auto-routing: first matching rule above threshold wins.
        CREATE TABLE IF NOT EXISTS rules (
            id          INTEGER PRIMARY KEY,
            name        TEXT NOT NULL,
            pattern     TEXT NOT NULL,  -- matched against OCR text + filename
            field       TEXT NOT NULL DEFAULT 'text',
            destination TEXT NOT NULL,
            tag_names   TEXT,           -- comma separated
            weight      REAL NOT NULL DEFAULT 0.9,
            enabled     INTEGER NOT NULL DEFAULT 1,
            priority    INTEGER NOT NULL DEFAULT 0
        );

        -- Recent Processing Queue.
        CREATE TABLE IF NOT EXISTS processing (
            id          INTEGER PRIMARY KEY,
            doc_id      INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            at          REAL NOT NULL,
            action      TEXT NOT NULL,  -- 'imported' | 'routed' | 'indexed' | 'optimized' | 'renamed'
            detail      TEXT,
            confidence  REAL,
            rule        TEXT,
            from_path   TEXT,
            to_path     TEXT,
            status      INTEGER NOT NULL DEFAULT 0 -- 0 needs review, 1 approved
        );
        CREATE INDEX IF NOT EXISTS idx_processing_at ON processing(at DESC);

        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }
}
