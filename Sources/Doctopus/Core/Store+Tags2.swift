import Foundation

extension Store {

    // MARK: - Per-value icons

    /// Icons chosen for individual values of a field — one for “Invoice”,
    /// another for “Tax”. Unset values fall back to the field's own icon.
    func setValueIcon(field: Field, value: String, icon: String?) throws {
        guard let icon, !icon.isEmpty else {
            try db.run("DELETE FROM value_icons WHERE field_id=? AND value=?",
                       [.int(field.fieldID), .text(value)])
            return
        }
        try db.run("""
            INSERT INTO value_icons(field_id, value, icon) VALUES(?,?,?)
            ON CONFLICT(field_id, value) DO UPDATE SET icon=excluded.icon
            """, [.int(field.fieldID), .text(value), .text(icon)])
    }

    func valueIcons(field: Field) throws -> [String: String] {
        var out: [String: String] = [:]
        try db.query("SELECT value, icon FROM value_icons WHERE field_id=?", [.int(field.fieldID)]) {
            out[$0.string(0)] = $0.string(1)
        }
        return out
    }

    // MARK: - Finder tags

    /// Replaces the indexed copy of one document's Finder tags. The file itself
    /// is the source of truth; this only mirrors it so the tags can be counted
    /// and filtered without reading every file.
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

    /// The colour label seen for each Finder tag across the library. The
    /// maximum, so one untagged-by-colour copy cannot grey out a tag that
    /// every other file carries in red.
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
                Tag(tagID: row.int(1), name: row.string(2), color: row.int(3), mirrors: false, folder: nil))
        }

        var finder: [Int64: [String]] = [:]
        try db.query("""
            SELECT doc_id, name FROM finder_tags WHERE doc_id IN (\(placeholders))
            ORDER BY name COLLATE NOCASE
            """, args) { finder[$0.int(0), default: []].append($0.string(1)) }

        return (own, finder)
    }

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
}
