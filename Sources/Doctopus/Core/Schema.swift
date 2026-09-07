import Foundation

/// Versioned schema. Migrations are append-only: bump `current` and add a case.
enum Schema {
    static let current = 1

    static func migrate(_ db: Database) throws {
        let version = try db.first("PRAGMA user_version") { Int($0.int(0)) } ?? 0
        if version < 1 { try v1(db) }
        try db.exec("PRAGMA user_version=\(current)")
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
