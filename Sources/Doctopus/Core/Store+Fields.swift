import Foundation

extension Store {

    // MARK: - Field registry

    /// Fields are read on every list query, so keep them in memory. Every
    /// mutation below drops the cache.
    func cachedFields() throws -> [Field] {
        if let cached = fieldCache { return cached }
        let loaded = try fields()
        fieldCache = loaded
        return loaded
    }

    func invalidateFields() { fieldCache = nil }

    func fields(includeDisabled: Bool = false) throws -> [Field] {
        let filter = includeDisabled ? "" : "WHERE enabled=1"
        return try db.map("""
            SELECT id, key, name, builtin_column, icon, show_in_sidebar, show_in_list, position, enabled
            FROM fields \(filter) ORDER BY position, id
            """) {
            Field(id: $0.int(0), key: $0.string(1), name: $0.string(2),
                  builtinColumn: $0.stringOrNil(3), icon: $0.string(4),
                  showInSidebar: $0.bool(5), showInList: $0.bool(6),
                  position: $0.int(7), enabled: $0.bool(8))
        }
    }

    func updateField(_ f: Field) throws {
        defer { invalidateFields() }
        try db.run("""
            UPDATE fields SET name=?, icon=?, show_in_sidebar=?, show_in_list=?, position=?, enabled=?
            WHERE id=?
            """, [.text(f.name), .text(f.icon), .bool(f.showInSidebar), .bool(f.showInList),
                  .int(f.position), .bool(f.enabled), .int(f.id)])
    }

    @discardableResult
    func addCustomField(name: String, icon: String = "tag") throws -> Int64 {
        defer { invalidateFields() }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        let key = try uniqueKey(base: Store.slug(clean))
        let next = try db.first("SELECT COALESCE(MAX(position), 0) + 10 FROM fields", [], { $0.int(0) }) ?? 100
        return try db.run("""
            INSERT INTO fields(key, name, builtin_column, icon, show_in_sidebar, show_in_list, position)
            VALUES(?,?,NULL,?,1,0,?)
            """, [.text(key), .text(clean), .text(icon), .int(next)])
    }

    /// Built-ins are only ever disabled — their column still carries extracted
    /// data, and dropping the definition would orphan it.
    func deleteField(_ id: Int64) throws {
        defer { invalidateFields() }
        let builtin = try db.first("SELECT builtin_column FROM fields WHERE id=?", [.int(id)],
                                   { $0.stringOrNil(0) }) ?? nil
        if builtin != nil {
            try db.run("UPDATE fields SET enabled=0 WHERE id=?", [.int(id)])
        } else {
            try db.run("DELETE FROM fields WHERE id=?", [.int(id)])
        }
    }

