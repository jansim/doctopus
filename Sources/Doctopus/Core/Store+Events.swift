import Foundation

extension Store {

    static let queueLength = 500

    func logProcessing(docID: Int64, action: EventAction, detail: String?,
                       rule: String?, from: String?, to: String?, approved: Bool) throws {
        let eventID = try db.run("""
            INSERT INTO events(doc_id, at, action, detail, rule, from_path, to_path)
            VALUES(?,?,?,?,?,?,?)
            """, [.int(docID), .double(Date().timeIntervalSince1970), .text(action.rawValue), .text(detail),
                  .text(rule), .text(from), .text(to)])
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

    /// Hand edits closer together than this are grouped into one history entry.
    static let editGroupingWindow: TimeInterval = 5 * 60

    func logEdit(docID: Int64, detail: String, at now: Date = Date()) throws {
        if let last = try db.first("""
            SELECT id, at, action, detail FROM events
            WHERE doc_id=? ORDER BY at DESC, id DESC LIMIT 1
            """, [.int(docID)], { (id: $0.int(0), at: $0.double(1),
                                   action: $0.string(2), detail: $0.stringOrNil(3)) }),
           last.action == EventAction.edited.rawValue,
           now.timeIntervalSince1970 - last.at < Store.editGroupingWindow {
            try db.run("UPDATE events SET at=?, detail=? WHERE id=?",
                       [.double(now.timeIntervalSince1970),
                        .text(Self.mergedEditDetail(last.detail, detail)), .int(last.id)])
            return
        }
        try db.run("INSERT INTO events(doc_id, at, action, detail) VALUES(?,?,?,?)",
                   [.int(docID), .double(now.timeIntervalSince1970),
                    .text(EventAction.edited.rawValue), .text(detail)])
    }

    static func mergedEditDetail(_ existing: String?, _ addition: String) -> String {
        func subject(_ line: String) -> String {
            if let arrow = line.range(of: " → ") { return String(line[..<arrow.lowerBound]) }
            if line.hasSuffix(" cleared") { return String(line.dropLast(" cleared".count)) }
            return line
        }
        let key = subject(addition)
        var lines = (existing ?? "").split(separator: "\n").map(String.init)
        lines.removeAll { subject($0) == key }
        lines.append(addition)
        return lines.joined(separator: "\n")
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

    func history(for docID: Int64, limit: Int = 200) throws -> [HistoryEvent] {
        try db.map("""
            SELECT id, at, action, detail, rule, from_path, to_path
            FROM events WHERE doc_id=? ORDER BY at DESC, id DESC LIMIT ?
            """, [.int(docID), .int(limit)]) {
            HistoryEvent(id: $0.int(0), at: Date(timeIntervalSince1970: $0.double(1)),
                         action: EventAction(stored: $0.string(2)), detail: $0.stringOrNil(3),
                         rule: $0.stringOrNil(4),
                         fromPath: $0.stringOrNil(5).map { absPath($0) },
                         toPath: $0.stringOrNil(6).map { absPath($0) })
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
            WHERE doc_id=? AND id>? AND action IN (\(actions))
              AND from_path IS NOT NULL AND to_path IS NOT NULL
            ORDER BY id DESC LIMIT 1
            """, [.int(docID), .int(mark)]) {
            UndoableEvent(id: $0.int(0), docID: $0.int(1), action: EventAction(stored: $0.string(2)),
                          from: absPath($0.string(3)), to: absPath($0.string(4)))
        }
    }

    func deleteEvent(_ id: Int64) throws {
        try db.run("DELETE FROM events WHERE id=?", [.int(id)])
    }
}
