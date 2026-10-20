import Foundation

/// The change log. Each change is one `events` row; one that went through
/// `record` also keeps every row it wrote in `event_rows`, as it was before
/// and after, which is what reverting it puts back.
///
/// Rows are captured by temporary triggers on this connection, and only while
/// `record` runs, so what the scan writes to keep up with the disk is never
/// mistaken for a change to take back.
extension Store {

    /// The log itself; the library settings, which the app holds a copy of
    /// in memory; and what mirrors the disk, which only changes with the files.
    /// The search index is rebuilt from the rows it is made of.
    static let uncapturedTables: Set<String> = [
        "events", "event_rows", "settings", "finder_tags", "aliases",
    ]

    /// Where and what a document's file is. A revert never writes these back:
    /// the file did not go back with it.
    static let fileColumns: Set<String> = [
        "path", "directory", "filename", "ext", "hash", "original_hash", "size", "original_size",
        "mtime", "file_id", "missing", "missing_since", "deleted_at", "deleted_path",
    ]

    struct Recording {
        var action: EventAction
        var docID: Int64?
        var detail: String?
        var rule: String?
        var from: String?
        var to: String?
        /// Whether the review queue gets an entry, and whether it is approved.
        var queued: Bool?
        /// Logged even when it wrote nothing, as the pipeline's steps are.
        var always: Bool
        var reverts: Int64?
    }

