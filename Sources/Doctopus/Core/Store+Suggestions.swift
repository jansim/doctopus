import Foundation

extension Store {

    func suggestTag(_ name: String, for docID: Int64, autoAcceptMatching: Bool) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if autoAcceptMatching, let existing = try existingTagID(named: clean) {
            try assign(tag: existing, to: docID, auto: true)
            return
        }
        try db.run("INSERT OR IGNORE INTO tag_suggestions(doc_id, name) VALUES(?,?)",
                   [.int(docID), .text(clean)])
    }

    func tagSuggestions(for docID: Int64) throws -> [TagSuggestion] {
        try db.map("SELECT name FROM tag_suggestions WHERE doc_id=? ORDER BY name COLLATE NOCASE",
                   [.int(docID)]) { TagSuggestion(name: $0.string(0)) }
    }

    func acceptTagSuggestion(_ name: String, for docID: Int64) throws {
        let id = try tagID(named: name)
        try assign(tag: id, to: docID)
        try discardTagSuggestion(name, for: docID)
    }

    func discardTagSuggestion(_ name: String, for docID: Int64) throws {
        try db.run("DELETE FROM tag_suggestions WHERE doc_id=? AND name=?", [.int(docID), .text(name)])
    }

    private func existingTagID(named name: String) throws -> Int64? {
        try db.first("SELECT id FROM tags WHERE name=? COLLATE NOCASE", [.text(name)]) { $0.int(0) }
    }

    func setPathSuggestions(_ candidates: [Router.Candidate], for docID: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM path_suggestions WHERE doc_id=?", [.int(docID)])
            for (rank, c) in candidates.enumerated() {
                try db.run("""
                    INSERT OR IGNORE INTO path_suggestions(doc_id, path, confidence, source, explanation, rank)
                    VALUES(?,?,?,?,?,?)
                    """, [.int(docID), .text(relPath(c.destination.path)), .double(c.confidence),
                          .text(c.rule), .text(c.explanation), .int(Int64(rank))])
            }
        }
    }

    func pathSuggestions(for docID: Int64) throws -> [PathSuggestion] {
        try db.map("""
            SELECT path, confidence, source, explanation FROM path_suggestions
            WHERE doc_id=? ORDER BY rank
            """, [.int(docID)]) {
            PathSuggestion(path: absPath($0.string(0)), confidence: $0.double(1),
                           source: $0.string(2), explanation: $0.stringOrNil(3))
        }
    }

    struct RoutingInput: Sendable {
        var docID: Int64
        var directory: URL
        var subject: Rule.Subject
        var date: Date
        var confidence: Double
    }

    /// What routing would look at for each document still in Needs Review, as
    /// the index has it now — hand edits included. `ids` narrows it; a document
    /// in the list that is no longer awaiting review is left out.
    func routingInputsAwaitingReview(_ ids: [Int64]? = nil) throws -> [RoutingInput] {
        var sql = """
            SELECT d.id, d.directory, d.filename, d.created_at, m.doc_date, ec.name, et.name,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id), m.confidence
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL
              AND d.id IN (SELECT doc_id FROM processing WHERE status=0)
            """
        var params: [Database.Value] = []
        if let ids {
            guard !ids.isEmpty else { return [] }
            sql += " AND d.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
            params = ids.map { .int($0) }
        }
        return try db.map(sql, params) {
            RoutingInput(docID: $0.int(0),
                         directory: URL(fileURLWithPath: absPath($0.string(1)), isDirectory: true),
                         subject: Rule.Subject(text: $0.stringOrNil(7) ?? "", filename: $0.string(2),
                                               correspondent: $0.stringOrNil(5),
                                               docType: $0.stringOrNil(6)),
                         date: $0.date(4) ?? Date(timeIntervalSince1970: $0.double(3)),
                         confidence: $0.doubleOrNil(8) ?? 0)
        }
    }
}
