import Foundation

/// What the review needs beyond the document itself: one approval state per
/// document, a way to throw away what the pipeline guessed, and more places
/// to file it than the router alone came up with.
extension Store {

    // MARK: - Approval

    /// Approval belongs to the document, not to one queue entry. Approving it
    /// settles every entry it has — otherwise an older "imported" entry left
    /// undecided keeps it in Needs Review after the newest one is ticked. Sending
    /// it back for review reopens only the newest, which is the one on show.
    func setDocumentApproved(_ docID: Int64, _ approved: Bool) throws {
        try db.transaction {
            if approved {
                try db.run("UPDATE processing SET status=1 WHERE doc_id=?", [.int(docID)])
            } else {
                try db.run("""
                    UPDATE processing SET status=0
                    WHERE id = (SELECT id FROM processing WHERE doc_id=? ORDER BY at DESC LIMIT 1)
                    """, [.int(docID)])
            }
            try db.run("UPDATE documents SET approved=? WHERE id=?", [.bool(approved), .int(docID)])
        }
    }

    /// Everything waiting for review, approved in one go.
    func approveAllPending() throws {
        try db.transaction {
            try db.run("""
                UPDATE documents SET approved=1
                WHERE approved=0 OR id IN (SELECT doc_id FROM processing WHERE status=0)
                """)
            try db.run("UPDATE processing SET status=1 WHERE status=0")
        }
    }

    // MARK: - Discarding generated information

    /// Throws away what the pipeline worked out for a document — title,
    /// correspondent, type, language, summary, intent, amount and the date it
    /// guessed — along with the tags rules assigned and every suggestion still
    /// pending. What someone typed is kept: a date set by hand, tags added by
    /// hand, custom fields. The extracted text stays too, so Analyze can be run
    /// again from scratch.
    ///
    /// Only the index changes. The file itself is not touched.
    func discardGeneratedInfo(_ docID: Int64) throws {
        try db.transaction {
            try db.run("""
                UPDATE metadata SET title=NULL, correspondent=NULL, doc_type=NULL, language=NULL,
                                    summary=NULL, intent=NULL, amount=NULL, confidence=NULL,
                                    source=NULL,
                                    doc_date = CASE WHEN date_source='manual' THEN doc_date END,
                                    date_source = CASE WHEN date_source='manual' THEN 'manual' END
                WHERE doc_id=?
                """, [.int(docID)])
            try db.run("DELETE FROM document_tags WHERE doc_id=? AND auto=1", [.int(docID)])
            try db.run("DELETE FROM tag_suggestions WHERE doc_id=?", [.int(docID)])
            try db.run("DELETE FROM path_suggestions WHERE doc_id=?", [.int(docID)])
        }
    }

    // MARK: - More places to file a document

    /// Folders where documents like this one already live — same
    /// correspondent first, then same type — busiest first. The library's own
    /// habits are often a better guess than any rule, and they cost nothing to
    /// offer.
    func similarFolders(for docID: Int64, limit: Int = 4) throws -> [PathSuggestion] {
        guard let (correspondent, docType, directory) = try db.first("""
            SELECT m.correspondent, m.doc_type, d.directory FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id WHERE d.id=?
            """, [.int(docID)], { ($0.stringOrNil(0), $0.stringOrNil(1), $0.string(2)) })
        else { return [] }

        var out: [PathSuggestion] = []
        var seen: Set<String> = [directory]
        for (column, value, label) in [("correspondent", correspondent, "from"),
                                       ("doc_type", docType, "of type")] {
            guard let value = value?.nilIfBlank else { continue }
            let rows = try db.map("""
                SELECT d.directory, COUNT(*) FROM documents d
                JOIN metadata m ON m.doc_id = d.id
                WHERE d.missing=0 AND d.id<>? AND m.\(column) = ? COLLATE NOCASE
                GROUP BY d.directory ORDER BY COUNT(*) DESC LIMIT ?
                """, [.int(docID), .text(value), .int(Int64(limit))]) { ($0.string(0), Int($0.int(1))) }
            let total = max(1, rows.reduce(0) { $0 + $1.1 })
            for (dir, count) in rows where seen.insert(dir).inserted {
                out.append(PathSuggestion(
                    path: absPath(dir), confidence: Double(count) / Double(total), source: "similar",
                    explanation: "\(count) other document\(count == 1 ? "" : "s") \(label) “\(value)” \(count == 1 ? "is" : "are") here"))
            }
        }
        return Array(out.prefix(limit))
    }

    /// The folders a document has been filed in as an alias by hand — its
    /// secondary places. Tag aliases are the tag's business and are left out.
    func folderAliases(for docID: Int64) throws -> [String] {
        try db.map("SELECT path FROM aliases WHERE doc_id=? AND tag_id IS NULL", [.int(docID)]) {
            absPath($0.string(0))
        }
    }
}
