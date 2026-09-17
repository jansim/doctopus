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
            SELECT id, key, name, builtin_column, icon, show_in_sidebar, show_in_list, position,
                   enabled, data_type, extra_data
            FROM fields \(filter) ORDER BY position, id
            """) {
            Field(fieldID: $0.int(0), key: $0.string(1), name: $0.string(2),
                  builtinColumn: $0.stringOrNil(3), icon: $0.string(4),
                  showInSidebar: $0.bool(5), showInList: $0.bool(6),
                  position: $0.int(7), enabled: $0.bool(8),
                  type: FieldType(rawValue: $0.string(9)) ?? .string,
                  extraData: $0.stringOrNil(10))
        }
    }

    func updateField(_ f: Field) throws {
        defer { invalidateFields() }
        // A built-in field's type is decided by the column behind it and is not
        // the user's to change; everything else about it is.
        let existing = try db.first("SELECT builtin_column, data_type FROM fields WHERE id=?",
                                    [.int(f.fieldID)], { ($0.stringOrNil(0), $0.string(1)) })
        let type = (existing?.0 != nil) ? (existing?.1 ?? f.type.rawValue) : f.type.rawValue
        let retype = existing?.1 != type
        try db.run("""
            UPDATE fields SET name=?, icon=?, show_in_sidebar=?, show_in_list=?, position=?,
                              enabled=?, data_type=?, extra_data=?
            WHERE id=?
            """, [.text(f.name), .text(f.icon), .bool(f.showInSidebar), .bool(f.showInList),
                  .int(f.position), .bool(f.enabled), .text(type), .text(f.extraData),
                  .int(f.fieldID)])
        // Changing the type re-reads every value it already holds, so a field
        // switched to Amount starts sorting numerically straight away rather
        // than only for whatever is typed next.
        if retype { try reparseValues(fieldID: f.fieldID) }
    }

    @discardableResult
    func addCustomField(name: String, icon: String = "tag", type: FieldType = .string) throws -> Int64 {
        defer { invalidateFields() }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        let key = try uniqueKey(base: Store.slug(clean))
        let next = try db.first("SELECT COALESCE(MAX(position), 0) + 10 FROM fields", [], { $0.int(0) }) ?? 100
        return try db.run("""
            INSERT INTO fields(key, name, builtin_column, icon, show_in_sidebar, show_in_list,
                               position, data_type)
            VALUES(?,?,NULL,?,1,0,?,?)
            """, [.text(key), .text(clean), .text(icon), .int(next), .text(type.rawValue)])
    }

    /// Re-reads every stored value of a field through its (new) type. The text
    /// is left exactly as it was typed — only the comparable columns change.
    private func reparseValues(fieldID: Int64) throws {
        guard let raw = try db.first("SELECT data_type FROM fields WHERE id=?", [.int(fieldID)],
                                     { $0.string(0) }),
              let type = FieldType(rawValue: raw) else { return }
        let rows = try db.map("SELECT doc_id, value FROM field_values WHERE field_id=?",
                              [.int(fieldID)]) { ($0.int(0), $0.string(1)) }
        try db.transaction {
            for (docID, text) in rows {
                let parsed = type.parse(text)
                try db.run("""
                    UPDATE field_values SET value=?, value_num=?, value_date=?, value_bool=?
                    WHERE doc_id=? AND field_id=?
                    """, [.text(parsed.text ?? text), .double(parsed.number),
                          .date(parsed.date), .int(parsed.boolean.map { $0 ? Int64(1) : Int64(0) }),
                          .int(docID), .int(fieldID)])
            }
        }
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
        let parsed = field.type.parse(value)
        if let column = field.builtinColumn {
            try overwriteMetadataField(docID, column: column, value: parsed.text)
            return
        }
        guard let text = parsed.text else {
            try db.run("DELETE FROM field_values WHERE doc_id=? AND field_id=?", [.int(docID), .int(field.fieldID)])
            try refreshSearchIndex(docID)
            return
        }
        // The text is what gets shown — and for an amount it is the only place
        // the currency lives. The typed columns are what sorting compares.
        try db.run("""
            INSERT INTO field_values(doc_id, field_id, value, value_num, value_date, value_bool)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(doc_id, field_id) DO UPDATE SET
                value=excluded.value, value_num=excluded.value_num,
                value_date=excluded.value_date, value_bool=excluded.value_bool
            """, [.int(docID), .int(field.fieldID), .text(text), .double(parsed.number),
                  .date(parsed.date), .int(parsed.boolean.map { $0 ? Int64(1) : Int64(0) })])
        try refreshSearchIndex(docID)
    }

    /// Custom-field values for a batch of rows, in one query.
    func customValues(for docIDs: [Int64], fields: [Field]) throws -> [Int64: [String: String]] {
        let custom = fields.filter { !$0.isBuiltin }
        guard !custom.isEmpty, !docIDs.isEmpty else { return [:] }
        let keyByID = Dictionary(uniqueKeysWithValues: custom.map { ($0.fieldID, $0.key) })
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
        var values: [Facet]
        if let column = field.builtinColumn {
            values = try facets(column: column)
        } else {
            values = try db.map("""
                SELECT v.value, COUNT(*) FROM field_values v
                JOIN documents d ON d.id = v.doc_id AND d.missing = 0 AND d.deleted_at IS NULL
                WHERE v.field_id = ? AND TRIM(v.value) <> ''
                GROUP BY v.value COLLATE NOCASE
                ORDER BY COUNT(*) DESC, v.value COLLATE NOCASE
                """, [.int(field.fieldID)]) { Facet(value: $0.string(0), count: Int($0.int(1))) }
        }
        let icons = try valueIcons(field: field)
        for i in values.indices { values[i].icon = icons[values[i].value] }
        return values
    }

    /// Renames one value of a field across the whole library. Renaming two
    /// values to the same name merges them, because they simply become the
    /// same string — for custom fields the primary key collision is resolved
    /// the same way, by folding the duplicates into one row per document.
    @discardableResult
    func renameFieldValue(field: Field, from old: String, to new: String) throws -> Int {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != old else { return 0 }
        // An icon belongs to the value, so it travels with a rename — and a
        // merge keeps whichever icon the target already had. For a taxonomy
        // field the icon is already on the row and needs no help; this is for
        // the fields whose values are still strings.
        if Store.entityColumn(for: field.builtinColumn) == nil {
            try db.run("""
                UPDATE OR IGNORE value_icons SET value=? WHERE field_id=? AND value=?
                """, [.text(clean), .int(field.fieldID), .text(old)])
            try db.run("DELETE FROM value_icons WHERE field_id=? AND value=?",
                       [.int(field.fieldID), .text(old)])
        }
        if let column = field.builtinColumn {
            guard Store.fieldColumns.contains(column) else { return 0 }
            // A taxonomy value is one row, so renaming it is one UPDATE — and
            // renaming it onto another is a merge rather than two spellings
            // that happen to have become the same string.
            if Store.entityColumns[column] != nil {
                guard let id = try existingEntityID(named: old, builtin: column) else { return 0 }
                return try renameEntity(id, to: clean)
            }
            let affected = try db.map("SELECT doc_id FROM metadata WHERE \(column)=? COLLATE NOCASE",
                                      [.text(old)]) { $0.int(0) }
            try db.run("UPDATE metadata SET \(column)=? WHERE \(column)=? COLLATE NOCASE",
                       [.text(clean), .text(old)])
            let changed = Int(db.changes)
            try refreshSearchIndex(affected)
            return changed
        }
        let affected = try db.map(
            "SELECT doc_id FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE",
            [.int(field.fieldID), .text(old)]) { $0.int(0) }
        let renamed = try db.transaction { () -> Int in
            // Documents that already carry the target value would violate the
            // (doc_id, field_id) primary key, so drop the losing row first.
            try db.run("""
                DELETE FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE
                  AND doc_id IN (SELECT doc_id FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE)
                """, [.int(field.fieldID), .text(old), .int(field.fieldID), .text(clean)])
            try db.run("UPDATE field_values SET value=? WHERE field_id=? AND value=? COLLATE NOCASE",
                       [.text(clean), .int(field.fieldID), .text(old)])
            return Int(db.changes)
        }
        // The renamed text has to be read through the field's type again, or a
        // typed field would keep sorting by what the value used to say.
        if field.type.sortsTyped { try reparseValues(fieldID: field.fieldID) }
        try refreshSearchIndex(affected)
        return renamed
    }

    func deleteFieldValue(field: Field, value: String) throws {
        try db.run("DELETE FROM value_icons WHERE field_id=? AND value=?", [.int(field.fieldID), .text(value)])
        if let column = field.builtinColumn {
            guard Store.fieldColumns.contains(column) else { return }
            if Store.entityColumns[column] != nil {
                guard let id = try existingEntityID(named: value, builtin: column) else { return }
                try deleteEntity(id, column: column)
                return
            }
            let affected = try db.map("SELECT doc_id FROM metadata WHERE \(column)=? COLLATE NOCASE",
                                      [.text(value)]) { $0.int(0) }
            try db.run("UPDATE metadata SET \(column)=NULL WHERE \(column)=? COLLATE NOCASE", [.text(value)])
            try refreshSearchIndex(affected)
        } else {
            let affected = try db.map(
                "SELECT doc_id FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE",
                [.int(field.fieldID), .text(value)]) { $0.int(0) }
            try db.run("DELETE FROM field_values WHERE field_id=? AND value=? COLLATE NOCASE",
                       [.int(field.fieldID), .text(value)])
            try refreshSearchIndex(affected)
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
        let affected = try documentIDs(withTag: id)
        guard let target = existing else {
            try db.run("UPDATE tags SET name=? WHERE id=?", [.text(clean), .int(id)])
            try refreshSearchIndex(affected)
            return id
        }
        guard mergeIntoExisting else { return id }
        let merged = try db.transaction { () -> Int64 in
            try db.run("UPDATE OR IGNORE document_tags SET tag_id=? WHERE tag_id=?", [.int(target), .int(id)])
            try db.run("DELETE FROM document_tags WHERE tag_id=?", [.int(id)])
            try db.run("UPDATE OR IGNORE aliases SET tag_id=? WHERE tag_id=?", [.int(target), .int(id)])
            try db.run("DELETE FROM tags WHERE id=?", [.int(id)])
            return target
        }
        try refreshSearchIndex(affected)
        return merged
    }

    func setTagColor(_ id: Int64, _ color: Int64) throws {
        try db.run("UPDATE tags SET color=? WHERE id=?", [.int(color), .int(id)])
    }
}
