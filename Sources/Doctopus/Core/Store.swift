import Foundation

/// Serialized owner of the SQLite index. Every read and write funnels through
/// here, which keeps the connection single-threaded without a mutex.
actor Store {
    let db: Database
    let containerURL: URL
    let root: URL
    let libraryID: LibraryID
    var fieldCache: [Field]?

    // Store+RuleMatches
    var ruleMatchCache = RuleMatchCache()

    private let rootPrefix: String

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = URL(fileURLWithPath: Store.canonical(directory.standardizedFileURL.path),
                            isDirectory: true)
        self.containerURL = container
        self.root = container.deletingLastPathComponent()
        self.rootPrefix = container.deletingLastPathComponent().path + "/"
        var meta = try Store.loadOrCreateMeta(in: container)
        self.libraryID = meta.id
        db = try Database(path: container.appendingPathComponent("index.sqlite").path)
        do { try Schema.migrate(db) } catch is Schema.TooNew {
            throw OpenError.newer(writtenBy: meta.appVersion)
        }
        // Stamped only once the index is known to be readable, so a refused
        // library keeps naming the build that can open it.
        if meta.formatVersion != Store.formatVersion || meta.appVersion != Store.appVersion {
            meta.formatVersion = Store.formatVersion
            meta.appVersion = Store.appVersion
            try? JSONEncoder().encode(meta).write(to: container.appendingPathComponent("meta.json"),
                                                  options: .atomic)
        }
    }

    // Paths are stored relative to `root` so the library is portable. Nothing
    // outside `Store` ever sees a relative path.

    nonisolated static func canonical(_ path: String) -> String {
        for prefix in ["/var/", "/tmp/", "/etc/"] where path.hasPrefix(prefix) {
            return "/private" + path
        }
        return path
    }

    nonisolated func relPath(_ absolute: String) -> String {
        let path = Store.canonical(absolute)
        if path == root.path { return "" }
        guard path.hasPrefix(rootPrefix) else { return path }
        return String(path.dropFirst(rootPrefix.count))
    }

    nonisolated func absPath(_ relative: String) -> String {
        if relative.isEmpty { return root.path }
        if relative.hasPrefix("/") { return relative }
        return rootPrefix + relative
    }

    nonisolated func url(forRelative relative: String) -> URL {
        URL(fileURLWithPath: absPath(relative))
    }

    static let formatVersion = 2
    /// Where tags mirror as aliases unless a tag names its own folder.
    static let tagMirrorFolder = "Tags"

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    enum OpenError: Swift.Error, CustomStringConvertible {
        case newer(writtenBy: String?)
        case unreadableMeta(String)

        var description: String {
            switch self {
            case .newer(let writtenBy):
                let by = writtenBy.map { " (Doctopus \($0))" } ?? ""
                return "This library was written by a newer version of Doctopus\(by). Update Doctopus to open it."
            case .unreadableMeta(let reason):
                return "This library’s meta.json could not be read (\(reason)), so it was not opened. "
                    + "It names the library, and replacing it would make this a different one: "
                    + "restore it from a backup, or delete it to open the library under a new identity."
            }
        }
    }

    private struct Meta: Codable {
        var id: String
        var formatVersion: Int
        var name: String?
        var appVersion: String?
    }

    /// Only a library with no `meta.json` at all gets a new one. One that is
    /// there but will not read is refused rather than replaced, since its id is
    /// the library's identity.
    private static func loadOrCreateMeta(in container: URL) throws -> Meta {
        let metaURL = container.appendingPathComponent("meta.json")
        if FileManager.default.fileExists(atPath: metaURL.path) {
            let meta: Meta
            do {
                meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))
            } catch {
                throw OpenError.unreadableMeta(error.localizedDescription)
            }
            guard !meta.id.isEmpty else { throw OpenError.unreadableMeta("it names no library") }
            // A newer app may have written columns and tables this build would
            // drop on the first write.
            guard meta.formatVersion <= formatVersion else { throw OpenError.newer(writtenBy: meta.appVersion) }
            return meta
        }
        let meta = Meta(id: UUID().uuidString, formatVersion: formatVersion,
                        name: container.deletingLastPathComponent().lastPathComponent,
                        appVersion: appVersion)
        // Unwritten, the library would get a new identity on every open.
        try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        return meta
    }

    func setting(_ key: String) throws -> String? {
        try db.first("SELECT value FROM settings WHERE key=?", [.text(key)]) { $0.string(0) }
    }

    func setSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }

    struct FileFacts: Sendable {
        var path: String
        var size: Int64
        var mtime: Date
        var created: Date
        var fileID: Int64? = nil
    }

    func upsertDocument(_ f: FileFacts, origin: DocumentOrigin) throws -> (id: Int64, isNew: Bool, changed: Bool) {
        let url = URL(fileURLWithPath: f.path)
        let relative = relPath(f.path)
        let dir = relPath(url.deletingLastPathComponent().path)
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let existing = try db.first(
            "SELECT id, size, mtime, ocr_state, filename FROM documents WHERE path=?", [.text(relative)]
        ) { ($0.int(0), $0.int(1), $0.double(2), $0.int(3), $0.string(4)) }

        if let (id, size, mtime, state, oldName) = existing {
            let changed = size != f.size || abs(mtime - f.mtime.timeIntervalSince1970) > 1
            try db.run("""
                UPDATE documents SET size=?, mtime=?, missing=0, missing_since=NULL,
                                     directory=?, filename=?, ext=?, file_id=?
                WHERE id=?
                """, [.int(f.size), .double(f.mtime.timeIntervalSince1970),
                      .text(dir), .text(name), .text(ext), .int(f.fileID), .int(id)])
            if oldName != name { try refreshSearchIndex(id) }
            if changed {
                try db.run("UPDATE documents SET hash=NULL, original_hash=NULL, ocr_state=0 WHERE id=?",
                           [.int(id)])
            }
            return (id, false, changed || state == OCRState.pending.rawValue)
        }

        let id = try db.run("""
            INSERT INTO documents(path, directory, filename, ext, size, mtime, created_at, ocr_state, file_id)
            VALUES(?,?,?,?,?,?,?,0,?)
            """, [.text(relative), .text(dir), .text(name), .text(ext),
                  .int(f.size), .double(f.mtime.timeIntervalSince1970),
                  .double(f.created.timeIntervalSince1970), .int(f.fileID)])
        try refreshSearchIndex(id)
        try logOrigin(docID: id, origin, path: relative)
        return (id, true, true)
    }

    /// A whole scan in one transaction: a commit per file is most of its cost.
    func upsertDocuments(_ files: [FileFacts]) throws -> [(id: Int64, path: String, isNew: Bool, changed: Bool)] {
        try db.transaction {
            try files.map { f in
                let result = try upsertDocument(f, origin: .inLibrary)
                return (result.id, f.path, result.isNew, result.changed)
            }
        }
    }

    private func logOrigin(docID: Int64, _ origin: DocumentOrigin, path: String) throws {
        let detail: String
        var source: String?
        switch origin {
        case .scanned:
            detail = "Scanned"
        case .imported(let from):
            detail = "Imported from \(from)"
            source = from
        case .inLibrary:
            detail = "In library at \(path)"
        }
        try db.run("INSERT INTO events(doc_id, at, action, detail, from_path) VALUES(?,?,?,?,?)",
                   [.int(docID), .double(Date().timeIntervalSince1970),
                    .text(EventAction.added.rawValue), .text(detail), .text(source)])
    }

    func reconcileMissing(seenPaths: Set<String>) throws -> Int {
        let seenRelative = Set(seenPaths.map { relPath($0) })
        var stale: [Int64] = []
        try db.query("SELECT id, path FROM documents WHERE missing=0 AND deleted_at IS NULL") { row in
            if !seenRelative.contains(row.string(1)) { stale.append(row.int(0)) }
        }
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for id in stale {
                try db.run("UPDATE documents SET missing=1, missing_since=COALESCE(missing_since,?) WHERE id=?",
                           [.double(now), .int(id)])
            }
        }
        return stale.count
    }

    /// Moves a document to where its file turned up, matched by file-system ID rather than bytes.
    func relinkByFileID(_ f: FileFacts) throws -> Int64? {
        guard let fileID = f.fileID else { return nil }
        let relative = relPath(f.path)
        let rows = try db.map("SELECT id, path FROM documents WHERE file_id=? AND deleted_at IS NULL",
                              [.int(fileID)]) { ($0.int(0), $0.string(1)) }
        guard !rows.isEmpty, !rows.contains(where: { $0.1 == relative }) else { return nil }
        let taken = try db.first("SELECT id FROM documents WHERE path=?", [.text(relative)]) { $0.int(0) }
        guard taken == nil else { return nil }

        let moved = rows.filter { _, path in
            // A case-only rename still finds the same file at the old path.
            path.lowercased() == relative.lowercased()
                || FileScanner.fileID(url(forRelative: path)) != fileID
        }
        guard moved.count == 1, let id = moved.first?.0 else { return nil }
        try updatePath(id, to: f.path)
        return id
    }

    func relinkByHash(hash: String, newPath: String) throws -> Int64? {
        let match = try db.first(
            "SELECT id FROM documents WHERE hash=? AND missing=1 AND deleted_at IS NULL LIMIT 1", [.text(hash)],
            { $0.int(0) })
        guard let id = match else { return nil }
        let url = URL(fileURLWithPath: newPath)
        try db.run("""
            UPDATE documents SET path=?, directory=?, filename=?, missing=0, missing_since=NULL
            WHERE id=?
            """, [.text(relPath(newPath)), .text(relPath(url.deletingLastPathComponent().path)),
                  .text(url.lastPathComponent), .int(id)])
        try refreshSearchIndex(id)
        return id
    }

    func markMissing(path: String) throws {
        try db.run("UPDATE documents SET missing=1, missing_since=COALESCE(missing_since,?) WHERE path=?",
                   [.double(Date().timeIntervalSince1970), .text(relPath(path))])
    }

    func documentCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM documents") { Int($0.int(0)) } ?? 0
    }

    func setHash(_ id: Int64, _ hash: String, isOriginal: Bool = false) throws {
        if isOriginal {
            try db.run("UPDATE documents SET hash=?, original_hash=? WHERE id=?",
                       [.text(hash), .text(hash), .int(id)])
        } else {
            try db.run("UPDATE documents SET hash=? WHERE id=?", [.text(hash), .int(id)])
        }
    }

    func documents(matchingHash hash: String, excluding docID: Int64? = nil) throws -> [Int64] {
        try db.map("""
            SELECT id FROM documents
            WHERE (hash = ? OR original_hash = ?) AND id <> COALESCE(?, -1)
            """, [.text(hash), .text(hash), .int(docID)]) { $0.int(0) }
    }

    struct DuplicateMatch: Sendable {
        var docID: Int64
        var filename: String
        var path: String
    }

    func findDuplicate(hash: String) throws -> DuplicateMatch? {
        try db.first("""
            SELECT id, filename, path FROM documents
            WHERE (hash = ? OR original_hash = ?) AND missing = 0 AND deleted_at IS NULL
            LIMIT 1
            """, [.text(hash), .text(hash)]) {
            DuplicateMatch(docID: $0.int(0), filename: $0.string(1), path: absPath($0.string(2)))
        }
    }

    func documentIDsNeedingOCR(limit: Int = 5000) throws -> [(id: Int64, path: String, ext: String)] {
        try db.map("""
            SELECT id, path, ext FROM documents
            WHERE ocr_state=0 AND missing=0 AND deleted_at IS NULL ORDER BY created_at DESC LIMIT ?
            """, [.int(limit)]) { ($0.int(0), absPath($0.string(1)), $0.string(2)) }
    }

    func allDocumentIDs(limit: Int = 20000) throws -> [Int64] {
        try db.map("SELECT id FROM documents WHERE missing=0 AND deleted_at IS NULL ORDER BY created_at DESC LIMIT ?",
                   [.int(limit)]) { $0.int(0) }
    }

    func documentPath(_ id: Int64) throws -> String? {
        try db.first("SELECT path FROM documents WHERE id=?", [.int(id)]) { absPath($0.string(0)) }
    }

    func documentPageCount(_ id: Int64) throws -> Int? {
        try db.first("SELECT page_count FROM documents WHERE id=?", [.int(id)]) {
            $0.intOrNil(0).map(Int.init)
        } ?? nil
    }

    func storeOCR(docID: Int64, text: String, words: Int,
                  source: String, elapsedMS: Int, pageCount: Int?) throws {
        try db.transaction {
            try refreshSearchIndex(docID, body: text)
            try db.run("""
                INSERT INTO ocr_stats(doc_id, words, source, engine_ms)
                VALUES(?,?,?,?)
                ON CONFLICT(doc_id) DO UPDATE SET
                    words=excluded.words, source=excluded.source, engine_ms=excluded.engine_ms
                """, [.int(docID), .int(words), .text(source), .int(elapsedMS)])
            try db.run("UPDATE documents SET ocr_state=1, indexed_at=?, page_count=? WHERE id=?",
                       [.double(Date().timeIntervalSince1970), .int(pageCount.map(Int64.init)), .int(docID)])
        }
    }

    func markOCR(_ id: Int64, state: OCRState) throws {
        try db.run("UPDATE documents SET ocr_state=? WHERE id=?", [.int(state.rawValue), .int(id)])
    }

    func ocrText(_ id: Int64) throws -> String {
        try db.first("SELECT body FROM doc_fts WHERE rowid=?", [.int(id)]) { $0.string(0) } ?? ""
    }

    /// `bm25()` weights for `doc_fts`, in column order: title, correspondent,
    /// doc_type, tags, fields, notes, filename, body. A title hit should
    /// outrank a body hit by a wide margin — the body is the longest column
    /// and would otherwise dominate purely by having more chances to match.
    static let bm25Weights = "10.0, 8.0, 4.0, 4.0, 2.0, 2.0, 3.0, 1.0"

    func refreshSearchIndex(_ docID: Int64, body: String? = nil) throws {
        let text: String
        if let body {
            text = body
        } else {
            text = try db.first("SELECT body FROM doc_fts WHERE rowid=?", [.int(docID)],
                                { $0.string(0) }) ?? ""
        }
        try db.run("DELETE FROM doc_fts WHERE rowid=?", [.int(docID)])
        try db.run("""
            INSERT INTO doc_fts(rowid, title, correspondent, doc_type, tags, fields, notes, filename, body)
            SELECT d.id,
                   COALESCE(m.title, ''), COALESCE(ec.name, ''), COALESCE(et.name, ''),
                   COALESCE((SELECT group_concat(t.name, ' ') FROM document_tags dt
                              JOIN tags t ON t.id = dt.tag_id WHERE dt.doc_id = d.id), ''),
                   COALESCE((SELECT group_concat(v.value, ' ') FROM field_values v
                              WHERE v.doc_id = d.id), ''),
                   COALESCE((SELECT group_concat(n.body, ' ') FROM notes n
                              WHERE n.doc_id = d.id), ''),
                   d.filename,
                   ?
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.id = ?
            """, [.text(text), .int(docID)])
    }

    func refreshSearchIndex(_ docIDs: [Int64]) throws {
        guard !docIDs.isEmpty else { return }
        try db.transaction {
            for id in docIDs { try refreshSearchIndex(id) }
        }
    }

    func documentIDs(withTag tagID: Int64) throws -> [Int64] {
        try db.map("SELECT doc_id FROM document_tags WHERE tag_id=?", [.int(tagID)]) { $0.int(0) }
    }

    struct MetadataPatch: Sendable {
        var docID: Int64
        var title: String?
        var correspondent: String?
        var docType: String?
        var language: String?
        var summary: String?
        var intent: String?
        var docDate: Date?
        var dateSource: String?
        var source: String?
        var amount: String?
    }

    func storeMetadata(_ p: MetadataPatch) throws {
        let correspondentID = try entityID(named: p.correspondent, builtin: "correspondent")
        let docTypeID = try entityID(named: p.docType, builtin: "doc_type")
        try db.run("""
            INSERT INTO metadata(doc_id, title, correspondent_id, doc_type_id, language, summary,
                                 intent, doc_date, date_source, source, amount, amount_value)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(doc_id) DO UPDATE SET
                title=COALESCE(excluded.title, metadata.title),
                correspondent_id=COALESCE(excluded.correspondent_id, metadata.correspondent_id),
                doc_type_id=COALESCE(excluded.doc_type_id, metadata.doc_type_id),
                language=COALESCE(excluded.language, metadata.language),
                summary=COALESCE(excluded.summary, metadata.summary),
                intent=COALESCE(excluded.intent, metadata.intent),
                doc_date=COALESCE(excluded.doc_date, metadata.doc_date),
                date_source=COALESCE(excluded.date_source, metadata.date_source),
                source=COALESCE(excluded.source, metadata.source),
                amount=COALESCE(excluded.amount, metadata.amount),
                amount_value=COALESCE(excluded.amount_value, metadata.amount_value)
            """, [.int(p.docID), .text(p.title), .int(correspondentID), .int(docTypeID),
                  .text(p.language), .text(p.summary), .text(p.intent),
                  .date(p.docDate.map { DayDate.startOfDay($0) }),
                  .text(p.dateSource), .text(p.source), .text(p.amount),
                  .double(p.amount.flatMap { FieldType.number(from: $0) })])
        try refreshSearchIndex(p.docID)
    }

    func overwriteMetadataField(_ docID: Int64, column: String, value: String?) throws {
        guard Store.editableColumns.contains(column) else { return }
        try db.run("INSERT OR IGNORE INTO metadata(doc_id) VALUES(?)", [.int(docID)])
        if let idColumn = Store.entityColumns[column] {
            let id = try entityID(named: value, builtin: column)
            try db.run("UPDATE metadata SET \(idColumn)=? WHERE doc_id=?", [.int(id), .int(docID)])
            try refreshSearchIndex(docID)
            return
        }
        try db.run("UPDATE metadata SET \(column)=? WHERE doc_id=?", [.text(value), .int(docID)])
        if column == "amount" {
            try db.run("UPDATE metadata SET amount_value=? WHERE doc_id=?",
                       [.double(value.flatMap { FieldType.number(from: $0) }), .int(docID)])
        }
        try refreshSearchIndex(docID)
    }

    func setDocumentDate(_ docID: Int64, _ date: Date?, source: String = "manual") throws {
        try db.run("INSERT OR IGNORE INTO metadata(doc_id) VALUES(?)", [.int(docID)])
        try db.run("UPDATE metadata SET doc_date=?, date_source=? WHERE doc_id=?",
                   [.date(date.map { DayDate.startOfDay($0) }), .text(source), .int(docID)])
    }

    func setDateCandidates(_ candidates: [DateCandidate], for docID: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM date_candidates WHERE doc_id=?", [.int(docID)])
            for (rank, c) in candidates.enumerated() {
                try db.run("""
                    INSERT OR IGNORE INTO date_candidates(doc_id, date, source, labelled, cue, rank)
                    VALUES(?,?,?,?,?,?)
                    """, [.int(docID), .date(DayDate.startOfDay(c.date)), .text(c.source),
                          .bool(c.labelled), .text(c.cue), .int(Int64(rank))])
            }
        }
    }

    func dateCandidates(for docID: Int64) throws -> [DateCandidate] {
        try db.map("""
            SELECT date, source, labelled, cue FROM date_candidates
            WHERE doc_id=? ORDER BY rank
            """, [.int(docID)]) {
            DateCandidate(date: Date(timeIntervalSince1970: $0.double(0)), source: $0.string(1),
                          labelled: $0.bool(2), cue: $0.stringOrNil(3))
        }
    }

    func dominantLanguage() throws -> String? {
        try db.first("""
            SELECT m.language FROM metadata m
            JOIN documents d ON d.id = m.doc_id AND d.missing=0 AND d.deleted_at IS NULL
            WHERE m.language IS NOT NULL AND TRIM(m.language) <> ''
            GROUP BY m.language COLLATE NOCASE ORDER BY COUNT(*) DESC LIMIT 1
            """) { $0.stringOrNil(0) } ?? nil
    }

    func eventCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM events") { Int($0.int(0)) } ?? 0
    }

    func updatePath(_ docID: Int64, to newPath: String) throws {
        let url = URL(fileURLWithPath: newPath)
        try db.run("""
            UPDATE documents SET path=?, directory=?, filename=?, ext=?, missing=0, missing_since=NULL WHERE id=?
            """, [.text(relPath(newPath)), .text(relPath(url.deletingLastPathComponent().path)),
                  .text(url.lastPathComponent), .text(url.pathExtension.lowercased()), .int(docID)])
        try refreshSearchIndex(docID)
    }

    /// A folder renamed as a whole: every path under it follows, rather than
    /// each document going missing and being found again by its hash.
    func moveFolder(from old: String, to new: String) throws {
        let columns = [("documents", "path"), ("documents", "directory"), ("aliases", "path")]
        // Events keep the absolute paths they were logged with.
        let absolute = [("events", "from_path"), ("events", "to_path")]
        try db.transaction {
            for (table, column) in columns + absolute {
                let isAbsolute = table == "events"
                let (from, to) = isAbsolute ? (Store.canonical(old), Store.canonical(new))
                                            : (relPath(old), relPath(new))
                try db.run("""
                    UPDATE \(table) SET \(column) = ?2 || substr(\(column), length(?1) + 1)
                    WHERE \(column) = ?1 OR substr(\(column), 1, length(?1) + 1) = ?1 || '/'
                    """, [.text(from), .text(to)])
            }
        }
    }

    func setSizes(_ docID: Int64, size: Int64, originalSize: Int64?) throws {
        try db.run("UPDATE documents SET size=?, original_size=COALESCE(?, original_size) WHERE id=?",
                   [.int(size), .int(originalSize), .int(docID)])
    }

    /// `doc_fts` is a virtual table and so carries no foreign key: its row has
    /// to go by hand, or the text stays searchable after the document is gone.
    func deleteDocument(_ docID: Int64) throws {
        try db.run("DELETE FROM doc_fts WHERE rowid=?", [.int(docID)])
        try db.run("DELETE FROM documents WHERE id=?", [.int(docID)])
    }
}
