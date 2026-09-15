import Foundation

/// Correspondents and document types, as rows.
///
/// The two built-in fields whose values are a taxonomy rather than free text
/// point at `entities` instead of repeating a string on every document. See
/// `Schema.v16` for why. Everything else — language, amount, intent, and every
/// custom field — is still a value in place, because none of those is a thing
/// you rename, merge, give an icon to, or write a matching rule for.
extension Store {

    /// The built-in columns whose values are entities, and the `metadata`
    /// column that holds the id.
    static let entityColumns: [String: String] = [
        "correspondent": "correspondent_id",
        "doc_type": "doc_type_id",
    ]

    nonisolated static func entityColumn(for builtin: String?) -> String? {
        builtin.flatMap { entityColumns[$0] }
    }

    /// The `fields` row id for a built-in column, which is what an entity
    /// belongs to.
    func fieldID(forBuiltin column: String) throws -> Int64? {
        try db.first("SELECT id FROM fields WHERE builtin_column=?", [.text(column)]) { $0.int(0) }
    }

    /// Finds the entity with this name, or makes one. Names are compared
    /// case-insensitively, so a second spelling of the same capitalisation
    /// never becomes a second correspondent.
    @discardableResult
    func entityID(named name: String?, builtin column: String) throws -> Int64? {
        guard let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
              let fieldID = try fieldID(forBuiltin: column) else { return nil }
        if let existing = try db.first("SELECT id FROM entities WHERE field_id=? AND name=?",
                                       [.int(fieldID), .text(clean)], { $0.int(0) }) {
            return existing
        }
        return try db.run("INSERT INTO entities(field_id, name) VALUES(?,?)",
                          [.int(fieldID), .text(clean)])
    }

    func entityName(_ id: Int64?) throws -> String? {
        guard let id else { return nil }
        return try db.first("SELECT name FROM entities WHERE id=?", [.int(id)]) { $0.string(0) }
    }

    /// Every value of one taxonomy field, with how many live documents carry
    /// it. Busiest first, like the facets it feeds.
    func entities(builtin column: String) throws -> [Entity] {
        guard let idColumn = Store.entityColumns[column],
              let fieldID = try fieldID(forBuiltin: column) else { return [] }
        return try db.map("""
            SELECT e.id, e.name, e.icon, e.color, e.match, e.match_mode, e.match_insensitive,
                   (SELECT COUNT(*) FROM metadata m
                     JOIN documents d ON d.id = m.doc_id AND d.missing=0 AND d.deleted_at IS NULL
                    WHERE m.\(idColumn) = e.id)
            FROM entities e WHERE e.field_id = ?
            ORDER BY 8 DESC, e.name COLLATE NOCASE
            """, [.int(fieldID)]) {
            Entity(entityID: $0.int(0), fieldKey: column, name: $0.string(1),
                   icon: $0.stringOrNil(2), color: $0.int(3), match: $0.stringOrNil(4),
                   matchMode: MatchMode(rawValue: $0.int(5)) ?? .anyWord,
                   matchInsensitive: $0.bool(6), count: Int($0.int(7)))
        }
    }

    /// Every entity that carries a matching rule, for the analyzer. A value
    /// that can identify itself is how Paperless gets most of its
    /// classification right without a model.
    func matchingEntities() throws -> [Entity] {
        try db.map("""
            SELECT e.id, f.builtin_column, e.name, e.icon, e.color, e.match,
                   e.match_mode, e.match_insensitive
            FROM entities e JOIN fields f ON f.id = e.field_id
            WHERE e.match IS NOT NULL AND TRIM(e.match) <> ''
            ORDER BY f.builtin_column, e.name COLLATE NOCASE
            """) {
            Entity(entityID: $0.int(0), fieldKey: $0.string(1), name: $0.string(2),
                   icon: $0.stringOrNil(3), color: $0.int(4), match: $0.stringOrNil(5),
                   matchMode: MatchMode(rawValue: $0.int(6)) ?? .anyWord,
                   matchInsensitive: $0.bool(7))
        }
    }

    /// Renames one value. Renaming onto a name that already exists merges the
    /// two: the documents are repointed and the loser is deleted. Returns how
    /// many documents changed hands.
    @discardableResult
    func renameEntity(_ id: Int64, to name: String) throws -> Int {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let (fieldID, column) = try db.first("""
                SELECT e.field_id, f.builtin_column FROM entities e
                JOIN fields f ON f.id = e.field_id WHERE e.id=?
                """, [.int(id)], { ($0.int(0), $0.string(1)) }),
              let idColumn = Store.entityColumns[column] else { return 0 }

        let existing = try db.first("SELECT id FROM entities WHERE field_id=? AND name=? AND id<>?",
                                    [.int(fieldID), .text(clean), .int(id)], { $0.int(0) })
        guard let target = existing else {
            // One row, one name. This is the whole point of the change: the
            // documents are not touched at all, they already point here.
            let affected = try documentIDs(withEntity: id, column: idColumn)
            try db.run("UPDATE entities SET name=? WHERE id=?", [.text(clean), .int(id)])
            try refreshSearchIndex(affected)
            return affected.count
        }
        let affected = try documentIDs(withEntity: id, column: idColumn)
            + documentIDs(withEntity: target, column: idColumn)
        try db.transaction {
            try db.run("UPDATE metadata SET \(idColumn)=? WHERE \(idColumn)=?",
                       [.int(target), .int(id)])
            // The surviving row keeps its own icon; the merged one's goes with it.
            try db.run("DELETE FROM entities WHERE id=?", [.int(id)])
        }
        try refreshSearchIndex(affected)
        return affected.count
    }

    func deleteEntity(_ id: Int64, column: String) throws {
        guard let idColumn = Store.entityColumns[column] else { return }
        let affected = try documentIDs(withEntity: id, column: idColumn)
        try db.run("DELETE FROM entities WHERE id=?", [.int(id)])
        try refreshSearchIndex(affected)
    }

    func setEntityIcon(_ id: Int64, icon: String?) throws {
        try db.run("UPDATE entities SET icon=? WHERE id=?", [.text(icon?.nilIfBlank), .int(id)])
    }

    func setEntityColor(_ id: Int64, color: Int64) throws {
        try db.run("UPDATE entities SET color=? WHERE id=?", [.int(color), .int(id)])
    }

    /// Gives a value a pattern that identifies it. This is the cheapest
    /// classification there is: no model, no network, and it is right every
    /// time the pattern is.
    func setEntityMatch(_ id: Int64, pattern: String?, mode: MatchMode = .anyWord,
                        insensitive: Bool = true) throws {
        try db.run("UPDATE entities SET match=?, match_mode=?, match_insensitive=? WHERE id=?",
                   [.text(pattern?.nilIfBlank), .int(mode.rawValue), .bool(insensitive), .int(id)])
    }

    func documentIDs(withEntity id: Int64, column idColumn: String) throws -> [Int64] {
        try db.map("SELECT doc_id FROM metadata WHERE \(idColumn)=?", [.int(id)]) { $0.int(0) }
    }

    /// The id of the entity a name refers to, without creating one. Used by
    /// filters, where a name nobody has used should match nothing rather than
    /// quietly bringing a new correspondent into existence.
    func existingEntityID(named name: String, builtin column: String) throws -> Int64? {
        guard let fieldID = try fieldID(forBuiltin: column) else { return nil }
        return try db.first("SELECT id FROM entities WHERE field_id=? AND name=?",
                            [.int(fieldID), .text(name)]) { $0.int(0) }
    }
}
