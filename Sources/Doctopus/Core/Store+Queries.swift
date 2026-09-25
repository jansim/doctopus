import Foundation

extension Store {

    // The list, detail and more-like-this queries share these columns in this
    // order, so one decoder reads all three. Extra columns go after them.

    static let rowColumns = """
        d.id, d.path, d.directory, d.filename, d.ext, d.size, d.original_size,
        d.created_at, d.mtime, d.ocr_state, d.page_count, d.approved, d.missing,
        m.title, ec.name, et.name, m.language, m.doc_date, m.summary
        """

    static let rowTables = """
        FROM documents d
        LEFT JOIN metadata m ON m.doc_id = d.id
        LEFT JOIN entities ec ON ec.id = m.correspondent_id
        LEFT JOIN entities et ON et.id = m.doc_type_id
        """

    /// Only imports and scans are logged as imported or routed; Apply to Existing's `routed` is told apart by its detail.
    /// Approving the arrival settles it into the library, so a later event cannot make it new again.
    static let fromOutsideColumn = """
        EXISTS (SELECT 1 FROM processing op JOIN events o ON o.id = op.event_id
                WHERE op.doc_id = d.id AND op.status = 0
                AND (o.action = 'imported'
                     OR (o.action = 'routed' AND COALESCE(o.detail, '') NOT LIKE 'Applied rule %')))
        """

    func documentRow(_ r: Database.Row) -> DocumentRow {
        DocumentRow(
            doc: r.int(0), path: absPath(r.string(1)), directory: absPath(r.string(2)),
            filename: r.string(3), ext: r.string(4), size: r.int(5),
            originalSize: r.intOrNil(6),
            createdAt: Date(timeIntervalSince1970: r.double(7)),
            mtime: Date(timeIntervalSince1970: r.double(8)),
            ocrState: OCRState(rawValue: r.int(9)) ?? .pending,
            pageCount: r.intOrNil(10).map(Int.init), approved: r.bool(11), missing: r.bool(12),
            title: r.stringOrNil(13), correspondent: r.stringOrNil(14), docType: r.stringOrNil(15),
            language: r.stringOrNil(16), docDate: r.date(17), summary: r.stringOrNil(18))
    }

