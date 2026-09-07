import Foundation

extension Store {

    /// The center pane's single query. Search, token filters, sidebar selection
    /// and sort all collapse into one statement so paging stays O(limit).
    func listDocuments(selection: Selection, query: SearchQuery, sort: SortField,
                       ascending: Bool, limit: Int = 500) throws -> [DocumentRow] {
        var wheres: [String] = ["d.missing=0"]
        var args: [Database.Value] = []

        switch selection {
        case .all: break
        case .inbox:
            wheres.append("d.directory LIKE ?")
            args.append(.text("%/Inbox"))
        case .queue:
            wheres.append("d.id IN (SELECT doc_id FROM processing)")
        case .folder(let path):
            // Subtree, not just the immediate folder.
            wheres.append("(d.directory = ? OR d.directory LIKE ?)")
            args.append(.text(path)); args.append(.text(path + "/%"))
        case .tag(let id):
            wheres.append("d.id IN (SELECT doc_id FROM document_tags WHERE tag_id=?)")
            args.append(.int(id))
        case .correspondent(let v):
            wheres.append("m.correspondent = ?"); args.append(.text(v))
        case .docType(let v):
            wheres.append("m.doc_type = ?"); args.append(.text(v))
        case .language(let v):
            wheres.append("m.language = ?"); args.append(.text(v))
        case .untagged:
            wheres.append("d.id NOT IN (SELECT doc_id FROM document_tags)")
        case .needsReview:
            wheres.append("d.approved=0")
        }

        for t in query.tags {
            wheres.append("d.id IN (SELECT dt.doc_id FROM document_tags dt JOIN tags tg ON tg.id=dt.tag_id WHERE tg.name=? COLLATE NOCASE)")
            args.append(.text(t))
        }
        for v in query.correspondents { wheres.append("m.correspondent LIKE ?"); args.append(.text("%\(v)%")) }
        for v in query.docTypes       { wheres.append("m.doc_type LIKE ?");      args.append(.text("%\(v)%")) }
        for v in query.languages      { wheres.append("m.language = ?");         args.append(.text(v)) }
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

        let order: String
        if sort == .relevance && !joinFTS.isEmpty {
            order = "(h.r IS NULL), h.r ASC, d.created_at DESC"
        } else {
            let field = sort == .relevance ? SortField.added : sort
            order = "\(field.column) \(ascending ? "ASC" : "DESC")"
        }

        let sql = """
        SELECT d.id, d.path, d.directory, d.filename, d.ext, d.size, d.original_size,
               d.created_at, d.mtime, d.ocr_state, d.page_count, d.approved, d.missing,
               m.title, m.correspondent, m.doc_type, m.language, m.doc_date, m.summary,
               \(snippetCol)
        FROM documents d
        LEFT JOIN metadata m ON m.doc_id = d.id
        \(joinFTS)
        WHERE \(wheres.joined(separator: " AND "))
        ORDER BY \(order)
        LIMIT \(limit)
        """

        return try db.map(sql, args) { r in
            DocumentRow(
                id: r.int(0), path: r.string(1), directory: r.string(2), filename: r.string(3),
                ext: r.string(4), size: r.int(5), originalSize: r.intOrNil(6),
                createdAt: Date(timeIntervalSince1970: r.double(7)),
                mtime: Date(timeIntervalSince1970: r.double(8)),
                ocrState: OCRState(rawValue: r.int(9)) ?? .pending,
                pageCount: r.intOrNil(10).map(Int.init), approved: r.bool(11), missing: r.bool(12),
                title: r.stringOrNil(13), correspondent: r.stringOrNil(14), docType: r.stringOrNil(15),
                language: r.stringOrNil(16), docDate: r.date(17), summary: r.stringOrNil(18),
                snippet: r.stringOrNil(19)?.nilIfBlank)
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
                id: r.int(0), path: r.string(1), directory: r.string(2), filename: r.string(3),
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
        d.text = try ocrText(id)
        d.tags = try tags(for: id)
        d.aliases = try aliases(for: id).map(\.path)
        return d
    }

    // MARK: - Sidebar

    /// Builds the physical folder tree from the indexed directory column. Cheap
    /// enough to rebuild on every change — one grouped scan, no filesystem I/O.
    func folderTree(roots: [String]) throws -> [FolderNode] {
        var counts: [String: Int] = [:]
        try db.query("SELECT directory, COUNT(*) FROM documents WHERE missing=0 GROUP BY directory") {
            counts[$0.string(0)] = Int($0.int(1))
        }

        var children: [String: Set<String>] = [:]
        for dir in counts.keys {
            guard let root = roots.first(where: { dir == $0 || dir.hasPrefix($0 + "/") }) else { continue }
            var cur = dir
            while cur.count > root.count {
                let parent = (cur as NSString).deletingLastPathComponent
                children[parent, default: []].insert(cur)
                cur = parent
            }
        }

        func build(_ path: String, isRoot: Bool) -> FolderNode {
            let kids = (children[path] ?? []).sorted { lhs, rhs in
                (lhs as NSString).lastPathComponent.localizedStandardCompare(
                    (rhs as NSString).lastPathComponent) == .orderedAscending
            }.map { build($0, isRoot: false) }
            let own = counts[path] ?? 0
            return FolderNode(path: path, name: (path as NSString).lastPathComponent,
                              children: kids, count: own,
                              deepCount: own + kids.reduce(0) { $0 + $1.deepCount },
                              isRoot: isRoot)
        }
        return roots.map { build($0, isRoot: true) }
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

    /// Distinct folders under the roots, for the "Move to…" menu.
    func allDirectories() throws -> [String] {
        var set = Set<String>()
        try db.query("SELECT DISTINCT directory FROM documents WHERE missing=0") { set.insert($0.string(0)) }
        return set.sorted()
    }
}
