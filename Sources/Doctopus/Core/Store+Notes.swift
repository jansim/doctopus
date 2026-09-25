import Foundation

extension Store {

    func note(for docID: Int64) throws -> String {
        try db.first("SELECT body FROM notes WHERE doc_id=?", [.int(docID)]) { $0.string(0) } ?? ""
    }

    /// Replaces the document's note; a blank one takes it away. Returns what
    /// the note said before, so the caller can tell an addition from an edit.
    @discardableResult
    func setNote(_ body: String, for docID: Int64) throws -> String {
        let before = try note(for: docID)
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != before else { return before }
        if clean.isEmpty {
            try db.run("DELETE FROM notes WHERE doc_id=?", [.int(docID)])
        } else {
            try db.run("""
                INSERT INTO notes(doc_id, body, updated_at) VALUES(?,?,?)
                ON CONFLICT(doc_id) DO UPDATE SET body=excluded.body, updated_at=excluded.updated_at
                """, [.int(docID), .text(clean), .double(Date().timeIntervalSince1970)])
        }
        try refreshSearchIndex(docID)
        return before
    }
}
