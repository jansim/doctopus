import Foundation

extension Store {

    func notes(for docID: Int64) throws -> [Note] {
        try db.map("""
            SELECT id, body, created_at, updated_at FROM notes
            WHERE doc_id=? ORDER BY created_at DESC, id DESC
            """, [.int(docID)]) {
            Note(id: $0.int(0), body: $0.string(1),
                 createdAt: Date(timeIntervalSince1970: $0.double(2)),
                 updatedAt: $0.date(3))
        }
    }

    @discardableResult
    func addNote(_ body: String, to docID: Int64) throws -> Int64 {
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        let id = try db.run("INSERT INTO notes(doc_id, body, created_at) VALUES(?,?,?)",
                            [.int(docID), .text(clean), .double(Date().timeIntervalSince1970)])
        try refreshSearchIndex(docID)
        return id
    }

    func updateNote(_ id: Int64, body: String) throws {
        guard let docID = try db.first("SELECT doc_id FROM notes WHERE id=?", [.int(id)],
                                       { $0.int(0) }) else { return }
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try db.run("DELETE FROM notes WHERE id=?", [.int(id)])
        } else {
            try db.run("UPDATE notes SET body=?, updated_at=? WHERE id=?",
                       [.text(clean), .double(Date().timeIntervalSince1970), .int(id)])
        }
        try refreshSearchIndex(docID)
    }

    func deleteNote(_ id: Int64) throws {
        guard let docID = try db.first("SELECT doc_id FROM notes WHERE id=?", [.int(id)],
                                       { $0.int(0) }) else { return }
        try db.run("DELETE FROM notes WHERE id=?", [.int(id)])
        try refreshSearchIndex(docID)
    }
}
