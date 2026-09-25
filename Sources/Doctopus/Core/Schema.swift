import Foundation

/// Versioned schema. Migrations are append-only: add a step to `steps`.
/// A step is frozen once shipped, so it never calls code that may change later.
enum Schema {
    struct TooNew: Error {}

    private static let steps: [@Sendable (Database) throws -> Void] = [
        v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12, v13, v14, v15, v16, v17, v18, v19,
        v20, v21, v22,
    ]
    static var current: Int { steps.count }

    /// Each step commits with its own version, so a crash mid-way resumes at
    /// the step that failed. An index from a newer build is refused rather than
    /// stamped back down to this one's version.
    static func migrate(_ db: Database) throws {
        let version = try db.first("PRAGMA user_version") { Int($0.int(0)) } ?? 0
        guard version <= current else { throw TooNew() }
        for (index, step) in steps.enumerated().dropFirst(version) {
            try db.transaction {
                try step(db)
                try db.exec("PRAGMA user_version=\(index + 1)")
            }
        }
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

    /// Confidence scores were never more than a tally of which fields were
    /// found, so nothing stores them any more.
    private static func v22(_ db: Database) throws {
        for table in ["events", "path_suggestions", "metadata", "ocr_stats"] {
            let present = try db.first(
                "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name='confidence'",
                [.text(table)]) { $0.int(0) } ?? 0
            guard present > 0 else { continue }
            try db.exec("ALTER TABLE \(table) DROP COLUMN confidence")
        }
    }

    /// Documents marked as outliers for a rule, which it then leaves alone.
    private static func v21(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS rule_suppressions (
            rule_id    INTEGER NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
            doc_id     INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            PRIMARY KEY (rule_id, doc_id)
        );
        CREATE INDEX IF NOT EXISTS idx_rule_suppressions_doc ON rule_suppressions(doc_id);
        """)
    }

    /// v15: a pattern that compiled as a regex was being matched as one.
    static func inferredMode(_ pattern: String) -> Int64 {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard p.rangeOfCharacter(from: CharacterSet(charactersIn: "^$*+?[]()|\\")) != nil,
              (try? NSRegularExpression(pattern: p)) != nil else { return 0 }
        return 3
    }

    /// v19: every word pattern had matched at the start of a word.
    static func openingEnds(_ pattern: String) -> String {
        pattern.split(separator: ",", omittingEmptySubsequences: false)
            .map { part -> String in
                let t = part.trimmingCharacters(in: .whitespaces)
                return t.isEmpty || t.hasSuffix("*") ? t : t + "*"
            }
            .joined(separator: ", ")
    }

    /// File-system IDs, so a move is recognised even when the bytes changed.
    private static func v20(_ db: Database) throws {
        try addColumn(db, table: "documents", column: "file_id", declaration: "INTEGER")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_documents_file_id ON documents(file_id)")
    }

    /// Word patterns used to match at the start of a word; the `*` keeps every
    /// existing one matching what it matched.
    private static func v19(_ db: Database) throws {
        let already = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('rules') WHERE name='weight'") { $0.int(0) } ?? 0
        guard already > 0 else { return }

        try db.exec("UPDATE rule_actions SET kind='move_file' WHERE kind='file_into'")

        let words = "(0, 1)"  // any words, all words
        for (table, column) in [("rule_conditions", "pattern"), ("entities", "match")] {
            let rows = try db.map(
                "SELECT id, \(column) FROM \(table) WHERE match_mode IN \(words) AND \(column) IS NOT NULL"
            ) { ($0.int(0), $0.string(1)) }
            for (id, pattern) in rows {
                try db.run("UPDATE \(table) SET \(column)=? WHERE id=?",
                           [.text(openingEnds(pattern)), .int(id)])
            }
        }

        try db.exec("ALTER TABLE rules DROP COLUMN weight")
    }

    private static func v18(_ db: Database) throws {
        let already = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('rules') WHERE name='match_all'") { $0.int(0) } ?? 0
        guard already == 0 else { return }

        try db.exec("""
        CREATE TABLE IF NOT EXISTS rule_conditions (
            id                INTEGER PRIMARY KEY,
            rule_id           INTEGER NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
            position          INTEGER NOT NULL DEFAULT 0,
            field             TEXT NOT NULL DEFAULT 'text',
            pattern           TEXT NOT NULL,
            match_mode        INTEGER NOT NULL DEFAULT 0,
            match_insensitive INTEGER NOT NULL DEFAULT 1,
            negated           INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_rule_conditions ON rule_conditions(rule_id, position);

        CREATE TABLE IF NOT EXISTS rule_actions (
            id       INTEGER PRIMARY KEY,
            rule_id  INTEGER NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
            position INTEGER NOT NULL DEFAULT 0,
            kind     TEXT NOT NULL,
            value    TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_rule_actions ON rule_actions(rule_id, position);
        """)

        try addColumn(db, table: "rules", column: "match_all",
                      declaration: "INTEGER NOT NULL DEFAULT 0")

        try db.exec("""
        INSERT INTO rule_conditions(rule_id, position, field, pattern, match_mode, match_insensitive)
        SELECT id, 0, COALESCE(field, 'text'), pattern,
               COALESCE(match_mode, 0), COALESCE(match_insensitive, 1)
        FROM rules;
        """)

        for (position, column, kind) in [(0, "destination", "file_into"),
                                         (1, "tag_names", "add_tags"),
                                         (2, "set_correspondent", "set_correspondent"),
                                         (3, "set_doc_type", "set_doc_type")] {
            try db.exec("""
            INSERT INTO rule_actions(rule_id, position, kind, value)
            SELECT id, \(position), '\(kind)', TRIM(\(column)) FROM rules
            WHERE \(column) IS NOT NULL AND TRIM(\(column)) <> '';
            """)
        }

        try db.exec("""
        ALTER TABLE rules DROP COLUMN pattern;
        ALTER TABLE rules DROP COLUMN field;
        ALTER TABLE rules DROP COLUMN destination;
        ALTER TABLE rules DROP COLUMN tag_names;
        ALTER TABLE rules DROP COLUMN match_mode;
        ALTER TABLE rules DROP COLUMN match_insensitive;
        ALTER TABLE rules DROP COLUMN set_correspondent;
        ALTER TABLE rules DROP COLUMN set_doc_type;
        ALTER TABLE rules DROP COLUMN set_fields;
        """)
    }

    private static func v17(_ db: Database) throws {
        try addColumn(db, table: "rules", column: "set_correspondent", declaration: "TEXT")
        try addColumn(db, table: "rules", column: "set_doc_type", declaration: "TEXT")
        try addColumn(db, table: "rules", column: "set_fields", declaration: "TEXT")

        try db.exec("""
        CREATE TABLE IF NOT EXISTS saved_views (
            id        INTEGER PRIMARY KEY,
            name      TEXT NOT NULL,
            icon      TEXT NOT NULL DEFAULT 'line.3.horizontal.decrease.circle',
            query     TEXT NOT NULL,
            sort_key  TEXT,
            ascending INTEGER NOT NULL DEFAULT 0,
            view_mode TEXT,
            position  INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_saved_views_pos ON saved_views(position, name);
        """)
    }

    private static func v16(_ db: Database) throws {
        let already = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('metadata') WHERE name='correspondent_id'") { $0.int(0) } ?? 0
        guard already == 0 else { return }

        try db.exec("""
        CREATE TABLE IF NOT EXISTS entities (
            id                INTEGER PRIMARY KEY,
            field_id          INTEGER NOT NULL REFERENCES fields(id) ON DELETE CASCADE,
            name              TEXT NOT NULL COLLATE NOCASE,
            icon              TEXT,
            color             INTEGER NOT NULL DEFAULT 0,
            -- A value can identify itself, exactly as a rule does.
            match             TEXT,
            match_mode        INTEGER NOT NULL DEFAULT 0,
            match_insensitive INTEGER NOT NULL DEFAULT 1,
            UNIQUE (field_id, name)
        );
        CREATE INDEX IF NOT EXISTS idx_entities_field ON entities(field_id, name);
        """)

        for column in ["correspondent", "doc_type"] {
            try db.exec("""
            INSERT OR IGNORE INTO entities(field_id, name)
            SELECT f.id, TRIM(m.\(column)) FROM metadata m, fields f
            WHERE f.builtin_column = '\(column)'
              AND m.\(column) IS NOT NULL AND TRIM(m.\(column)) <> '';
            """)
        }

        try addColumn(db, table: "metadata", column: "correspondent_id",
                      declaration: "INTEGER REFERENCES entities(id) ON DELETE SET NULL")
        try addColumn(db, table: "metadata", column: "doc_type_id",
                      declaration: "INTEGER REFERENCES entities(id) ON DELETE SET NULL")

        for column in ["correspondent", "doc_type"] {
            try db.exec("""
            UPDATE metadata SET \(column)_id = (
                SELECT e.id FROM entities e JOIN fields f ON f.id = e.field_id
                WHERE f.builtin_column = '\(column)' AND e.name = TRIM(metadata.\(column))
            ) WHERE \(column) IS NOT NULL AND TRIM(\(column)) <> '';
            """)
        }

        try db.exec("""
        UPDATE entities SET icon = (
            SELECT vi.icon FROM value_icons vi
            WHERE vi.field_id = entities.field_id AND vi.value = entities.name
        ) WHERE icon IS NULL;
        DELETE FROM value_icons WHERE field_id IN (
            SELECT id FROM fields WHERE builtin_column IN ('correspondent', 'doc_type')
        );
        """)

        try db.exec("""
        DROP INDEX IF EXISTS idx_metadata_corr;
        DROP INDEX IF EXISTS idx_metadata_type;
        ALTER TABLE metadata DROP COLUMN correspondent;
        ALTER TABLE metadata DROP COLUMN doc_type;
        CREATE INDEX IF NOT EXISTS idx_metadata_corr ON metadata(correspondent_id);
        CREATE INDEX IF NOT EXISTS idx_metadata_type ON metadata(doc_type_id);
        """)
    }

    private static func v15(_ db: Database) throws {
        let already = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('rules') WHERE name='match_mode'") { $0.int(0) } ?? 0
        guard already == 0 else { return }
        try addColumn(db, table: "rules", column: "match_mode",
                      declaration: "INTEGER NOT NULL DEFAULT 0")
        try addColumn(db, table: "rules", column: "match_insensitive",
                      declaration: "INTEGER NOT NULL DEFAULT 1")

        let existing = try db.map("SELECT id, pattern FROM rules") { ($0.int(0), $0.string(1)) }
        for (id, pattern) in existing {
            try db.run("UPDATE rules SET match_mode=? WHERE id=?", [.int(inferredMode(pattern)), .int(id)])
        }
    }

    private static func v14(_ db: Database) throws {
        try addColumn(db, table: "tags", column: "parent_id",
                      declaration: "INTEGER REFERENCES tags(id) ON DELETE SET NULL")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tags_parent ON tags(parent_id)")
    }

    private static func v13(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS date_candidates (
            doc_id   INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            date     REAL NOT NULL,   -- UTC start of day
            source   TEXT NOT NULL,   -- 'ocr' | 'pdf' | 'exif' | 'filename'
            labelled INTEGER NOT NULL DEFAULT 0,
            cue      TEXT,
            rank     INTEGER NOT NULL,
            PRIMARY KEY (doc_id, date)
        );
        CREATE INDEX IF NOT EXISTS idx_date_candidates_doc ON date_candidates(doc_id, rank);
        """)

        try db.exec("""
        UPDATE metadata SET doc_date = CAST(FLOOR(doc_date / 86400.0) AS INTEGER) * 86400
        WHERE doc_date IS NOT NULL;
        """)
    }

    private static func v12(_ db: Database) throws {
        try addColumn(db, table: "fields", column: "data_type",
                      declaration: "TEXT NOT NULL DEFAULT 'string'")
        try addColumn(db, table: "fields", column: "extra_data", declaration: "TEXT")
        try addColumn(db, table: "field_values", column: "value_num", declaration: "REAL")
        try addColumn(db, table: "field_values", column: "value_date", declaration: "REAL")
        try addColumn(db, table: "field_values", column: "value_bool", declaration: "INTEGER")
        try db.exec("""
        CREATE INDEX IF NOT EXISTS idx_field_values_num  ON field_values(field_id, value_num);
        CREATE INDEX IF NOT EXISTS idx_field_values_date ON field_values(field_id, value_date);
        """)

        try addColumn(db, table: "metadata", column: "amount_value", declaration: "REAL")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_metadata_amount ON metadata(amount_value)")

        try db.exec("""
        UPDATE fields SET data_type='monetary' WHERE builtin_column='amount';
        """)
    }

    private static func v11(_ db: Database) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS notes (
            id         INTEGER PRIMARY KEY,
            doc_id     INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            body       TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_notes_doc ON notes(doc_id, created_at DESC);
        """)
    }

    private static func v10(_ db: Database) throws {
        try addColumn(db, table: "documents", column: "deleted_at", declaration: "REAL")
        try addColumn(db, table: "documents", column: "deleted_path", declaration: "TEXT")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_documents_deleted ON documents(deleted_at)")
    }

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

    private static func v7(_ db: Database) throws {
        try addColumn(db, table: "documents", column: "original_hash", declaration: "TEXT")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_documents_original_hash ON documents(original_hash)")
    }

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

    private static func v4(_ db: Database) throws {
        let present = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('finder_tags') WHERE name='label'") { $0.int(0) } ?? 0
        guard present == 0 else { return }
        try db.exec("ALTER TABLE finder_tags ADD COLUMN label INTEGER NOT NULL DEFAULT 0")
    }

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
