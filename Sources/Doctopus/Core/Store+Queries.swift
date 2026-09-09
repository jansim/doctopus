import Foundation

extension Store {

    /// The center pane's single query. Search, token filters, sidebar selection
    /// and sort all collapse into one statement so paging stays O(limit).
    func listDocuments(selection: Selection, query: SearchQuery, sort: SortField,
                       ascending: Bool, limit: Int = 500) throws -> [DocumentRow] {
        let allFields = try cachedFields()
        var wheres: [String] = ["d.missing=0"]
        var args: [Database.Value] = []

        switch selection {
        case .all: break
        case .inbox:
            wheres.append("(d.directory = ? OR d.directory LIKE ?)")
            args.append(.text("Inbox")); args.append(.text("%/Inbox"))
        case .queue:
            wheres.append("d.id IN (SELECT doc_id FROM processing)")
        case .folder(let path):
            // `path` is absolute; the database stores directories relative to root.
            let rel = relPath(path)
            if !rel.isEmpty {
                // Subtree, plus anything present here only as a Finder alias.
                wheres.append("""
                    (d.directory = ? OR d.directory LIKE ?
                     OR EXISTS (SELECT 1 FROM aliases a WHERE a.doc_id = d.id AND a.path LIKE ?))
                    """)
                args.append(.text(rel)); args.append(.text(rel + "/%"))
                args.append(.text(rel + "/%"))
            }
            // rel == "" means the library root itself: no directory filter.
        case .tag(_, let id):
            wheres.append("d.id IN (SELECT doc_id FROM document_tags WHERE tag_id=?)")
            args.append(.int(id))
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
            wheres.append("d.id IN (SELECT doc_id FROM processing WHERE status=0)")
        }

        for t in query.tags {
            wheres.append("d.id IN (SELECT dt.doc_id FROM document_tags dt JOIN tags tg ON tg.id=dt.tag_id WHERE tg.name=? COLLATE NOCASE)")
            args.append(.text(t))
        }
        for name in query.finderTags {
            wheres.append("d.id IN (SELECT doc_id FROM finder_tags WHERE name = ? COLLATE NOCASE)")
            args.append(.text(name))
        }
        for filter in query.fieldFilters {
            guard let field = allFields.first(where: { $0.key == filter.key }) else { continue }
            appendFieldFilter(field, filter.value, exact: false, to: &wheres, args: &args)
        }
        for v in query.exts           { wheres.append("d.ext = ?");              args.append(.text(v)) }
        for v in query.folders        { wheres.append("d.directory LIKE ?");     args.append(.text("%\(v)%")) }
        for f in query.flags {
            switch f {
            case "review", "unapproved": wheres.append("d.approved=0")
            case "approved":             wheres.append("d.approved=1")
            case "untagged":             wheres.append("d.id NOT IN (SELECT doc_id FROM document_tags)")
            case "tagged":               wheres.append("d.id IN (SELECT doc_id FROM document_tags)")
            case "pending":              wheres.append("d.ocr_state=0")
            case "failed":               wheres.append("d.ocr_state=2")
            case "optimized":            wheres.append("d.original_size IS NOT NULL")
            default: break
            }
        }

        // Text search: FTS5 hit on OCR content, OR a LIKE on the human-facing fields.
        var joinFTS = ""
        var snippetCol = "NULL"
        if let expr = query.ftsExpression {
            joinFTS = """
            LEFT JOIN (
                SELECT doc_id, rank AS r, snippet(ocr_content, 0, '', '', '…', 14) AS snip
                FROM ocr_content WHERE ocr_content MATCH ?
            ) h ON h.doc_id = d.id
            """
            snippetCol = "h.snip"
            args.insert(.text(expr), at: 0)  // the MATCH bind comes before the WHERE binds

            var ors = ["h.doc_id IS NOT NULL"]
            for p in query.likePatterns {
                ors.append("(d.filename LIKE ? OR m.title LIKE ? OR m.correspondent LIKE ?)")
                args.append(.text(p)); args.append(.text(p)); args.append(.text(p))
            }
            wheres.append("(" + ors.joined(separator: " OR ") + ")")
        }

        // Queue mode carries the latest pipeline event alongside each row, so
        // review happens in the same browser as everything else.
        var joinQueue = ""
        var queueColumns = "NULL, NULL, NULL, NULL, NULL, NULL, NULL"
        if selection.isQueueMode {
            joinQueue = """
            LEFT JOIN processing p
                ON p.id = (SELECT id FROM processing WHERE doc_id = d.id ORDER BY at DESC LIMIT 1)
            """
            queueColumns = "p.id, p.at, p.action, p.detail, p.confidence, p.rule, p.status"
        }

        let order: String
        if selection.isQueueMode {
            order = "p.at DESC"
        } else if sort == .relevance && !joinFTS.isEmpty {
            order = "(h.r IS NULL), h.r ASC, d.created_at DESC"
        } else if case .field(let key) = sort, let f = allFields.first(where: { $0.key == key }) {
            // Built-ins are columns; everything else is one row in the EAV table.
            let expr = f.builtinColumn.map { "m.\($0)" }
                ?? "(SELECT value FROM field_values WHERE doc_id = d.id AND field_id = \(f.id))"
            // Blank values sort last whichever way the column points, so an
            // unfilled field never heads the list.
            order = "(\(expr) IS NULL OR \(expr) = ''), \(expr) COLLATE NOCASE \(ascending ? "ASC" : "DESC")"
        } else {
            let column = sort.column ?? SortField.added.column!
            order = "\(sort == .relevance ? SortField.added.column! : column) \(ascending ? "ASC" : "DESC")"
        }

        let sql = """
        SELECT d.id, d.path, d.directory, d.filename, d.ext, d.size, d.original_size,
               d.created_at, d.mtime, d.ocr_state, d.page_count, d.approved, d.missing,
               m.title, m.correspondent, m.doc_type, m.language, m.doc_date, m.summary,
               \(snippetCol), \(queueColumns)
        FROM documents d
        LEFT JOIN metadata m ON m.doc_id = d.id
        \(joinFTS)
        \(joinQueue)
        WHERE \(wheres.joined(separator: " AND "))
        ORDER BY \(order)
        LIMIT \(limit)
        """

        var rows = try db.map(sql, args) { r in
            DocumentRow(
                id: r.int(0), path: absPath(r.string(1)), directory: absPath(r.string(2)),
                filename: r.string(3),
                ext: r.string(4), size: r.int(5), originalSize: r.intOrNil(6),
                createdAt: Date(timeIntervalSince1970: r.double(7)),
                mtime: Date(timeIntervalSince1970: r.double(8)),
                ocrState: OCRState(rawValue: r.int(9)) ?? .pending,
                pageCount: r.intOrNil(10).map(Int.init), approved: r.bool(11), missing: r.bool(12),
                title: r.stringOrNil(13), correspondent: r.stringOrNil(14), docType: r.stringOrNil(15),
                language: r.stringOrNil(16), docDate: r.date(17), summary: r.stringOrNil(18),
                snippet: r.stringOrNil(19)?.nilIfBlank,
                queue: r.intOrNil(20).map { id in
                    QueueInfo(entryID: id, at: r.date(21) ?? .now, action: r.string(22),
                              detail: r.stringOrNil(23), confidence: r.doubleOrNil(24),
                              rule: r.stringOrNil(25), approved: r.bool(26))
                })
        }

        // A document shown inside a folder it does not physically live in is
        // there through an alias; flag it so the UI can say so.
        if case .folder(let path) = selection {
            for i in rows.indices where rows[i].directory != path && !rows[i].directory.hasPrefix(path + "/") {
                rows[i].isAliasHere = true
            }
        }

        // Both tag systems, so either can be shown as a column.
        let tagged = try tags(forDocuments: rows.map(\.id))
        for i in rows.indices {
            rows[i].tags = tagged.own[rows[i].id] ?? []
            rows[i].finderTags = tagged.finder[rows[i].id] ?? []
        }

        // Fold every field's value into one uniform dictionary so the views
        // never need to know whether a field is built in or user-defined.
        let custom = try customValues(for: rows.map(\.id), fields: allFields)
        for i in rows.indices {
            var values: [String: String] = [:]
            for field in allFields {
                switch field.builtinColumn {
                case "doc_type":      values[field.key] = rows[i].docType
                case "correspondent": values[field.key] = rows[i].correspondent
                case "language":      values[field.key] = rows[i].language
                default: break
                }
            }
            if let extra = custom[rows[i].id] { values.merge(extra) { _, new in new } }
            rows[i].values = values.compactMapValues { $0 }
        }
        return rows
    }