    private func uniqueKey(base: String) throws -> String {
        var candidate = base.isEmpty ? "field" : base
        var n = 2
        while try db.first("SELECT 1 FROM fields WHERE key=?", [.text(candidate)], { _ in true }) != nil {
            candidate = "\(base)_\(n)"
            n += 1
        }
        return candidate
    }

    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(mapped).split(separator: "_").joined(separator: "_")
    }

    // MARK: - Values

    func setFieldValue(docID: Int64, field: Field, value: String?) throws {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        if let column = field.builtinColumn {
            try overwriteMetadataField(docID, column: column, value: clean)
            return
        }
        guard let clean else {
            try db.run("DELETE FROM field_values WHERE doc_id=? AND field_id=?", [.int(docID), .int(field.id)])
            return
        }
        try db.run("""
            INSERT INTO field_values(doc_id, field_id, value) VALUES(?,?,?)
            ON CONFLICT(doc_id, field_id) DO UPDATE SET value=excluded.value
            """, [.int(docID), .int(field.id), .text(clean)])
    }

    /// Custom-field values for a batch of rows, in one query.
    func customValues(for docIDs: [Int64], fields: [Field]) throws -> [Int64: [String: String]] {
        let custom = fields.filter { !$0.isBuiltin }
        guard !custom.isEmpty, !docIDs.isEmpty else { return [:] }
        let keyByID = Dictionary(uniqueKeysWithValues: custom.map { ($0.id, $0.key) })
        let placeholders = docIDs.map { _ in "?" }.joined(separator: ",")
        var out: [Int64: [String: String]] = [:]
        try db.query("SELECT doc_id, field_id, value FROM field_values WHERE doc_id IN (\(placeholders))",
                     docIDs.map { Database.Value.int($0) }) { row in
            guard let key = keyByID[row.int(1)] else { return }
            out[row.int(0), default: [:]][key] = row.string(2)
        }
        return out
    }

    // MARK: - Facets

    func facets(field: Field) throws -> [Facet] {
        if let column = field.builtinColumn { return try facets(column: column) }
        return try db.map("""
            SELECT v.value, COUNT(*) FROM field_values v
            JOIN documents d ON d.id = v.doc_id AND d.missing = 0
            WHERE v.field_id = ? AND TRIM(v.value) <> ''
            GROUP BY v.value COLLATE NOCASE
            ORDER BY COUNT(*) DESC, v.value COLLATE NOCASE
            """, [.int(field.id)]) { Facet(value: $0.string(0), count: Int($0.int(1))) }
    }

    /// Renames one value of a field across the whole library. Renaming two
    /// values to the same name merges them, because they simply become the
    /// same string — for custom fields the primary key collision is resolved
    /// the same way, by folding the duplicates into one row per document.
    @discardableResult
    func renameFieldValue(field: Field, from old: String, to new: String) throws -> Int {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != old else { return 0 }
        if let column = field.builtinColumn {
            let allowed = ["correspondent", "doc_type", "language", "amount", "intent"]
            guard allowed.contains(column) else { return 0 }
            try db.run("UPDATE metadata SET \(column)=? WHERE \(column)=? COLLATE NOCASE",
                       [.text(clean), .text(old)])
            return Int(db.changes)
        }
        return try db.transaction {
            // Documents that already carry the target value would violate the
            // (doc_id, field_id) primary key, so drop the losing row first.
            try db.run("""
                DELETE FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE
                  AND doc_id IN (SELECT doc_id FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE)
                """, [.int(field.id), .text(old), .int(field.id), .text(clean)])
            try db.run("UPDATE field_values SET value=? WHERE field_id=? AND value=? COLLATE NOCASE",
                       [.text(clean), .int(field.id), .text(old)])
            return Int(db.changes)
        }
    }

    func deleteFieldValue(field: Field, value: String) throws {
        if let column = field.builtinColumn {
            let allowed = ["correspondent", "doc_type", "language", "amount", "intent"]
            guard allowed.contains(column) else { return }
            try db.run("UPDATE metadata SET \(column)=NULL WHERE \(column)=? COLLATE NOCASE", [.text(value)])
        } else {
            try db.run("DELETE FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE",
                       [.int(field.id), .text(value)])
        }
    }

    // MARK: - Tags

    /// Renaming onto an existing tag merges the two: assignments and aliases
    /// move across, then the now-empty source tag is dropped.
    @discardableResult
    func renameTag(_ id: Int64, to name: String, mergeIntoExisting: Bool = true) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return id }
        let existing = try db.first("SELECT id FROM tags WHERE name=? COLLATE NOCASE AND id<>?",
                                    [.text(clean), .int(id)], { $0.int(0) })
        guard let target = existing else {
            try db.run("UPDATE tags SET name=? WHERE id=?", [.text(clean), .int(id)])
            return id
        }
        guard mergeIntoExisting else { return id }
        return try db.transaction {
            try db.run("UPDATE OR IGNORE document_tags SET tag_id=? WHERE tag_id=?", [.int(target), .int(id)])
            try db.run("DELETE FROM document_tags WHERE tag_id=?", [.int(id)])
            try db.run("UPDATE OR IGNORE aliases SET tag_id=? WHERE tag_id=?", [.int(target), .int(id)])
            try db.run("DELETE FROM tags WHERE id=?", [.int(id)])
            return target
        }
    }

    func setTagColor(_ id: Int64, _ color: Int64) throws {
        try db.run("UPDATE tags SET color=? WHERE id=?", [.int(color), .int(id)])
    }
}
