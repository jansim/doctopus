import Foundation

/// What the pipeline proposed and nobody has decided on yet: tags the model
/// put forward, and the folders the router considered. Both are kept apart from
/// the real assignments so a suggestion never counts as a fact.
extension Store {

    // MARK: - Tag suggestions

    /// Stages a tag the model proposed. When `autoAcceptMatching` is on and the
    /// name exactly matches a tag that already exists, it is assigned directly
    /// instead — there is nothing to review when the suggestion is one the
    /// library already uses.
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

    /// Turns a proposed tag into a real assignment, creating the tag itself
    /// if this is the first time anyone has accepted it.
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

    // MARK: - Path suggestions

    /// Replaces what the router suggested for a document. `candidates` are
    /// best first, with absolute destinations.
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

    // MARK: - Re-routing what is already in the library

    /// What `Router` needs to re-evaluate a document that is already indexed,
    /// built from its current fields rather than a fresh analysis — so a
    /// hand-corrected date or correspondent is what the router sees, not
    /// whatever it read the first time.
    struct RoutingSample: Sendable {
        var filename: String
        var directory: URL
        var text: String
        var findings: DocumentAnalyzer.Findings
    }

    func routingSample(_ docID: Int64) throws -> RoutingSample? {
        try db.first("""
            SELECT d.filename, d.directory, ec.name, et.name, m.doc_date, m.confidence, m.amount,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id)
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.id = ? AND d.missing=0 AND d.deleted_at IS NULL
            """, [.int(docID)]) { row in
            var findings = DocumentAnalyzer.Findings()
            findings.date = row.date(4)
            findings.correspondent = row.stringOrNil(2)
            findings.docType = row.stringOrNil(3)
            findings.amount = row.stringOrNil(6)
            findings.confidence = row.doubleOrNil(5) ?? 0.5
            return RoutingSample(filename: row.string(0), directory: url(forRelative: row.string(1)),
                                 text: row.stringOrNil(7) ?? "", findings: findings)
        }
    }

    /// Documents still awaiting review — approval pending on the document
    /// itself or on its newest processing entry. What a rule change has to
    /// reach, so a suggestion the edit made stale does not linger.
    func pendingDocumentIDs() throws -> [Int64] {
        try db.map("""
            SELECT id FROM documents
            WHERE missing=0 AND deleted_at IS NULL
              AND (approved=0 OR id IN (SELECT doc_id FROM processing WHERE status=0))
            """) { $0.int(0) }
    }
}