    /// Adds the WHERE clause for one field, wherever its values are stored.
    private func appendFieldFilter(_ field: Field, _ value: String, exact: Bool,
                                   to wheres: inout [String], args: inout [Database.Value]) {
        if let column = field.builtinColumn {
            let allowed = ["correspondent", "doc_type", "language", "amount", "intent"]
            guard allowed.contains(column) else { return }
            if exact {
                wheres.append("m.\(column) = ?"); args.append(.text(value))
            } else {
                wheres.append("m.\(column) LIKE ?"); args.append(.text("%\(value)%"))
            }
        } else {
            let comparison = exact ? "v.value = ?" : "v.value LIKE ?"
            wheres.append("d.id IN (SELECT v.doc_id FROM field_values v WHERE v.field_id=? AND \(comparison))")
            args.append(.int(field.id))
            args.append(.text(exact ? value : "%\(value)%"))
        }
    }

    func detail(_ id: Int64) throws -> DocumentDetail? {
        guard let base = try db.first("""
            SELECT d.id, d.path, d.directory, d.filename, d.ext, d.size, d.original_size,
                   d.created_at, d.mtime, d.ocr_state, d.page_count, d.approved, d.missing, d.hash,
                   m.title, m.correspondent, m.doc_type, m.language, m.doc_date, m.summary,
                   m.intent, m.date_source, m.confidence, m.source, m.amount,
                   s.confidence, s.words, s.source
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id=d.id
            LEFT JOIN ocr_stats s ON s.doc_id=d.id
            WHERE d.id=?
            """, [.int(id)], { r -> DocumentDetail in
            let row = DocumentRow(
                id: r.int(0), path: absPath(r.string(1)), directory: absPath(r.string(2)),
                filename: r.string(3),
                ext: r.string(4), size: r.int(5), originalSize: r.intOrNil(6),
                createdAt: Date(timeIntervalSince1970: r.double(7)),
                mtime: Date(timeIntervalSince1970: r.double(8)),
                ocrState: OCRState(rawValue: r.int(9)) ?? .pending,
                pageCount: r.intOrNil(10).map(Int.init), approved: r.bool(11), missing: r.bool(12),
                title: r.stringOrNil(14), correspondent: r.stringOrNil(15), docType: r.stringOrNil(16),
                language: r.stringOrNil(17), docDate: r.date(18), summary: r.stringOrNil(19))
            return DocumentDetail(
                row: row, hash: r.stringOrNil(13), intent: r.stringOrNil(20),
                dateSource: r.stringOrNil(21), metadataSource: r.stringOrNil(23),
                metadataConfidence: r.doubleOrNil(22), amount: r.stringOrNil(24),
                ocrConfidence: r.doubleOrNil(25), ocrWords: r.intOrNil(26).map(Int.init),
                ocrSource: r.stringOrNil(27))
        }) else { return nil }

        var d = base
        let allFields = try cachedFields()
        var values: [String: String] = [:]
        for field in allFields {
            switch field.builtinColumn {
            case "doc_type":      values[field.key] = d.row.docType
            case "correspondent": values[field.key] = d.row.correspondent
            case "language":      values[field.key] = d.row.language
            case "amount":        values[field.key] = d.amount
            case "intent":        values[field.key] = d.intent
            default: break
            }
        }
        if let extra = try customValues(for: [id], fields: allFields)[id] {
            values.merge(extra) { _, new in new }
        }
        d.row.values = values.compactMapValues { $0 }
        d.text = try ocrText(id)
        d.tags = try tags(for: id)
        d.row.finderTags = try finderTags(docID: id)
        d.aliases = try aliases(for: id).map(\.path)
        return d
    }

