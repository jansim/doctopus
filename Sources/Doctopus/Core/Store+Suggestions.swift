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

    func setPathSuggestions(_ candidates: [PathSuggestion], for docID: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM path_suggestions WHERE doc_id=?", [.int(docID)])
            for (rank, c) in candidates.enumerated() {
                try db.run("""
                    INSERT OR IGNORE INTO path_suggestions(doc_id, path, confidence, source, explanation, rank)
                    VALUES(?,?,?,?,?,?)
                    """, [.int(docID), .text(relPath(c.path)), .double(c.confidence),
                          .text(c.source), .text(c.explanation), .int(Int64(rank))])
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
}
