import Foundation

extension Store {

    func indexFinderTags(docID: Int64, entries: [FinderTags.Entry]) throws {
        try db.run("DELETE FROM finder_tags WHERE doc_id=?", [.int(docID)])
        var seen: Set<String> = []
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            try db.run("INSERT OR IGNORE INTO finder_tags(doc_id, name, label) VALUES(?,?,?)",
                       [.int(docID), .text(name), .int(Int64(entry.label))])
        }
    }

    func finderTagLabels() throws -> [String: Int] {
        var out: [String: Int] = [:]
        try db.query("SELECT name, MAX(label) FROM finder_tags GROUP BY name COLLATE NOCASE") {
            out[$0.string(0)] = Int($0.int(1))
        }
        return out
    }

    func finderTags(docID: Int64) throws -> [String] {
        try db.map("SELECT name FROM finder_tags WHERE doc_id=? ORDER BY name COLLATE NOCASE",
                   [.int(docID)]) { $0.string(0) }
    }

    func finderTags() throws -> [Facet] {
        try db.map("""
            SELECT f.name, COUNT(*) FROM finder_tags f
            JOIN documents d ON d.id = f.doc_id AND d.missing = 0 AND d.deleted_at IS NULL
            GROUP BY f.name COLLATE NOCASE
            ORDER BY f.name COLLATE NOCASE
            """) { Facet(value: $0.string(0), count: Int($0.int(1))) }
    }

    func tags(forDocuments ids: [Int64]) throws -> (own: [Int64: [Tag]], finder: [Int64: [String]]) {
        guard !ids.isEmpty else { return ([:], [:]) }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let args = ids.map { Database.Value.int($0) }

        var own: [Int64: [Tag]] = [:]
        try db.query("""
            SELECT dt.doc_id, t.id, t.name, t.color, t.parent_id, dt.implied, t.icon FROM document_tags dt
            JOIN tags t ON t.id = dt.tag_id
            WHERE dt.doc_id IN (\(placeholders))
            ORDER BY t.name COLLATE NOCASE
            """, args) { row in
            own[row.int(0), default: []].append(
                Tag(tagID: row.int(1), name: row.string(2), color: row.int(3), icon: row.stringOrNil(6),
                    parentID: row.intOrNil(4), implied: row.bool(5)))
        }

        var finder: [Int64: [String]] = [:]
        try db.query("""
            SELECT doc_id, name FROM finder_tags WHERE doc_id IN (\(placeholders))
            ORDER BY name COLLATE NOCASE
            """, args) { finder[$0.int(0), default: []].append($0.string(1)) }

        return (own, finder)
    }
}