    /// Created per connection, so they follow whatever columns this build's
    /// schema has, and never travel with a backup.
    nonisolated static func installChangeCapture(_ db: Database) throws {
        try db.exec("""
            CREATE TEMP TABLE IF NOT EXISTS capture_state(recording INTEGER NOT NULL);
            CREATE TEMP TABLE IF NOT EXISTS captured_rows(
                seq INTEGER PRIMARY KEY, tbl TEXT NOT NULL, op TEXT NOT NULL, old TEXT, new TEXT);
            DELETE FROM capture_state;
            INSERT INTO capture_state VALUES(0);
            """)
        let tables = try db.map("SELECT name FROM sqlite_master WHERE type='table'") { $0.string(0) }
            .filter { !$0.hasPrefix("sqlite_") && !$0.hasPrefix("doc_fts") && !uncapturedTables.contains($0) }
        for table in tables {
            let columns = try db.map("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) }
            guard !columns.isEmpty else { continue }
            func row(_ alias: String) -> String {
                "json_object(" + columns.map { "'\($0)', \(alias).\"\($0)\"" }.joined(separator: ", ") + ")"
            }
            for (op, old, new) in [("insert", "NULL", row("NEW")),
                                   ("update", row("OLD"), row("NEW")),
                                   ("delete", row("OLD"), "NULL")] {
                try db.exec("""
                    CREATE TEMP TRIGGER IF NOT EXISTS capture_\(table)_\(op)
                    AFTER \(op.uppercased()) ON main."\(table)"
                    WHEN (SELECT recording FROM capture_state)
                    BEGIN
                        INSERT INTO captured_rows(tbl, op, old, new) VALUES('\(table)', '\(op)', \(old), \(new));
                    END;
                    """)
            }
        }
    }

    /// Runs `body` as one change: one event, carrying every row it wrote, so
    /// it can be reverted as a whole. Inside another recording it becomes part
    /// of that one. Nothing is logged for a change that wrote nothing, unless
    /// `always` says the step is worth a line regardless.
    @discardableResult
    func record<T>(_ action: EventAction = .edited, doc docID: Int64?, _ detail: String?,
                   rule: String? = nil, from: String? = nil, to: String? = nil,
                   queued: Bool? = nil, always: Bool = false, reverts: Int64? = nil,
                   _ body: () throws -> T) throws -> T {
        if recording != nil {
            let result = try body()
            if recording?.detail == nil { recording?.detail = detail }
            return result
        }
        recording = Recording(action: action, docID: docID, detail: detail, rule: rule, from: from,
                              to: to, queued: queued, always: always, reverts: reverts)
        defer { recording = nil }
        // Not `db.transaction { … }`: a closure capturing `body` is a data race
        // to the region checker, since `body` is isolated to this actor.
        let scope = try db.begin()
        do {
            try db.run("DELETE FROM captured_rows")
            try db.run("UPDATE capture_state SET recording=1")
            let result = try body()
            try db.run("UPDATE capture_state SET recording=0")
            try commitRecording()
            try db.commit(scope)
            return result
        } catch {
            db.rollback(scope)
            throw error
        }
    }

    /// `record` for callers outside the store: `body` runs on it, in one go.
    @discardableResult
    func change<T: Sendable>(_ action: EventAction = .edited, doc docID: Int64?, _ detail: String?,
                             _ body: @Sendable (isolated Store) throws -> T) throws -> T {
        try record(action, doc: docID, detail) { try body(self) }
    }

    /// Replaces the line a recording will be logged with, for a change that
    /// only knows what it did once it has done it.
    func describe(_ detail: String) {
        recording?.detail = detail
    }

    private func commitRecording() throws {
        guard let r = recording else { return }
        // An update that left a row as it was changed nothing.
        try db.run("DELETE FROM captured_rows WHERE op='update' AND old IS new")
        let captured = try db.first("SELECT COUNT(*) FROM captured_rows") { $0.int(0) } ?? 0
        guard captured > 0 || r.always else { return }
        if captured > 0, let previous = try foldableEdit(r) {
            try fold(into: previous, detail: r.detail)
            return
        }
        let eventID = try insertEvent(doc: r.docID, action: r.action, detail: r.detail, rule: r.rule,
                                      from: r.from, to: r.to, reverts: r.reverts)
        if captured > 0 {
            try db.run("""
                INSERT INTO event_rows(event_id, seq, tbl, op, old, new)
                SELECT ?, seq, tbl, op, old, new FROM captured_rows ORDER BY seq
                """, [.int(eventID)])
            try db.run("DELETE FROM captured_rows")
        }
        if let approved = r.queued, let docID = r.docID {
            try queue(eventID, docID: docID, approved: approved)
        }
    }

    // MARK: Folding

    /// A field typed into again sooner than this after the last time joins
    /// that change, so fixing a typo is not a change of its own.
    static let editFoldingWindow: TimeInterval = 5 * 60

    /// The hand edit a new one folds into: the last thing logged for the
    /// document, an edit of the same field, still in effect, with rows to
    /// revert, and recent enough. Reverting the two together goes back to
    /// before the first.
    private func foldableEdit(_ r: Recording, at now: Date = Date())
        throws -> (id: Int64, detail: String?)? {
        guard r.action == .edited, let docID = r.docID,
              let subject = r.detail.flatMap(Self.editSubject) else { return nil }
        guard let last = try db.first("""
            SELECT id, at, action, detail, reverted_at IS NULL,
                   EXISTS (SELECT 1 FROM event_rows r WHERE r.event_id = events.id)
            FROM events WHERE doc_id=? ORDER BY id DESC LIMIT 1
            """, [.int(docID)], {
                (id: $0.int(0), at: $0.double(1), action: $0.string(2), detail: $0.stringOrNil(3),
                 inEffect: $0.bool(4), hasRows: $0.bool(5))
            }) else { return nil }
        let age = now.timeIntervalSince1970 - last.at
        guard last.action == EventAction.edited.rawValue, last.inEffect, last.hasRows,
              age >= 0, age < Self.editFoldingWindow,
              last.detail.flatMap(Self.editSubject) == subject else { return nil }
        return (last.id, last.detail)
    }

    private func fold(into previous: (id: Int64, detail: String?), detail: String?) throws {
        let offset = try db.first("SELECT COALESCE(MAX(seq), 0) FROM event_rows WHERE event_id=?",
                                  [.int(previous.id)]) { $0.int(0) } ?? 0
        try db.run("""
            INSERT INTO event_rows(event_id, seq, tbl, op, old, new)
            SELECT ?, seq + ?, tbl, op, old, new FROM captured_rows ORDER BY seq
            """, [.int(previous.id), .int(offset)])
        try db.run("DELETE FROM captured_rows")
        // A note added and then edited is, taken together, still a note added.
        let merged = previous.detail == "Note added" && detail == "Note edited" ? previous.detail : detail
        try db.run("UPDATE events SET at=?, detail=? WHERE id=?",
                   [.double(Date().timeIntervalSince1970), .text(merged), .int(previous.id)])
    }

    /// What a hand edit's line is about — "Title" for "Title → Invoice" or
    /// "Title cleared" — or nil for an edit that is never folded, such as a tag.
    nonisolated static func editSubject(_ detail: String) -> String? {
        let line = detail.split(separator: "\n").first.map(String.init) ?? detail
        if let arrow = line.range(of: " → ") { return String(line[..<arrow.lowerBound]) }
        if line.hasSuffix(" cleared") { return String(line.dropLast(" cleared".count)) }
        if line.hasPrefix("Note ") { return "Note" }
        return nil
    }

    @discardableResult
    func insertEvent(doc docID: Int64?, action: EventAction, detail: String?, rule: String? = nil,
                     from: String? = nil, to: String? = nil, reverts: Int64? = nil,
                     at: Date = Date()) throws -> Int64 {
        let id = try db.run("""
            INSERT INTO events(doc_id, at, action, detail, rule, from_path, to_path, reverts)
            VALUES(?,?,?,?,?,?,?,?)
            """, [.int(docID), .double(at.timeIntervalSince1970), .text(action.rawValue), .text(detail),
                  .text(rule), .text(from), .text(to), .int(reverts)])
        try pruneHistory()
        return id
    }

    // MARK: Keeping

    /// How many changes the log keeps; 0 keeps every one.
    func setHistoryLimit(_ limit: Int) throws {
        historyLimit = max(0, limit)
        try pruneHistory()
    }

    /// Ids are monotonic, so this is a range delete. What a change wrote, and
    /// its review queue entry, go with it.
    private func pruneHistory() throws {
        guard historyLimit > 0 else { return }
        try db.run("""
            DELETE FROM events
            WHERE id <= COALESCE((SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET ?), 0)
            """, [.int(historyLimit)])
    }

    // MARK: Reading

    private static let eventColumns = """
        e.id, e.at, e.action, e.detail, e.rule, e.from_path, e.to_path, e.doc_id, d.filename,
        e.reverted_at IS NOT NULL,
        EXISTS (SELECT 1 FROM event_rows r WHERE r.event_id = e.id),
        EXISTS (SELECT 1 FROM event_rows r WHERE r.event_id = e.id AND r.tbl = 'documents' AND r.op = 'insert'),
        d.original_size IS NOT NULL AND d.deleted_at IS NULL
        FROM events e LEFT JOIN documents d ON d.id = e.doc_id
        """

    private func historyEvent(_ row: Database.Row) -> HistoryEvent {
        let action = EventAction(stored: row.string(2))
        let from = row.stringOrNil(5).map { absPath($0) }
        let to = row.stringOrNil(6).map { absPath($0) }
        let reverted = row.bool(9)
        return HistoryEvent(
            id: row.int(0), at: Date(timeIntervalSince1970: row.double(1)), action: action,
            detail: row.stringOrNil(3), rule: row.stringOrNil(4), fromPath: from, toPath: to,
            docID: row.intOrNil(7), filename: row.stringOrNil(8), reverted: reverted,
            revert: Store.revertKind(action, hasPaths: from != nil && to != nil, hasRows: row.bool(10),
                                     createsDocument: row.bool(11), keepsOriginal: row.bool(12),
                                     reverted: reverted))
    }

    /// Newest first.
    func history(for docID: Int64, limit: Int = 200) throws -> [HistoryEvent] {
        try db.map("SELECT \(Self.eventColumns) WHERE e.doc_id=? ORDER BY e.id DESC LIMIT ?",
                   [.int(docID), .int(limit)]) { historyEvent($0) }
    }

    /// Every change to the library, newest first.
    func changeLog(limit: Int = 200) throws -> [HistoryEvent] {
        try db.map("SELECT \(Self.eventColumns) ORDER BY e.id DESC LIMIT ?", [.int(limit)]) { historyEvent($0) }
    }

    func event(_ id: Int64) throws -> HistoryEvent? {
        try db.first("SELECT \(Self.eventColumns) WHERE e.id=?", [.int(id)]) { historyEvent($0) }
    }

    /// What reverting an event takes, or nil when it cannot be: taking back
    /// what created a document would delete it, and a step that recorded
    /// nothing it wrote has nothing to put back.
    nonisolated static func revertKind(_ action: EventAction, hasPaths: Bool, hasRows: Bool,
                                       createsDocument: Bool, keepsOriginal: Bool,
                                       reverted: Bool) -> RevertKind? {
        guard !reverted else { return nil }
        if EventAction.undoable.contains(action) { return hasPaths ? .file : nil }
        if action == .optimized { return keepsOriginal ? .optimization : nil }
        return hasRows && !createsDocument ? .rows : nil
    }

    // MARK: Reverting

    enum RevertError: LocalizedError {
        case notRevertible
        case clash(String)

        var errorDescription: String? {
            switch self {
            case .notRevertible:
                return "That change cannot be reverted."
            case .clash(let reason):
                return "Something changed since stands in its way (\(reason))."
            }
        }
    }

    nonisolated static func revertDetail(_ event: HistoryEvent) -> String {
        "Reverted: " + event.summary
    }

    /// Puts back every row an event wrote, newest first, as a change of its
    /// own, which can be reverted in turn. Rows of documents or anything else
    /// that is gone since are skipped: there is nothing left to put them on.
    func revertRows(of eventID: Int64) throws {
        guard let event = try self.event(eventID), event.revert == .rows else { throw RevertError.notRevertible }
        let original = try db.first("SELECT reverts FROM events WHERE id=?", [.int(eventID)]) { $0.intOrNil(0) } ?? nil
        let rows = try db.map("SELECT tbl, op, old, new FROM event_rows WHERE event_id=? ORDER BY seq DESC",
                              [.int(eventID)]) {
            CapturedRow(table: $0.string(0), op: $0.string(1), old: $0.stringOrNil(2), new: $0.stringOrNil(3))
        }
        var touched: [CapturedRow] = []
        do {
            try record(.reverted, doc: event.docID, Self.revertDetail(event), reverts: eventID) {
                for row in rows {
                    if try putBack(row) { touched.append(row) }
                }
                let now = Date().timeIntervalSince1970
                try db.run("UPDATE events SET reverted_at=? WHERE id=?", [.double(now), .int(eventID)])
                // Reverting a revert puts the change it took back in effect again.
                if let original {
                    try db.run("UPDATE events SET reverted_at=NULL WHERE id=?", [.int(original)])
                }
            }
        } catch let error as Database.Error {
            throw RevertError.clash(error.reason)
        }
        try refreshSearchIndex(documentsAffected(by: touched))
        fieldCache = nil
        ruleMatchCache = RuleMatchCache()
    }

    /// For a change taken back on disk rather than through its rows: marked
    /// reverted, with the revert logged beside it.
    func markEventReverted(_ eventID: Int64) throws {
        guard let event = try self.event(eventID) else { return }
        try db.transaction {
            try db.run("UPDATE events SET reverted_at=? WHERE id=?",
                       [.double(Date().timeIntervalSince1970), .int(eventID)])
            try insertEvent(doc: event.docID, action: .reverted, detail: Self.revertDetail(event),
                            reverts: eventID)
        }
    }

    struct CapturedRow: Sendable {
        var table: String
        var op: String
        var old: String?
        var new: String?
    }

    /// Whether anything a change wrote has been changed again since, so that
    /// reverting it would take back what came after it too.
    func changedSince(_ eventID: Int64) throws -> Bool {
        guard let event = try self.event(eventID), let kind = event.revert else { return false }
        switch kind {
        case .optimization:
            return false
        case .file:
            guard ![.aliased, .unfiled].contains(event.action),
                  let docID = event.docID, let to = event.toPath,
                  let current = try documentPath(docID) else { return false }
            return Store.canonical(current) != Store.canonical(to)
        case .rows:
            let rows = try db.map("SELECT tbl, op, old, new FROM event_rows WHERE event_id=? ORDER BY seq DESC",
                                  [.int(eventID)]) {
                CapturedRow(table: $0.string(0), op: $0.string(1), old: $0.stringOrNil(2), new: $0.stringOrNil(3))
            }
            // Only how the change left each row counts: a folded edit also
            // passed through the typo it then fixed.
            var seen: Set<String> = []
            for row in rows {
                guard let identity = try identity(of: row), seen.insert(identity).inserted else { continue }
                if try differsNow(row) { return true }
            }
            return false
        }
    }

    /// The table and primary key a captured row is about.
    private func identity(of row: CapturedRow) throws -> String? {
        guard let json = row.new ?? row.old else { return nil }
        let keys = try db.map("SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk",
                              [.text(row.table)]) { $0.string(0) }
        guard !keys.isEmpty else { return nil }
        let values = keys.map { "json_extract(?1, '$.\"\($0)\"')" }.joined(separator: ", ")
        return try db.first("SELECT json_array(\(values))", [.text(json)]) { row.table + $0.string(0) }
    }

    /// Columns whose values differ between two captured rows, or that only one has.
    private func differingColumns(_ a: String, _ b: String) throws -> [String] {
        try db.map("""
            SELECT o.key FROM json_each(?1) o LEFT JOIN json_each(?2) n ON n.key = o.key
            WHERE n.key IS NULL OR o.type IS NOT n.type OR o.atom IS NOT n.atom
            """, [.text(a), .text(b)]) { $0.string(0) }
    }

    /// Whether the row is no longer as this change left it: gone, back, or
    /// holding something else in a column the change wrote.
    private func differsNow(_ row: CapturedRow) throws -> Bool {
        let columns = try db.map("SELECT name, pk FROM pragma_table_info(?)", [.text(row.table)]) {
            (name: $0.string(0), pk: $0.int(1))
        }
        let keys = columns.filter { $0.pk > 0 }.sorted { $0.pk < $1.pk }.map(\.name)
        guard !keys.isEmpty, let identity = row.new ?? row.old else { return false }
        let skipped = row.table == "documents" ? Self.fileColumns : []
        let names = columns.map(\.name).filter { !skipped.contains($0) }
        let object = "json_object(" + names.map { "'\($0)', \"\($0)\"" }.joined(separator: ", ") + ")"
        let matching = keys.map { "\"\($0)\" IS json_extract(?1, '$.\"\($0)\"')" }.joined(separator: " AND ")
        let current = try db.first("SELECT \(object) FROM \"\(row.table)\" WHERE \(matching)",
                                   [.text(identity)]) { $0.string(0) }

        switch (row.op, row.old, row.new) {
        case ("delete", _, _):
            return current != nil
        case ("insert", _, let new?):
            guard let current else { return true }
            return try !differingColumns(current, new).filter { names.contains($0) }.isEmpty
        case ("update", let old?, let new?):
            guard let current else { return true }
            let written = Set(try differingColumns(old, new))
            return try differingColumns(current, new).contains { written.contains($0) && names.contains($0) }
        default:
            return false
        }
    }

    /// False when the row was skipped, as one whose document or parent is gone.
    private func putBack(_ row: CapturedRow) throws -> Bool {
        let columns = try db.map("SELECT name, pk FROM pragma_table_info(?)", [.text(row.table)]) {
            (name: $0.string(0), pk: $0.int(1))
        }
        let keys = columns.filter { $0.pk > 0 }.sorted { $0.pk < $1.pk }.map(\.name)
        guard !keys.isEmpty else { return false }
        let present = Set(columns.map(\.name))
        func value(_ column: String, _ parameter: Int) -> String { "json_extract(?\(parameter), '$.\"\(column)\"')" }
        func matching(_ parameter: Int) -> String {
            keys.map { "\"\($0)\" IS \(value($0, parameter))" }.joined(separator: " AND ")
        }

        switch (row.op, row.old, row.new) {
        case ("insert", _, let new?):
            try db.run("DELETE FROM \"\(row.table)\" WHERE \(matching(1))", [.text(new)])
            return true

        case ("update", let old?, let new?):
            let changed = try differingColumns(old, new)
            let skipped = row.table == "documents" ? Self.fileColumns : []
            let restored = changed.filter { present.contains($0) && !skipped.contains($0) }
            guard !restored.isEmpty else { return false }
            let assignments = restored.map { "\"\($0)\" = \(value($0, 1))" }.joined(separator: ", ")
            return try skippingOrphans {
                try db.run("UPDATE \"\(row.table)\" SET \(assignments) WHERE \(matching(2))",
                           [.text(old), .text(new)])
            }

        case ("delete", let old?, _):
            let stored = try db.map("SELECT key FROM json_each(?)", [.text(old)]) { $0.string(0) }
                .filter { present.contains($0) }
            guard !stored.isEmpty else { return false }
            let names = stored.map { "\"\($0)\"" }.joined(separator: ", ")
            let values = stored.map { value($0, 1) }.joined(separator: ", ")
            return try skippingOrphans {
                try db.run("INSERT INTO \"\(row.table)\"(\(names)) VALUES(\(values))", [.text(old)])
            }

        default:
            return false
        }
    }

    /// A row that points at something since deleted — a document purged, a
    /// tag deleted — cannot go back, and is left out rather than failing the rest.
    private func skippingOrphans(_ body: () throws -> Void) throws -> Bool {
        do {
            try db.savepoint(body)
            return true
        } catch let error as Database.Error where error.isForeignKeyFailure {
            return false
        }
    }

    /// The documents whose search text a revert of these rows may change.
    private func documentsAffected(by rows: [CapturedRow]) throws -> [Int64] {
        var docs: Set<Int64> = []
        for row in rows {
            for json in [row.old, row.new].compactMap({ $0 }) {
                guard let data = json.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { continue }
                func id(_ key: String) -> Int64? { (object[key] as? NSNumber)?.int64Value }
                if let doc = id(row.table == "documents" ? "id" : "doc_id") { docs.insert(doc) }
                switch row.table {
                case "tags":
                    if let tag = id("id") { docs.formUnion(try documentIDs(withTag: tag)) }
                case "entities":
                    if let entity = id("id") {
                        docs.formUnion(try db.map("""
                            SELECT doc_id FROM metadata WHERE correspondent_id=?1 OR doc_type_id=?1
                            """, [.int(entity)]) { $0.int(0) })
                    }
                case "fields":
                    if let field = id("id") {
                        docs.formUnion(try db.map("SELECT doc_id FROM field_values WHERE field_id=?",
                                                  [.int(field)]) { $0.int(0) })
                    }
                default:
                    break
                }
            }
        }
        return try docs.sorted().filter {
            try db.first("SELECT 1 FROM documents WHERE id=?", [.int($0)]) { _ in true } ?? false
        }
    }
}

extension Database.Error {
    /// What went wrong, without the SQL.
    var reason: String {
        switch self {
        case .open(let m), .sql(_, let m): return m
        }
    }
}
