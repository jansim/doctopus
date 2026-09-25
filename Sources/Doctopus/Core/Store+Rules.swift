import Foundation

extension Store {

    func rules() throws -> [Rule] {
        var conditions: [Int64: [RuleCondition]] = [:]
        for (ruleID, condition) in try db.map("""
            SELECT rule_id, field, pattern, match_mode, match_insensitive, negated
            FROM rule_conditions ORDER BY rule_id, position, id
            """, [], { row in
            (row.int(0), RuleCondition(field: RuleField(rawValue: row.string(1)) ?? .text,
                                       pattern: row.string(2),
                                       mode: MatchMode(rawValue: row.int(3)) ?? .anyWord,
                                       caseInsensitive: row.bool(4),
                                       negated: row.bool(5)))
        }) {
            conditions[ruleID, default: []].append(condition)
        }

        var actions: [Int64: [RuleAction]] = [:]
        for (ruleID, kind, value) in try db.map("""
            SELECT rule_id, kind, value FROM rule_actions ORDER BY rule_id, position, id
            """, [], { ($0.int(0), $0.string(1), $0.string(2)) }) {
            guard let kind = RuleActionKind(rawValue: kind) else { continue }
            actions[ruleID, default: []].append(RuleAction(kind: kind, value: value))
        }

        return try db.map("""
            SELECT id, name, enabled, priority, match_all
            FROM rules ORDER BY priority DESC, id
            """) {
            let id = $0.int(0)
            return Rule(id: id, name: $0.string(1), enabled: $0.bool(2), priority: $0.int(3),
                        requiresAll: $0.bool(4),
                        conditions: conditions[id] ?? [], actions: actions[id] ?? [])
        }
    }

    /// Writes a rule whole, replacing its conditions and actions in one
    /// transaction: a half-written rule would file documents nobody asked for.
    @discardableResult
    func upsertRule(_ r: Rule) throws -> Int64 {
        try db.transaction { () -> Int64 in
            var id = r.id
            if id > 0 {
                try db.run("""
                    UPDATE rules SET name=?, enabled=?, priority=?, match_all=? WHERE id=?
                    """, [.text(r.name), .bool(r.enabled), .int(r.priority),
                          .bool(r.requiresAll), .int(id)])
                try db.run("DELETE FROM rule_conditions WHERE rule_id=?", [.int(id)])
                try db.run("DELETE FROM rule_actions WHERE rule_id=?", [.int(id)])
            } else {
                id = try db.run("""
                    INSERT INTO rules(name, enabled, priority, match_all) VALUES(?,?,?,?)
                    """, [.text(r.name), .bool(r.enabled), .int(r.priority),
                          .bool(r.requiresAll)])
            }
            for (position, c) in r.conditions.enumerated() where c.pattern.nilIfBlank != nil {
                try db.run("""
                    INSERT INTO rule_conditions(rule_id, position, field, pattern,
                                                match_mode, match_insensitive, negated)
                    VALUES(?,?,?,?,?,?,?)
                    """, [.int(id), .int(Int64(position)), .text(c.field.rawValue),
                          .text(c.pattern.trimmingCharacters(in: .whitespaces)),
                          .int(c.mode.rawValue), .bool(c.caseInsensitive), .bool(c.negated)])
            }
            for (position, a) in r.actions.enumerated() where a.value.nilIfBlank != nil {
                try db.run("""
                    INSERT INTO rule_actions(rule_id, position, kind, value) VALUES(?,?,?,?)
                    """, [.int(id), .int(Int64(position)), .text(a.kind.rawValue),
                          .text(a.value.trimmingCharacters(in: .whitespaces))])
            }
            return id
        }
    }

    func deleteRule(_ id: Int64) throws {
        try db.run("DELETE FROM rules WHERE id=?", [.int(id)])
    }

    func reorderRules(_ ids: [Int64]) throws {
        try db.transaction {
            for (index, id) in ids.enumerated() {
                try db.run("UPDATE rules SET priority=? WHERE id=?",
                           [.int(Int64((ids.count - index) * 10)), .int(id)])
            }
        }
    }

    struct RuleTarget: Sendable {
        var id: Int64
        var path: String
        var created: Date
        var docDate: Date?
        var title: String?
        var language: String?
        var subject: Rule.Subject
    }

    /// Skips the rule's outliers, unless it is applied to one document explicitly.
    func ruleTargets(for rule: Rule, onlyTo docID: Int64? = nil) throws -> [RuleTarget] {
        let scope = docID == nil
            ? "AND d.id NOT IN (SELECT doc_id FROM rule_suppressions WHERE rule_id=?)"
            : "AND d.id=?"
        return try db.map("""
            SELECT d.id, d.path, d.filename, d.created_at, m.doc_date, ec.name, et.name,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id), m.title, m.language,
                   \(Self.tagNamesColumn)
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL \(scope)
            """, [.int(docID ?? rule.id)]) {
            RuleTarget(id: $0.int(0), path: absPath($0.string(1)),
                       created: Date(timeIntervalSince1970: $0.double(3)), docDate: $0.date(4),
                       title: $0.stringOrNil(8), language: $0.stringOrNil(9),
                       subject: Rule.Subject(text: $0.stringOrNil(7) ?? "", filename: $0.string(2),
                                             correspondent: $0.stringOrNil(5), docType: $0.stringOrNil(6),
                                             tags: Self.tagNames($0.stringOrNil(10))))
        }
    }

    func ruleSamples(limit: Int = 5000) throws -> [Rule.Subject] {
        try db.map("""
            SELECT d.filename, ec.name, et.name,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id), \(Self.tagNamesColumn)
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL ORDER BY d.created_at DESC LIMIT ?
            """, [.int(Int64(limit))]) {
            Rule.Subject(text: $0.stringOrNil(3) ?? "", filename: $0.string(0),
                         correspondent: $0.stringOrNil(1), docType: $0.stringOrNil(2),
                         tags: Self.tagNames($0.stringOrNil(4)))
        }
    }

    /// A document's tag names as one column, for a query over documents `d`.
    static let tagNamesColumn = "(SELECT group_concat(t.name, char(31)) FROM document_tags dt "
        + "JOIN tags t ON t.id = dt.tag_id WHERE dt.doc_id = d.id)"

    static func tagNames(_ column: String?) -> [String] {
        (column ?? "").split(separator: "\u{1f}").map(String.init)
    }
}
