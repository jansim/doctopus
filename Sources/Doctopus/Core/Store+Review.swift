import Foundation

extension Store {

    /// Approval belongs to the document, not to one queue entry. Approving it
    /// settles every entry it has — otherwise an older "imported" entry left
    /// undecided keeps it in Needs Review after the newest one is ticked. Sending
    /// it back for review reopens only the newest, which is the one on show.
    func setDocumentApproved(_ docID: Int64, _ approved: Bool, at when: Date = .now) throws {
        try db.transaction {
            if approved {
                try db.run("UPDATE processing SET status=1 WHERE doc_id=?", [.int(docID)])
            } else {
                try db.run("""
                    UPDATE processing SET status=0
                    WHERE id = (SELECT id FROM processing WHERE doc_id=? ORDER BY id DESC LIMIT 1)
                    """, [.int(docID)])
            }
            try db.run("UPDATE documents SET approved=?, reviewed_at=? WHERE id=?",
                       [.bool(approved), approved ? .double(when.timeIntervalSince1970) : .null, .int(docID)])
        }
    }

    func approveAllPending() throws {
        try db.transaction {
            try db.run("""
                UPDATE documents SET approved=1, reviewed_at=?
                WHERE approved=0 OR id IN (SELECT doc_id FROM processing WHERE status=0)
                """, [.double(Date().timeIntervalSince1970)])
            try db.run("UPDATE processing SET status=1 WHERE status=0")
        }
    }

    /// Throws away what the pipeline guessed; hand edits and extracted text stay.
    /// Only the index changes — the file itself is never touched.
    func discardGeneratedInfo(_ docID: Int64) throws {
        try db.transaction {
            try db.run("""
                UPDATE metadata SET title=NULL, correspondent_id=NULL, doc_type_id=NULL, language=NULL,
                                    summary=NULL, intent=NULL, amount=NULL, source=NULL,
                                    doc_date = CASE WHEN date_source='manual' THEN doc_date END,
                                    date_source = CASE WHEN date_source='manual' THEN 'manual' END
                WHERE doc_id=?
                """, [.int(docID)])
            try db.run("DELETE FROM document_tags WHERE doc_id=? AND auto=1", [.int(docID)])
            try db.run("DELETE FROM tag_suggestions WHERE doc_id=?", [.int(docID)])
            try db.run("DELETE FROM path_suggestions WHERE doc_id=?", [.int(docID)])
            try refreshSearchIndex(docID)
        }
    }

    func similarFolders(for docID: Int64, limit: Int = 4) throws -> [PathSuggestion] {
        guard let (correspondentID, docTypeID, directory) = try db.first("""
            SELECT m.correspondent_id, m.doc_type_id, d.directory FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id WHERE d.id=?
            """, [.int(docID)], { ($0.intOrNil(0), $0.intOrNil(1), $0.string(2)) })
        else { return [] }

        var out: [PathSuggestion] = []
        var seen: Set<String> = [directory]
        for (idColumn, entityID, label) in [("correspondent_id", correspondentID, "from"),
                                            ("doc_type_id", docTypeID, "of type")] {
            guard let entityID, let value = try entityName(entityID)?.nilIfBlank else { continue }
            let rows = try db.map("""
                SELECT d.directory, COUNT(*) FROM documents d
                JOIN metadata m ON m.doc_id = d.id
                WHERE d.missing=0 AND d.deleted_at IS NULL AND d.id<>? AND m.\(idColumn) = ?
                GROUP BY d.directory ORDER BY COUNT(*) DESC LIMIT ?
                """, [.int(docID), .int(entityID), .int(Int64(limit))]) { ($0.string(0), Int($0.int(1))) }
            for (dir, count) in rows where seen.insert(dir).inserted {
                out.append(PathSuggestion(
                    path: absPath(dir), source: "similar",
                    explanation: "\(count) other document\(count == 1 ? "" : "s") \(label) “\(value)” \(count == 1 ? "is" : "are") here"))
            }
        }
        return Array(out.prefix(limit))
    }

    func similarDocuments(for docID: Int64, limit: Int = 5) throws -> [DocumentRow] {
        let text = (try? ocrText(docID)) ?? ""
        guard !text.isEmpty else { return [] }

        let stopWords: Set<String> = [
            "with", "from", "that", "this", "have", "were", "what", "your", "page", "total", "date",
            "und", "der", "die", "das", "mit", "von", "fuer", "für", "den", "dem", "des",
            "eine", "einer", "einem", "einen", "nicht", "auch", "aber", "über", "uber", "oder", "durch"
        ]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }

        var freq: [String: Int] = [:]
        for w in words { freq[w, default: 0] += 1 }
        let topTerms = freq.sorted { $0.value > $1.value }.prefix(8).map(\.key)
        guard !topTerms.isEmpty else { return [] }

        let matchExpr = topTerms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        let similarIDs = try db.map("""
            SELECT rowid FROM doc_fts
            WHERE doc_fts MATCH ? AND rowid <> ?
            ORDER BY bm25(doc_fts, \(Store.bm25Weights)) ASC
            LIMIT ?
            """, [.text(matchExpr), .int(docID), .int(Int64(limit))]) { $0.int(0) }
        guard !similarIDs.isEmpty else { return [] }

        let placeholders = similarIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try db.map("""
            SELECT \(Store.rowColumns)
            \(Store.rowTables)
            WHERE d.id IN (\(placeholders)) AND d.missing=0 AND d.deleted_at IS NULL
            """, similarIDs.map { Database.Value.int($0) }) { documentRow($0) }
        let byID = Dictionary(rows.map { ($0.doc, $0) }, uniquingKeysWith: { a, _ in a })
        return similarIDs.compactMap { byID[$0] }
    }

    func folderAliases(for docID: Int64) throws -> [String] {
        try db.map("SELECT path FROM aliases WHERE doc_id=?", [.int(docID)]) {
            absPath($0.string(0))
        }
    }

    func reviewDocumentIDs() throws -> [Int64] {
        try db.map("SELECT DISTINCT doc_id FROM processing WHERE status=0") { $0.int(0) }
    }

    struct RoutingInput: Sendable {
        var url: URL
        var text: String
        var correspondent: String?
        var docType: String?
        var date: Date?
        var dateSource: String?
    }

    func routingInput(for docID: Int64) throws -> RoutingInput? {
        try db.first("""
            SELECT d.path, (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id),
                   ec.name, et.name, m.doc_date, m.date_source
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.id=? AND d.missing=0 AND d.deleted_at IS NULL
            """, [.int(docID)]) {
            RoutingInput(url: URL(fileURLWithPath: absPath($0.string(0))), text: $0.stringOrNil(1) ?? "",
                         correspondent: $0.stringOrNil(2), docType: $0.stringOrNil(3),
                         date: $0.date(4), dateSource: $0.stringOrNil(5))
        }
    }
}