    // MARK: - Sidebar

    /// Builds the physical folder tree from the indexed directory column. Cheap
    /// enough to rebuild on every change — one grouped scan, no filesystem I/O.
    /// Directories are stored relative to the root (`""` is the root itself);
    /// the nodes it returns carry absolute paths.
    func folderTree() throws -> [FolderNode] {
        var counts: [String: Int] = [:]
        try db.query("SELECT directory, COUNT(*) FROM documents WHERE missing=0 GROUP BY directory") {
            counts[$0.string(0)] = Int($0.int(1))
        }

        var children: [String: Set<String>] = [:]
        for dir in counts.keys where !dir.isEmpty {
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
        let allowed = ["correspondent", "doc_type", "language"]
        guard allowed.contains(column) else { return [] }
        return try db.map("""
            SELECT m.\(column), COUNT(*) FROM metadata m
            JOIN documents d ON d.id=m.doc_id AND d.missing=0
            WHERE m.\(column) IS NOT NULL AND TRIM(m.\(column)) <> ''
            GROUP BY m.\(column) COLLATE NOCASE ORDER BY COUNT(*) DESC, m.\(column) COLLATE NOCASE
            """) { Facet(value: $0.string(0), count: Int($0.int(1))) }
    }

    struct Stats: Sendable, Equatable {
        var total = 0
        var pending = 0
        var failed = 0
        var needsReview = 0
        var bytes: Int64 = 0
        var saved: Int64 = 0

        /// Summed across the open libraries for the app-wide footer.
        static func + (a: Stats, b: Stats) -> Stats {
            Stats(total: a.total + b.total, pending: a.pending + b.pending,
                  failed: a.failed + b.failed, needsReview: a.needsReview + b.needsReview,
                  bytes: a.bytes + b.bytes, saved: a.saved + b.saved)
        }
    }

    func stats() throws -> Stats {
        var s = Stats()
        try db.query("""
            SELECT COUNT(*),
                   SUM(ocr_state=0), SUM(ocr_state=2), SUM(approved=0),
                   SUM(size), SUM(COALESCE(original_size,size) - size)
            FROM documents WHERE missing=0
            """) { r in
            s.total = Int(r.int(0)); s.pending = Int(r.int(1)); s.failed = Int(r.int(2))
            s.needsReview = Int(r.int(3)); s.bytes = r.int(4); s.saved = max(0, r.int(5))
        }
        return s
    }

    /// Distinct absolute folders under the root, for the "Move to…" menu.
    func allDirectories() throws -> [String] {
        var set = Set<String>()
        try db.query("SELECT DISTINCT directory FROM documents WHERE missing=0") {
            set.insert(absPath($0.string(0)))
        }
        return set.sorted()
    }
}
