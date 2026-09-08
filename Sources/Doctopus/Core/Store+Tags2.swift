import Foundation

extension Store {

    // MARK: - Per-value icons

    /// Icons chosen for individual values of a field — one for “Invoice”,
    /// another for “Tax”. Unset values fall back to the field's own icon.
    func setValueIcon(field: Field, value: String, icon: String?) throws {
        guard let icon, !icon.isEmpty else {
            try db.run("DELETE FROM value_icons WHERE field_id=? AND value=?",
                       [.int(field.id), .text(value)])
            return
        }
        try db.run("""
            INSERT INTO value_icons(field_id, value, icon) VALUES(?,?,?)
            ON CONFLICT(field_id, value) DO UPDATE SET icon=excluded.icon
            """, [.int(field.id), .text(value), .text(icon)])
    }

    func valueIcons(field: Field) throws -> [String: String] {
        var out: [String: String] = [:]
        try db.query("SELECT value, icon FROM value_icons WHERE field_id=?", [.int(field.id)]) {
            out[$0.string(0)] = $0.string(1)
        }
        return out
    }

    // MARK: - Finder tags

    /// Replaces the indexed copy of one document's Finder tags. The file itself
    /// is the source of truth; this only mirrors it so the tags can be counted
    /// and filtered without reading every file.
    func indexFinderTags(docID: Int64, names: [String]) throws {
        try db.run("DELETE FROM finder_tags WHERE doc_id=?", [.int(docID)])
        for name in Set(names.map { $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            try db.run("INSERT OR IGNORE INTO finder_tags(doc_id, name) VALUES(?,?)",
                       [.int(docID), .text(name)])
        }
    }

    func finderTags(docID: Int64) throws -> [String] {
        try db.map("SELECT name FROM finder_tags WHERE doc_id=? ORDER BY name COLLATE NOCASE",
                   [.int(docID)]) { $0.string(0) }
    }

    /// Every Finder tag in the library, with how many documents carry it.
    func finderTags() throws -> [Facet] {
        try db.map("""
            SELECT f.name, COUNT(*) FROM finder_tags f
            JOIN documents d ON d.id = f.doc_id AND d.missing = 0
            GROUP BY f.name COLLATE NOCASE
            ORDER BY f.name COLLATE NOCASE
            """) { Facet(value: $0.string(0), count: Int($0.int(1))) }
    }

    // MARK: - Tags for a batch of rows

    /// Both tag systems for a page of documents, in one query each, so the list
    /// can show either as a column.
    func tags(forDocuments ids: [Int64]) throws -> (own: [Int64: [Tag]], finder: [Int64: [String]]) {
        guard !ids.isEmpty else { return ([:], [:]) }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let args = ids.map { Database.Value.int($0) }

        var own: [Int64: [Tag]] = [:]
        try db.query("""
            SELECT dt.doc_id, t.id, t.name, t.color FROM document_tags dt
            JOIN tags t ON t.id = dt.tag_id
            WHERE dt.doc_id IN (\(placeholders))
            ORDER BY t.name COLLATE NOCASE
            """, args) { row in
            own[row.int(0), default: []].append(
                Tag(id: row.int(1), name: row.string(2), color: row.int(3), mirrors: false, folder: nil))
        }

        var finder: [Int64: [String]] = [:]
        try db.query("""
            SELECT doc_id, name FROM finder_tags WHERE doc_id IN (\(placeholders))
            ORDER BY name COLLATE NOCASE
            """, args) { finder[$0.int(0), default: []].append($0.string(1)) }

        return (own, finder)
    }
}
