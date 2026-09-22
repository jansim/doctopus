import Foundation

/// Versioned schema. Migrations are append-only: bump `current` and add a case.
enum Schema {
    static let current = 19

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
        if version < 10 { try v10(db) }
        if version < 11 { try v11(db) }
        if version < 12 { try v12(db) }
        if version < 13 { try v13(db) }
        if version < 14 { try v14(db) }
        if version < 15 { try v15(db) }
        if version < 16 { try v16(db) }
        if version < 17 { try v17(db) }
        if version < 18 { try v18(db) }
        if version < 19 { try v19(db) }
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

    /// Words match whole, rules drop their confidence, and "file into"
    /// becomes "move file" alongside a new "rename file".
    ///
    /// The word modes matched at the start of a word, so "rechnung" caught
    /// "Rechnungsnummer" whether or not anyone meant it to. Now a word is a
    /// word, and `rechnung*` asks for the rest. Every pattern already written
    /// — a rule's, or a correspondent's or type's own — gets the `*` it was
    /// implicitly carrying, so nothing that matched yesterday stops matching.
    ///
    /// A rule's `weight` scaled how sure a match was, which made a rule you
    /// wrote about a filename less sure when a model disagreed about the
    /// correspondent. A rule that matches is certain; two rules that disagree
    /// about the folder are what leaves a document for review.
    private static func v19(_ db: Database) throws {
        let already = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('rules') WHERE name='weight'") { $0.int(0) } ?? 0
        guard already > 0 else { return }

        try db.exec("UPDATE rule_actions SET kind='move_file' WHERE kind='file_into'")

        let words = "(\(MatchMode.anyWord.rawValue), \(MatchMode.allWords.rawValue))"
        for (table, column) in [("rule_conditions", "pattern"), ("entities", "match")] {
            let rows = try db.map(
                "SELECT id, \(column) FROM \(table) WHERE match_mode IN \(words) AND \(column) IS NOT NULL"
            ) { ($0.int(0), $0.string(1)) }
            for (id, pattern) in rows {
                try db.run("UPDATE \(table) SET \(column)=? WHERE id=?",
                           [.text(PatternMatcher.openingEnds(pattern)), .int(id)])
            }
        }

        try db.exec("ALTER TABLE rules DROP COLUMN weight")
    }

    /// Rules grow conditions and actions.
    ///
    /// A rule was one pattern against one field, with its effects spread over
    /// four columns — `destination`, `tag_names`, `set_correspondent`,
    /// `set_doc_type` — that were each either filled in or empty. Two things a
    /// rule could not say, both of them ordinary: "an invoice from Acme, but
    /// not a credit note", and "these three words, all of them". Splitting that
    /// into two rules loses the fact that they are one decision.
    ///
    /// Conditions and actions become rows of their own, which is also what lets
    /// a rule be read and written whole: both tables are rewritten as a block
    /// per rule, so there is no partial state to reconcile.
    ///
    /// Every existing rule migrates to exactly one condition and the actions it
    /// had filled in, which is the same rule — the shape is wider, not
    /// different. `set_fields` goes: it was added for per-rule field values and
    /// never written, so nothing can be lost with it.
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

    /// Rule metadata assignment and saved views.
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

    /// Correspondents and document types become rows.
    ///
    /// They were free text in two `metadata` columns, which cost more than it
    /// looks. Renaming "Stadtwerke München GmbH" to "Stadtwerke München" was a
    /// string rewrite across every row that could not merge two spellings and
    /// could not be undone. `value_icons` keyed an icon by a *string*, so
    /// renaming the value orphaned its icon. A correspondent could not carry a
    /// matching rule of its own ("anything mentioning DE12 3456 is from this
    /// bank"), which is how Paperless gets most of its classification right
    /// with no model at all. And the router's `{correspondent}` token expanded
    /// whatever string the analyzer produced that day, so two spellings quietly
    /// made two folders.
    ///
    /// Now there is one row per value, documents point at it, and the name
    /// lives in exactly one place. Renaming is an `UPDATE` of that row; merging
    /// is repointing the documents and deleting the loser. `value_icons` folds
    /// into `entities.icon` for these two fields and stays as it was for the
    /// rest.
    ///
    /// Storage paths deliberately do *not* become entities the way Paperless's
    /// do: Doctopus's folders are real folders, derived from
    /// `documents.directory`, which is both correct and cheaper.
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

        // One row per spelling that is already in use.
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

        // An icon belonged to a string; now it belongs to the row, where a
        // rename can no longer orphan it.
        try db.exec("""
        UPDATE entities SET icon = (
            SELECT vi.icon FROM value_icons vi
            WHERE vi.field_id = entities.field_id AND vi.value = entities.name
        ) WHERE icon IS NULL;
        DELETE FROM value_icons WHERE field_id IN (
            SELECT id FROM fields WHERE builtin_column IN ('correspondent', 'doc_type')
        );
        """)

