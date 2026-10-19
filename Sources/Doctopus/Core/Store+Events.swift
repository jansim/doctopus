import Foundation

extension Store {

    static let queueLength = 500

    /// A step of the pipeline, logged whether or not it wrote anything, and
    /// queued for review.
    func logProcessing(docID: Int64, action: EventAction, detail: String?,
                       rule: String?, from: String?, to: String?, approved: Bool) throws {
        try record(action, doc: docID, detail, rule: rule, from: from, to: to,
                   queued: approved, always: true) {}
    }

    /// A step of the pipeline together with everything it writes, as one
    /// change that can be reverted.
    @discardableResult
    func logProcessing<T: Sendable>(docID: Int64, action: EventAction, detail: String?, approved: Bool,
                                    _ body: @Sendable (isolated Store) throws -> T) throws -> T {
        try record(action, doc: docID, detail, queued: approved, always: true) { try body(self) }
    }

    func queue(_ eventID: Int64, docID: Int64, approved: Bool) throws {
        try db.run("INSERT INTO processing(event_id, doc_id, status) VALUES(?,?,?)",
                   [.int(eventID), .int(docID), .bool(approved)])
        if !approved {
            try db.run("UPDATE documents SET approved=0, reviewed_at=NULL WHERE id=?", [.int(docID)])
        }
        // Keep the view bounded. Ids are monotonic, so this is a range delete
        // rather than a sort of the whole table on every insert. The offset is
        // one short of the length because it names the oldest row to keep.
        try db.run("""
            DELETE FROM processing
            WHERE id < COALESCE((SELECT id FROM processing ORDER BY id DESC LIMIT 1 OFFSET ?), 0)
            """, [.int(Store.queueLength - 1)])
    }

    /// A hand edit that wrote nothing `record` keeps — a Finder tag lives on
    /// the file — so it is on record, but cannot be reverted from the log.
    func logEdit(docID: Int64, detail: String, at now: Date = Date()) throws {
        try insertEvent(doc: docID, action: .edited, detail: detail, at: now)
    }

    func processingQueue(limit: Int = 200) throws -> [ProcessingEntry] {
        try db.map("""
            SELECT p.id, p.doc_id, e.at, e.action, e.detail, e.rule,
                   e.from_path, e.to_path, p.status, d.filename, d.missing
            FROM processing p
            JOIN events e ON e.id = p.event_id
            JOIN documents d ON d.id = p.doc_id
            ORDER BY e.at DESC LIMIT ?
            """, [.int(limit)]) {
            ProcessingEntry(id: $0.int(0), docID: $0.int(1),
                            at: Date(timeIntervalSince1970: $0.double(2)), action: EventAction(stored: $0.string(3)),
                            detail: $0.stringOrNil(4), rule: $0.stringOrNil(5),
                            fromPath: $0.stringOrNil(6), toPath: $0.stringOrNil(7),
                            approved: $0.bool(8), filename: $0.string(9), missing: $0.bool(10))
        }
    }

    struct UndoableEvent: Sendable {
        var id: Int64
        var docID: Int64
        var action: EventAction
        var from: String
        var to: String
    }

    /// Where the event log stands, so an undo can take back what came after.
    func latestEventID() throws -> Int64 {
        try db.first("SELECT COALESCE(MAX(id), 0) FROM events") { $0.int(0) } ?? 0
    }

    func lastUndoableEvent(of docID: Int64, after mark: Int64) throws -> UndoableEvent? {
        let actions = EventAction.undoable.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        return try db.first("""
            SELECT id, doc_id, action, from_path, to_path FROM events
            WHERE doc_id=? AND id>? AND action IN (\(actions)) AND reverted_at IS NULL
              AND from_path IS NOT NULL AND to_path IS NOT NULL
            ORDER BY id DESC LIMIT 1
            """, [.int(docID), .int(mark)]) {
            UndoableEvent(id: $0.int(0), docID: $0.int(1), action: EventAction(stored: $0.string(2)),
                          from: absPath($0.string(3)), to: absPath($0.string(4)))
        }
    }

    func undoableEvent(_ id: Int64) throws -> UndoableEvent? {
        try db.first("""
            SELECT id, doc_id, action, from_path, to_path FROM events
            WHERE id=? AND doc_id IS NOT NULL AND from_path IS NOT NULL AND to_path IS NOT NULL
            """, [.int(id)]) {
            UndoableEvent(id: $0.int(0), docID: $0.int(1), action: EventAction(stored: $0.string(2)),
                          from: absPath($0.string(3)), to: absPath($0.string(4)))
        }
    }

    func deleteEvent(_ id: Int64) throws {
        try db.run("DELETE FROM events WHERE id=?", [.int(id)])
    }
}