    static func builtinValues(fields: [Field], row: DocumentRow,
                              amount: String?, intent: String?) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            let value: String?
            switch field.builtinColumn {
            case "doc_type":      value = row.docType
            case "correspondent": value = row.correspondent
            case "language":      value = row.language
            case "amount":        value = amount
            case "intent":        value = intent
            default: continue
            }
            if let value { values[field.key] = value }
        }
        return values
    }

    func listDocuments(selection: Selection, query: SearchQuery, sort: SortField,
                       ascending: Bool, limit: Int = 500, offset: Int = 0,
                       ruleMatched: Set<Int64> = []) throws -> [DocumentRow] {
        let allFields = try cachedFields()
        var args: [Database.Value] = []
        var wheres: [String] = selection == .deleted
            ? ["d.deleted_at IS NOT NULL"]
            : ["d.missing=0", "d.deleted_at IS NULL"]

        switch selection {
        case .all, .deleted, .savedView: break
        case .queue:
            wheres.append("d.id IN (SELECT doc_id FROM processing)")
        case .folder(let path):
            let rel = relPath(path)
            if !rel.isEmpty {
                wheres.append("""
                    (d.directory = ? OR d.directory LIKE ?
                     OR EXISTS (SELECT 1 FROM aliases a WHERE a.doc_id = d.id AND a.path LIKE ?))
                    """)
                args.append(.text(rel)); args.append(.text(rel + "/%"))
                args.append(.text(rel + "/%"))
            }
        case .tag(let tag):
            wheres.append("d.id IN (SELECT doc_id FROM document_tags WHERE tag_id=?)")
            args.append(.int(tag))
        case .finderTag(let name):
            wheres.append("d.id IN (SELECT doc_id FROM finder_tags WHERE name = ? COLLATE NOCASE)")
            args.append(.text(name))
        case .field(let key, let value):
            if let field = allFields.first(where: { $0.key == key }) {
                appendFieldFilter(field, value, exact: true, to: &wheres, args: &args)
            }
        case .untagged:
            wheres.append("d.id NOT IN (SELECT doc_id FROM document_tags)")
        case .needsReview:
            // Rule matches are worked out in memory, so the caller names the
            // documents a rule would still change; they wait here too.
            var waiting = "d.id IN (SELECT doc_id FROM processing WHERE status=0)"
            if !ruleMatched.isEmpty {
                waiting += " OR d.id IN (\(ruleMatched.sorted().map { String($0) }.joined(separator: ",")))"
            }
            wheres.append("(\(waiting))")
        case .outliers(let rule):
            wheres.append("d.id IN (SELECT doc_id FROM rule_suppressions WHERE rule_id=?)")
            args.append(.int(rule))
        }

        for t in query.tags {
            wheres.append("d.id IN (SELECT dt.doc_id FROM document_tags dt JOIN tags tg ON tg.id=dt.tag_id WHERE tg.name=? COLLATE NOCASE)")
            args.append(.text(t))
        }
        for t in query.negatedTags {
            wheres.append("d.id NOT IN (SELECT dt.doc_id FROM document_tags dt JOIN tags tg ON tg.id=dt.tag_id WHERE tg.name=? COLLATE NOCASE)")
            args.append(.text(t))
        }
        for name in query.finderTags {
            wheres.append("d.id IN (SELECT doc_id FROM finder_tags WHERE name = ? COLLATE NOCASE)")
            args.append(.text(name))
        }
        for name in query.negatedFinderTags {
            wheres.append("d.id NOT IN (SELECT doc_id FROM finder_tags WHERE name = ? COLLATE NOCASE)")
            args.append(.text(name))
        }
        for filter in query.fieldFilters {
            guard let field = allFields.first(where: { $0.key == filter.key }) else { continue }
            appendFieldFilter(field, filter.value, exact: false, negated: false, to: &wheres, args: &args)
        }
        for filter in query.negatedFieldFilters {
            guard let field = allFields.first(where: { $0.key == filter.key }) else { continue }
            appendFieldFilter(field, filter.value, exact: false, negated: true, to: &wheres, args: &args)
        }
        for v in query.exts           { wheres.append("d.ext = ?");              args.append(.text(v)) }
        for v in query.negatedExts    { wheres.append("d.ext <> ?");             args.append(.text(v)) }
        for v in query.folders        { wheres.append("d.directory LIKE ?");     args.append(.text("%\(v)%")) }
        for v in query.negatedFolders { wheres.append("d.directory NOT LIKE ?"); args.append(.text("%\(v)%")) }
        for f in query.flags {
            if let p = SearchQuery.flagPredicate(f) { wheres.append("(\(p))") }
        }
        for f in query.negatedFlags {
            if let p = SearchQuery.flagPredicate(f) { wheres.append("NOT COALESCE((\(p)), 0)") }
        }
        for df in query.dateFilters {
            let col = df.column
            let clause: String
            if let start = df.start, let end = df.end {
                clause = "\(col) >= ? AND \(col) <= ?"
                args.append(.double(start.timeIntervalSince1970))
                args.append(.double(end.timeIntervalSince1970))
            } else if let start = df.start {
                clause = "\(col) >= ?"
                args.append(.double(start.timeIntervalSince1970))
            } else if let end = df.end {
                clause = "\(col) <= ?"
                args.append(.double(end.timeIntervalSince1970))
            } else {
                continue
            }
            wheres.append(df.negated ? "NOT (\(clause))" : clause)
        }
        for term in query.negatedTerms {
            let unquoted = term.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            guard !unquoted.isEmpty else { continue }
            wheres.append("d.id NOT IN (SELECT rowid FROM doc_fts WHERE doc_fts MATCH ?)")
            args.append(.text(unquoted.contains(" ") ? "\"\(unquoted)\"" : "\"\(unquoted)\"*"))
        }

        var joinFTS = ""
        var snippetCol = "NULL"
        if let expr = query.ftsExpression {
            joinFTS = """
            JOIN (
                SELECT rowid AS doc, bm25(doc_fts, \(Store.bm25Weights)) AS r,
                       snippet(doc_fts, 7, '', '', '…', 14) AS snip
                FROM doc_fts WHERE doc_fts MATCH ?
            ) h ON h.doc = d.id
            """
            snippetCol = "h.snip"
            args.insert(.text(expr), at: 0)  // the MATCH bind comes before the WHERE binds
        }

        var joinQueue = ""
        var queueColumns = "NULL, NULL, NULL, NULL, NULL, NULL"
        var originColumn = "0"
        if selection.isQueueMode {
            originColumn = Store.fromOutsideColumn
            joinQueue = """
            LEFT JOIN processing p
                ON p.id = (SELECT id FROM processing WHERE doc_id = d.id ORDER BY id DESC LIMIT 1)
            LEFT JOIN events pe ON pe.id = p.event_id
            """
            queueColumns = "p.id, pe.at, pe.action, pe.detail, pe.rule, p.status"
        }

        let order: String
        if selection == .deleted {
            order = "d.deleted_at DESC"
        } else if selection.isQueueMode {
            order = "pe.at DESC, d.created_at DESC"
        } else if sort == .relevance && !joinFTS.isEmpty {
            // bm25() is more negative the better the match.
            order = "h.r ASC, d.created_at DESC"
        } else if case .field(let key) = sort, let f = allFields.first(where: { $0.key == key }) {
            let expr: String
            let collate: String
            if let column = f.builtinColumn {
                if column == "amount" {
                    expr = "m.amount_value"
                    collate = ""
                } else if let idColumn = Store.entityColumns[column] {
                    expr = "(SELECT name FROM entities WHERE id = m.\(idColumn))"
                    collate = " COLLATE NOCASE"
                } else {
                    expr = "m.\(column)"
                    collate = " COLLATE NOCASE"
                }
            } else if let typed = f.type.storageColumn {
                expr = "(SELECT \(typed) FROM field_values WHERE doc_id = d.id AND field_id = \(f.fieldID))"
                collate = ""
            } else {
                expr = "(SELECT value FROM field_values WHERE doc_id = d.id AND field_id = \(f.fieldID))"
                collate = " COLLATE NOCASE"
            }
            let blank = collate.isEmpty ? "\(expr) IS NULL" : "\(expr) IS NULL OR \(expr) = ''"
            order = "(\(blank)), \(expr)\(collate) \(ascending ? "ASC" : "DESC")"
        } else {
            let column = sort.column ?? SortField.added.column!
            order = "\(sort == .relevance ? SortField.added.column! : column) \(ascending ? "ASC" : "DESC")"
        }

        let sql = """
        SELECT \(Store.rowColumns),
               \(snippetCol), \(queueColumns), m.amount, m.intent, \(originColumn)
        \(Store.rowTables)
        \(joinFTS)
        \(joinQueue)
        WHERE \(wheres.joined(separator: " AND "))
        ORDER BY \(order)
        LIMIT \(limit) OFFSET \(offset)
        """

        var extras: [Int64: (amount: String?, intent: String?)] = [:]
        var rows = try db.map(sql, args) { r -> DocumentRow in
            var row = documentRow(r)
            row.snippet = r.stringOrNil(19)?.nilIfBlank
            row.queue = r.intOrNil(20).map { id in
                QueueInfo(entryID: id, at: r.date(21) ?? .now, action: EventAction(stored: r.string(22)),
                          detail: r.stringOrNil(23), rule: r.stringOrNil(24), approved: r.bool(25))
            }
            extras[row.doc] = (amount: r.stringOrNil(26), intent: r.stringOrNil(27))
            row.fromOutside = r.bool(28)
            return row
        }

        if case .folder(let path) = selection {
            for i in rows.indices where rows[i].directory != path && !rows[i].directory.hasPrefix(path + "/") {
                rows[i].isAliasHere = true
            }
        }

        let tagged = try tags(forDocuments: rows.map(\.doc))
        for i in rows.indices {
            rows[i].tags = tagged.own[rows[i].doc] ?? []
            rows[i].finderTags = tagged.finder[rows[i].doc] ?? []
        }

        let custom = try customValues(for: rows.map(\.doc), fields: allFields)
        for i in rows.indices {
            let extra = extras[rows[i].doc]
            var values = Store.builtinValues(fields: allFields, row: rows[i],
                                             amount: extra?.amount, intent: extra?.intent)
            if let custom = custom[rows[i].doc] { values.merge(custom) { _, new in new } }
            rows[i].values = values
        }
        return rows
    }

    private func appendFieldFilter(_ field: Field, _ value: String, exact: Bool, negated: Bool = false,
                                   to wheres: inout [String], args: inout [Database.Value]) {
        if let column = field.builtinColumn {
            guard Store.fieldColumns.contains(column) else { return }
            if let idColumn = Store.entityColumns[column] {
                let comparison = exact ? "e.name = ?" : "e.name LIKE ?"
                let subquery = """
                    (SELECT e.id FROM entities e
                                      JOIN fields f ON f.id = e.field_id
                                      WHERE f.builtin_column = ? AND \(comparison))
                    """
                // A negated filter must also match documents with no value at
                // all for this field — `NOT IN` alone evaluates to SQL NULL
                // (and is dropped by WHERE) when the column itself is NULL.
                if negated {
                    wheres.append("(m.\(idColumn) IS NULL OR m.\(idColumn) NOT IN \(subquery))")
                } else {
                    wheres.append("m.\(idColumn) IN \(subquery)")
                }
                args.append(.text(column))
                args.append(.text(exact ? value : "%\(value)%"))
                return
            }
            if exact {
                if negated {
                    wheres.append("(m.\(column) IS NULL OR m.\(column) <> ?)")
                } else {
                    wheres.append("m.\(column) = ?")
                }
                args.append(.text(value))
            } else {
                if negated {
                    wheres.append("(m.\(column) IS NULL OR m.\(column) NOT LIKE ?)")
                } else {
                    wheres.append("m.\(column) LIKE ?")
                }
                args.append(.text("%\(value)%"))
            }
        } else {
            let comparison = exact ? "v.value = ?" : "v.value LIKE ?"
            let inOrNotIn = negated ? "NOT IN" : "IN"
            wheres.append("d.id \(inOrNotIn) (SELECT v.doc_id FROM field_values v WHERE v.field_id=? AND \(comparison))")
            args.append(.int(field.fieldID))
            args.append(.text(exact ? value : "%\(value)%"))
        }
    }

    func detail(_ id: Int64) throws -> DocumentDetail? {
        guard let base = try db.first("""
            SELECT \(Store.rowColumns),
                   d.hash, m.intent, m.date_source, m.source, m.amount,
                   s.words, s.source, \(Store.fromOutsideColumn)
            \(Store.rowTables)
            LEFT JOIN ocr_stats s ON s.doc_id=d.id
            WHERE d.id=?
            """, [.int(id)], { r -> DocumentDetail in
            var d = DocumentDetail(
                row: documentRow(r), hash: r.stringOrNil(19), intent: r.stringOrNil(20),
                dateSource: r.stringOrNil(21), metadataSource: r.stringOrNil(22),
                amount: r.stringOrNil(23), ocrWords: r.intOrNil(24).map(Int.init),
                ocrSource: r.stringOrNil(25))
            d.row.fromOutside = r.bool(26)
            return d
        }) else { return nil }

        var d = base
        let allFields = try cachedFields()
        var values = Store.builtinValues(fields: allFields, row: d.row,
                                         amount: d.amount, intent: d.intent)
        if let custom = try customValues(for: [id], fields: allFields)[id] {
            values.merge(custom) { _, new in new }
        }
        d.row.values = values
        d.text = try ocrText(id)
        d.tags = try tags(for: id)
        d.tagSuggestions = try tagSuggestions(for: id)
        d.pathSuggestions = try pathSuggestions(for: id)
        d.similarFolders = try similarFolders(for: id)
        d.similarDocuments = (try? similarDocuments(for: id)) ?? []
        d.folderAliases = try folderAliases(for: id)
        d.history = try history(for: id)
        d.notes = try notes(for: id)
        d.dateCandidates = try dateCandidates(for: id)
        d.row.finderTags = try finderTags(docID: id)
        d.aliases = try aliases(for: id).map(\.path)
        d.originalFileURL = try? originalFileURL(for: id)
        return d
    }

    func folderTree() throws -> [FolderNode] {
        var counts: [String: Int] = [:]
        try db.query("SELECT directory, COUNT(*) FROM documents WHERE missing=0 AND deleted_at IS NULL GROUP BY directory") {
            counts[$0.string(0)] = Int($0.int(1))
        }

        var allDirs = Set(counts.keys)
        let tagsMirrorRoot = root.appendingPathComponent(Store.tagMirrorFolder, isDirectory: true).path
        for url in FileScanner.directories(root: root) {
            let path = url.path
            guard path != tagsMirrorRoot, !path.hasPrefix(tagsMirrorRoot + "/") else { continue }
            allDirs.insert(relPath(path))
        }

        var children: [String: Set<String>] = [:]
        for dir in allDirs where !dir.isEmpty {
            var cur = dir
            while !cur.isEmpty {
                let parent = (cur as NSString).deletingLastPathComponent
                if parent == cur { break }   // "/" is its own parent — a stray absolute path
                children[parent, default: []].insert(cur)
                cur = parent
            }
        }

        func build(_ rel: String, isRoot: Bool) -> FolderNode {
            let kids = (children[rel] ?? []).sorted { lhs, rhs in
                (lhs as NSString).lastPathComponent.localizedStandardCompare(
                    (rhs as NSString).lastPathComponent) == .orderedAscending
            }.map { build($0, isRoot: false) }
            let own = counts[rel] ?? 0
            return FolderNode(path: absPath(rel),
                              name: isRoot ? root.lastPathComponent : (rel as NSString).lastPathComponent,
                              children: kids, count: own,
                              deepCount: own + kids.reduce(0) { $0 + $1.deepCount },
                              isRoot: isRoot)
        }
        return [build("", isRoot: true)]
    }

    func facets(column: String) throws -> [Facet] {
        guard ["correspondent", "doc_type", "language"].contains(column) else { return [] }
        if Store.entityColumns[column] != nil {
            return try entities(builtin: column)
                .filter { $0.count > 0 }
                .map { Facet(value: $0.name, count: $0.count, icon: $0.icon, match: $0.match) }
        }
        return try db.map("""
            SELECT m.\(column), COUNT(*) FROM metadata m
            JOIN documents d ON d.id=m.doc_id AND d.missing=0 AND d.deleted_at IS NULL
            WHERE m.\(column) IS NOT NULL AND TRIM(m.\(column)) <> ''
            GROUP BY m.\(column) COLLATE NOCASE ORDER BY COUNT(*) DESC, m.\(column) COLLATE NOCASE
            """) { Facet(value: $0.string(0), count: Int($0.int(1))) }
    }

    struct Stats: Sendable, Equatable {
        var total = 0
        var pending = 0
        var failed = 0
        /// Documents in Recent Processing, counted as its list shows them.
        var queued = 0
        /// Documents with processing still waiting for approval.
        var waiting: Set<Int64> = []
        var bytes: Int64 = 0
        var saved: Int64 = 0
        var deleted = 0
    }

    func stats() throws -> Stats {
        var s = Stats()
        try db.query("""
            SELECT COUNT(*),
                   SUM(ocr_state=0), SUM(ocr_state=2), SUM(id IN (SELECT doc_id FROM processing)),
                   SUM(size), SUM(COALESCE(original_size,size) - size)
            FROM documents WHERE missing=0 AND deleted_at IS NULL
            """) { r in
            s.total = Int(r.int(0)); s.pending = Int(r.int(1)); s.failed = Int(r.int(2))
            s.queued = Int(r.int(3)); s.bytes = r.int(4); s.saved = max(0, r.int(5))
        }
        s.waiting = Set(try db.map("""
            SELECT id FROM documents
            WHERE missing=0 AND deleted_at IS NULL
              AND id IN (SELECT doc_id FROM processing WHERE status=0)
            """) { $0.int(0) })
        s.deleted = try deletedCount()
        return s
    }
}