        // The old columns go, along with the indexes on them — keeping them
        // would only let the two spellings drift apart again.
        try db.exec("""
        DROP INDEX IF EXISTS idx_metadata_corr;
        DROP INDEX IF EXISTS idx_metadata_type;
        ALTER TABLE metadata DROP COLUMN correspondent;
        ALTER TABLE metadata DROP COLUMN doc_type;
        CREATE INDEX IF NOT EXISTS idx_metadata_corr ON metadata(correspondent_id);
        CREATE INDEX IF NOT EXISTS idx_metadata_type ON metadata(doc_type_id);
        """)
    }

    /// How a rule reads its pattern, said out loud.
    ///
    /// The router used to guess from the punctuation: anything containing
    /// `^$*+?[]()|\` became a regular expression. So `Acme (UK) Ltd` was
    /// silently compiled as a regex, and `Betrag: 100€ +` was a regex that
    /// failed to compile and fell back to word matching without saying so.
    ///
    /// Existing rules are migrated by running that inference one last time,
    /// which is the only place it belongs: whatever a rule meant yesterday is
    /// what it keeps meaning, and from now on it says so in a column.
    private static func v15(_ db: Database) throws {
        let already = try db.first(
            "SELECT COUNT(*) FROM pragma_table_info('rules') WHERE name='match_mode'") { $0.int(0) } ?? 0
        guard already == 0 else { return }
        try addColumn(db, table: "rules", column: "match_mode",
                      declaration: "INTEGER NOT NULL DEFAULT 0")
        try addColumn(db, table: "rules", column: "match_insensitive",
                      declaration: "INTEGER NOT NULL DEFAULT 1")

        // A pattern with regex punctuation in it was being read as a regex, so
        // that is what it stays.
        let existing = try db.map("SELECT id, pattern FROM rules") { ($0.int(0), $0.string(1)) }
        for (id, pattern) in existing {
            let mode = MatchMode.inferred(from: pattern)
            try db.run("UPDATE rules SET match_mode=? WHERE id=?", [.int(mode.rawValue), .int(id)])
        }
    }

    /// Nested tags.
    ///
    /// One of the most-requested things in Paperless's history, and cheap here:
    /// a parent, a depth cap, and every ancestor attached automatically when a
    /// child is assigned — so filtering by "Finances" finds the invoices filed
    /// under "Finances / Invoices" without anyone having to tag both.
    ///
    /// It composes with alias mirroring for free: a mirrored parent gives you a
    /// `Finances/` folder with `Invoices/` and `Statements/` inside it.
    ///
    /// A deleted parent leaves its children as roots rather than taking them
    /// with it — deleting "Finances" should not silently delete every invoice's
    /// tag as well.
    private static func v14(_ db: Database) throws {
        try addColumn(db, table: "tags", column: "parent_id",
                      declaration: "INTEGER REFERENCES tags(id) ON DELETE SET NULL")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tags_parent ON tags(parent_id)")
    }

    /// Days, and the dates that were not chosen.
    ///
    /// `doc_date` was a timestamp holding whatever instant the extractor
    /// happened to produce, so the same document read as two different days in
    /// two timezones. It is normalised here to the UTC start of its day, and
    /// every reading of it goes through `DayDate` from now on — a document is
    /// issued on a day, not at an instant.
    ///
    /// `date_candidates` keeps the dates that were found and not picked.
    /// Extraction gets `03/04/2026` wrong often enough that offering the
    /// runner-up as a chip in the review is the cheapest accuracy win there is,
    /// and throwing the alternatives away was the only reason it could not.
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

        // Round every stored date down to the start of its UTC day. SQLite's
        // own arithmetic does this without needing to load the library.
        try db.exec("""
        UPDATE metadata SET doc_date = CAST(FLOOR(doc_date / 86400.0) AS INTEGER) * 86400
        WHERE doc_date IS NOT NULL;
        """)
    }

    /// Typed fields.
    ///
    /// Every field value was `TEXT`, including amounts and dates. So amounts
    /// sorted lexicographically ("€90" after "€1,200"), a date field could not
    /// be compared at all, and a "paid?" field was a string that said "yes" or
    /// "Yes" depending on who typed it.
    ///
    /// The fix is Paperless's, and it is unglamorous: a declared type on the
    /// field, and a typed column per shape alongside the text. The text stays —
    /// it is what gets displayed, and for `monetary` it is the only place the
    /// currency lives — while the typed column is what sorting and comparison
    /// actually use.
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

        // The built-in amount is the same problem in a dedicated column: the
        // string keeps the currency, the number is what sorts and sums.
        try addColumn(db, table: "metadata", column: "amount_value", declaration: "REAL")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_metadata_amount ON metadata(amount_value)")

        // The built-in fields declare what they have always held.
        try db.exec("""
        UPDATE fields SET data_type='monetary' WHERE builtin_column='amount';
        """)
    }

    /// Notes: the escape hatch for everything the schema does not model.
    ///
    /// "Cancelled by phone on the 4th", "the original is in the red folder" —
    /// there was nowhere to put any of it. Indexed into `doc_fts` alongside the
    /// document's own text, so a note is findable by searching for it.
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

    /// Soft delete.
    ///
    /// Move to Trash did the file half well — it used the real Trash and never
    /// unlinked anything — and then hard-deleted the row. So a file rescued
    /// from the Trash a week later came back as a brand-new document with no
    /// title, no tags and no history. `deleted_at` keeps the row instead, out
    /// of every ordinary query but ready to be revived, and `deleted_path`
    /// records where in the Trash the file went so Restore can put it back.
    private static func v10(_ db: Database) throws {
        try addColumn(db, table: "documents", column: "deleted_at", declaration: "REAL")
        try addColumn(db, table: "documents", column: "deleted_path", declaration: "TEXT")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_documents_deleted ON documents(deleted_at)")
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
