import Foundation

extension Store {

    /// Matched rule IDs per document. Matching reads the full text, so answers
    /// are kept until the document's text, filename, correspondent or type
    /// changes, or any rule's conditions do.
    struct RuleMatchCache {
        var signature = ""
        var entries: [Int64: (key: String, rules: [Int64])] = [:]
    }

    func ruleMatches() throws -> [Int64: [RuleMatch]] {
        let all = try rules()
        let live = all.filter { $0.enabled && $0.hasEffect && !$0.liveConditions.isEmpty }
        let signature = live.map(Self.conditionSignature).joined(separator: "\u{1e}")
        if signature != ruleMatchCache.signature {
            ruleMatchCache = RuleMatchCache(signature: signature)
        }

        let docs = try db.map("""
            SELECT d.id, d.path, d.filename, d.created_at, d.indexed_at, m.doc_date,
                   ec.name, et.name, m.title, m.language,
                   (SELECT group_concat(t.name, char(31)) FROM document_tags dt
                     JOIN tags t ON t.id = dt.tag_id WHERE dt.doc_id = d.id)
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL
            """) { row -> (id: Int64, key: String, filename: String, doc: RuleCheck.Document) in
            let filename = row.string(2)
            let correspondent = row.stringOrNil(6)
            let docType = row.stringOrNil(7)
            let key = [String(row.doubleOrNil(4) ?? 0), filename,
                       correspondent ?? "", docType ?? ""].joined(separator: "\u{1f}")
            let doc = RuleCheck.Document(
                path: absPath(row.string(1)), correspondent: correspondent, docType: docType,
                date: row.date(5) ?? Date(timeIntervalSince1970: row.double(3)),
                title: row.stringOrNil(8), language: row.stringOrNil(9),
                tags: (row.stringOrNil(10) ?? "").split(separator: "\u{1f}").map(String.init))
            return (row.int(0), key, filename, doc)
        }

        let present = Set(docs.map { $0.id })
        ruleMatchCache.entries = ruleMatchCache.entries.filter { present.contains($0.key) }

        if !live.isEmpty {
            let stale = docs.filter { ruleMatchCache.entries[$0.id]?.key != $0.key }
            for start in stride(from: 0, to: stale.count, by: 400) {
                let batch = stale[start..<min(start + 400, stale.count)]
                let texts = try bodies(of: batch.map { $0.id })
                for doc in batch {
                    let subject = Rule.Subject(text: texts[doc.id] ?? "", filename: doc.filename,
                                               correspondent: doc.doc.correspondent,
                                               docType: doc.doc.docType)
                    ruleMatchCache.entries[doc.id] = (doc.key,
                                                      live.filter { $0.matches(subject) }.map(\.id))
                }
            }
        }

        let outliers = try suppressions()
        let check = RuleCheck(root: root)
        var result: [Int64: [RuleMatch]] = [:]
        for doc in docs {
            let matched = live.isEmpty ? Set<Int64>() : Set(ruleMatchCache.entries[doc.id]?.rules ?? [])
            let suppressed = outliers[doc.id] ?? []
            guard !matched.isEmpty || !suppressed.isEmpty else { continue }
            var found: [RuleMatch] = []
            for rule in all where matched.contains(rule.id) || suppressed.contains(rule.id) {
                let changes = matched.contains(rule.id) ? check.changes(rule, for: doc.doc) : []
                let isOutlier = suppressed.contains(rule.id)
                guard isOutlier || !changes.isEmpty else { continue }
                found.append(RuleMatch(ruleID: rule.id, ruleName: rule.name,
                                       changes: changes, suppressed: isOutlier))
            }
            if !found.isEmpty { result[doc.id] = found }
        }
        return result
    }

    private static func conditionSignature(_ rule: Rule) -> String {
        "\(rule.id)|\(rule.requiresAll)|" + rule.liveConditions.map {
            "\($0.field.rawValue)\u{1f}\($0.pattern)\u{1f}\($0.mode.rawValue)\u{1f}\($0.caseInsensitive)\u{1f}\($0.negated)"
        }.joined(separator: "\u{1d}")
    }

    private func bodies(of ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var out: [Int64: String] = [:]
        try db.query("SELECT rowid, body FROM doc_fts WHERE rowid IN (\(marks))",
                     ids.map { .int($0) }) { out[$0.int(0)] = $0.string(1) }
        return out
    }

    // MARK: Outliers

    struct Outlier: Identifiable, Sendable {
        var doc: Int64
        var filename: String
        var folder: String
        var id: Int64 { doc }
    }

    func suppressions() throws -> [Int64: Set<Int64>] {
        var out: [Int64: Set<Int64>] = [:]
        try db.query("SELECT doc_id, rule_id FROM rule_suppressions") {
            out[$0.int(0), default: []].insert($0.int(1))
        }
        return out
    }

    func suppressedRuleIDs(for docID: Int64) throws -> Set<Int64> {
        Set(try db.map("SELECT rule_id FROM rule_suppressions WHERE doc_id=?", [.int(docID)]) { $0.int(0) })
    }

    func setRuleSuppressed(_ suppressed: Bool, rule ruleID: Int64, doc docID: Int64) throws {
        if suppressed {
            try db.run("INSERT OR IGNORE INTO rule_suppressions(rule_id, doc_id, created_at) VALUES(?,?,?)",
                       [.int(ruleID), .int(docID), .double(Date().timeIntervalSince1970)])
        } else {
            try db.run("DELETE FROM rule_suppressions WHERE rule_id=? AND doc_id=?",
                       [.int(ruleID), .int(docID)])
        }
    }

    func suppressionCounts() throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        try db.query("""
            SELECT s.rule_id, COUNT(*) FROM rule_suppressions s
            JOIN documents d ON d.id = s.doc_id
            WHERE d.missing=0 AND d.deleted_at IS NULL
            GROUP BY s.rule_id
            """) { out[$0.int(0)] = Int($0.int(1)) }
        return out
    }

    func outliers(of ruleID: Int64) throws -> [Outlier] {
        try db.map("""
            SELECT d.id, d.filename, d.directory FROM rule_suppressions s
            JOIN documents d ON d.id = s.doc_id
            WHERE s.rule_id=? AND d.missing=0 AND d.deleted_at IS NULL
            ORDER BY d.filename COLLATE NOCASE
            """, [.int(ruleID)]) {
            Outlier(doc: $0.int(0), filename: $0.string(1),
                    folder: $0.string(2).isEmpty ? root.lastPathComponent : $0.string(2))
        }
    }
}
