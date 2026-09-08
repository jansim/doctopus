import Foundation

/// Versioned schema. Migrations are append-only: bump `current` and add a case.
enum Schema {
    static let current = 3

    static func migrate(_ db: Database) throws {
        let version = try db.first("PRAGMA user_version") { Int($0.int(0)) } ?? 0
        if version < 1 { try v1(db) }
        if version < 2 { try v2(db) }
        if version < 3 { try v3(db) }
        try db.exec("PRAGMA user_version=\(current)")
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
        -- Watched top-level directories. Bookmarks let us survive folder moves.
        CREATE TABLE IF NOT EXISTS roots (
            id       INTEGER PRIMARY KEY,
            path     TEXT NOT NULL UNIQUE,
            bookmark BLOB,
            added_at REAL NOT NULL
        );

        -- One row per physical file on disk. `path` is the canonical master location.
        CREATE TABLE IF NOT EXISTS documents (
            id            INTEGER PRIMARY KEY,
            root_id       INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
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
