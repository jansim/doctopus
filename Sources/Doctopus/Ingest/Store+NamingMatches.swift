import Foundation

/// A document whose filename is not the one the library's naming template
/// gives it — the naming counterpart of a `RuleMatch`.
struct NamingMismatch: Hashable, Sendable {
    var current: String
    var expected: String
    var suppressed: Bool

    var isPending: Bool { !suppressed }
}

extension Store {

    /// What the index knows about how a document got its name.
    struct NamingState: Sendable {
        /// Its filename is still the one the template last gave it.
        var autoNamed: Bool
        var suppressed: Bool
    }

    /// Every document whose name the template would change, suppressed ones
    /// included so they can be handed back. A document a matching rule
    /// renames is the rule's to name, so it is left out; that is read off the
    /// rule-match cache, which `ruleMatches` fills and so has to run first.
    func namingMismatches(template: String, options: Naming.Options) throws -> [Int64: NamingMismatch] {
        guard template.nilIfBlank != nil else { return [:] }
        let renaming = try ruleRenamedDocuments()
        var out: [Int64: NamingMismatch] = [:]
        try db.query("""
            SELECT \(Store.rowColumns), d.name_suppressed
            \(Store.rowTables)
            WHERE d.missing=0 AND d.deleted_at IS NULL
            """) { r in
            let row = documentRow(r)
            guard !renaming.contains(row.doc) else { return }
            let expected = Naming.render(template, Naming.Context(row, options: options))
            guard !Naming.isRendering(row.filename, of: expected) else { return }
            out[row.doc] = NamingMismatch(current: row.filename, expected: expected, suppressed: r.bool(19))
        }
        return out
    }

    func namingState(_ docID: Int64) throws -> NamingState? {
        try db.first("SELECT filename, auto_name, name_suppressed FROM documents WHERE id=?",
                     [.int(docID)]) { r in
            NamingState(autoNamed: r.stringOrNil(1).map { Naming.isRendering(r.string(0), of: $0) } ?? false,
                        suppressed: r.bool(2))
        }
    }

    /// `name` is what the template rendered, before any number `uniqueURL`
    /// added to it, so the file still counts as the template's when it had to
    /// take one. Nil forgets it.
    func recordAutoName(_ name: String?, for docID: Int64) throws {
        try db.run("UPDATE documents SET auto_name=? WHERE id=?", [.text(name), .int(docID)])
    }

    func setNamingSuppressed(_ suppressed: Bool, doc docID: Int64) throws {
        try db.run("UPDATE documents SET name_suppressed=? WHERE id=?", [.bool(suppressed), .int(docID)])
    }

    func isRuleRenamed(_ docID: Int64) throws -> Bool {
        try ruleRenamedDocuments(among: [docID]).contains(docID)
    }

    /// Documents an enabled rule with a rename matches, where they are not
    /// that rule's outliers, as the rule-match cache last saw them.
    private func ruleRenamedDocuments(among ids: Set<Int64>? = nil) throws -> Set<Int64> {
        let renaming = Set(try rules().filter { $0.enabled && $0.rename != nil }.map(\.id))
        guard !renaming.isEmpty else { return [] }
        let outliers = try suppressions()
        var out: Set<Int64> = []
        for (doc, entry) in ruleMatchCache.entries where ids?.contains(doc) ?? true {
            let excused = outliers[doc] ?? []
            if entry.rules.contains(where: { renaming.contains($0) && !excused.contains($0) }) { out.insert(doc) }
        }
        return out
    }
}
