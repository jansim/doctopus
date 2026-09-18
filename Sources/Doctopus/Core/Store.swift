import Foundation

/// Serialized owner of the SQLite index. Every read and write funnels through
/// here, which keeps the connection single-threaded without a mutex.
actor Store {
    let db: Database
    /// The `library.doctopus` directory holding the database.
    let containerURL: URL
    /// The library root: the folder that contains `library.doctopus`. Document
    /// paths in the database are stored relative to this.
    let root: URL
    /// Stable identifier from `meta.json`, unchanged when the folder moves.
    let libraryID: LibraryID
    var fieldCache: [Field]?

    private let rootPrefix: String   // root.path + "/"

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = URL(fileURLWithPath: Store.canonical(directory.standardizedFileURL.path),
                            isDirectory: true)
        self.containerURL = container
        self.root = container.deletingLastPathComponent()
        self.rootPrefix = container.deletingLastPathComponent().path + "/"
        self.libraryID = try Store.loadOrCreateMeta(in: container)
        db = try Database(path: container.appendingPathComponent("index.sqlite").path)
        try Schema.migrate(db)
    }

    // MARK: - Relative-path translation
    //
    // The database stores every document/alias path relative to `root` so the
    // library is portable. Nothing outside `Store` sees a relative path: reads
    // hand back absolute URLs, writes take them.

    /// Normalises the `/var`, `/tmp`, `/etc` symlinks to their `/private/…`
    /// targets so a path from the file-system enumerator, from FSEvents and from
    /// the app's own `URL`s all compare equal. `/Users/…` paths are untouched.
    nonisolated static func canonical(_ path: String) -> String {
        for prefix in ["/var/", "/tmp/", "/etc/"] where path.hasPrefix(prefix) {
            return "/private" + path
        }
        return path
    }

    /// Absolute filesystem path → root-relative. Paths outside the root (a
    /// tag-alias folder the user pointed elsewhere) are stored as-is.
    nonisolated func relPath(_ absolute: String) -> String {
        let path = Store.canonical(absolute)
        if path == root.path { return "" }
        guard path.hasPrefix(rootPrefix) else { return path }
        return String(path.dropFirst(rootPrefix.count))
    }

    /// Root-relative → absolute. An already-absolute value is returned untouched.
    nonisolated func absPath(_ relative: String) -> String {
        if relative.isEmpty { return root.path }
        if relative.hasPrefix("/") { return relative }
        return rootPrefix + relative
    }

    nonisolated func url(forRelative relative: String) -> URL {
        URL(fileURLWithPath: absPath(relative))
    }

    // MARK: - meta.json

    /// What this build of Doctopus writes. A library stamped with a higher
    /// number was written by a newer app, and reading it with this one would
    /// misinterpret whatever it does not know about — so it is refused instead.
    static let formatVersion = 2

    /// This build's marketing version, stamped into `meta.json` so a library
    /// that has to be refused can say which app last wrote it.
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    enum OpenError: Swift.Error, CustomStringConvertible {
        /// The library was written by a newer Doctopus than this one.
        case futureFormat(found: Int, supported: Int, writtenBy: String?)

        var description: String {
            switch self {
            case .futureFormat(let found, let supported, let writtenBy):
                let by = writtenBy.map { " (last written by Doctopus \($0))" } ?? ""
                return "This library uses format version \(found)\(by), but this "
                    + "version of Doctopus only understands \(supported). Update Doctopus to open it."
            }
        }
    }

    private struct Meta: Codable {
        var id: String
        var formatVersion: Int
        var name: String?
        /// The marketing version of the app that last wrote this file.
        var appVersion: String?
    }

    private static func loadOrCreateMeta(in container: URL) throws -> LibraryID {
        let metaURL = container.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           var meta = try? JSONDecoder().decode(Meta.self, from: data),
           !meta.id.isEmpty {
            // Refuse a library from the future rather than silently misreading
            // it: a newer app may have written columns and tables this build
            // would drop on the first write.
            guard meta.formatVersion <= formatVersion else {
                throw OpenError.futureFormat(found: meta.formatVersion,
                                             supported: formatVersion,
                                             writtenBy: meta.appVersion)
            }
            // Opening an older library upgrades it in step with the schema
            // migrations that are about to run.
            if meta.formatVersion < formatVersion || meta.appVersion != appVersion {
                meta.formatVersion = formatVersion
                meta.appVersion = appVersion
                if let updated = try? JSONEncoder().encode(meta) {
                    try? updated.write(to: metaURL, options: .atomic)
                }
            }
            return meta.id
        }
        let meta = Meta(id: UUID().uuidString, formatVersion: formatVersion,
                        name: container.deletingLastPathComponent().lastPathComponent,
                        appVersion: appVersion)
        let data = try JSONEncoder().encode(meta)
        try? data.write(to: metaURL, options: .atomic)
        return meta.id
    }

    // MARK: - Settings

    func setting(_ key: String) throws -> String? {
        try db.first("SELECT value FROM settings WHERE key=?", [.text(key)]) { $0.string(0) }
    }

    func setSetting(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }

    // MARK: - Document ingest

    struct FileFacts: Sendable {
        /// Absolute filesystem path; `Store` stores it relative to the root.
        var path: String
        var size: Int64
        var mtime: Date
        var created: Date
    }

    /// Inserts or refreshes the row for a file. Returns the row id and whether
    /// the content changed (and therefore needs re-OCR).
    func upsertDocument(_ f: FileFacts) throws -> (id: Int64, isNew: Bool, changed: Bool) {
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
                                     directory=?, filename=?, ext=?
                WHERE id=?
                """, [.int(f.size), .double(f.mtime.timeIntervalSince1970),
                      .text(dir), .text(name), .text(ext), .int(id)])
            // Only the filename is indexed here, so a scan that finds nothing
            // new does not rewrite the search index for every document it sees.
            if oldName != name { try refreshSearchIndex(id) }
            if changed {
                try db.run("UPDATE documents SET hash=NULL, original_hash=NULL, ocr_state=0 WHERE id=?",
                           [.int(id)])
            }
            return (id, false, changed || state == OCRState.pending.rawValue)
        }

        let id = try db.run("""
            INSERT INTO documents(path, directory, filename, ext, size, mtime, created_at, ocr_state)
            VALUES(?,?,?,?,?,?,?,0)
            """, [.text(relative), .text(dir), .text(name), .text(ext),
                  .int(f.size), .double(f.mtime.timeIntervalSince1970),
                  .double(f.created.timeIntervalSince1970)])
        try refreshSearchIndex(id)
        return (id, true, true)
    }

    /// Disk is the source of truth: a vanished path that reappears elsewhere with
    /// the same content is a move, not a deletion. `seenPaths` are absolute.
    func reconcileMissing(seenPaths: Set<String>) throws -> Int {
        let seenRelative = Set(seenPaths.map { relPath($0) })
        var stale: [Int64] = []
        try db.query("SELECT id, path FROM documents WHERE missing=0 AND deleted_at IS NULL") { row in
            if !seenRelative.contains(row.string(1)) { stale.append(row.int(0)) }
        }
        let now = Date().timeIntervalSince1970
        for id in stale {
            try db.run("UPDATE documents SET missing=1, missing_since=COALESCE(missing_since,?) WHERE id=?",
                       [.double(now), .int(id)])
        }
        return stale.count
    }

    /// Reattaches a missing row to a new path when the content hash matches,
    /// so a Finder move keeps all metadata. `newPath` is absolute.
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

    /// `path` is absolute.
    func markMissing(path: String) throws {
        try db.run("UPDATE documents SET missing=1, missing_since=COALESCE(missing_since,?) WHERE path=?",
                   [.double(Date().timeIntervalSince1970), .text(relPath(path))])
    }

    /// How long a row whose file has vanished is kept. It is the row that makes
    /// a Finder move survive — relinked by content hash, with its tags, title
    /// and history intact — and rows are tiny, so the old week was far too
    /// short to buy anything. Paperless settled on thirty days; so does this.
    static let missingGrace: TimeInterval = 30 * 24 * 3600

    /// Missing rows are kept for a while on purpose: they are what lets a file
    /// moved in Finder be relinked by content hash with its tags and metadata
    /// intact. Past the grace period they are just dead weight — unless the
    /// file is sitting in the Trash, where it can still be put back, and
    /// forgetting the row now is exactly what would turn that into a brand-new
    /// document with nothing on it.
    @discardableResult
    func purgeMissing(olderThan seconds: TimeInterval = Store.missingGrace) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - seconds
        let doomed = try db.map("""
            SELECT id, filename, deleted_path FROM documents
            WHERE missing=1 AND deleted_at IS NULL AND COALESCE(missing_since, 0) < ?
            """, [.double(cutoff)]) { ($0.int(0), $0.string(1), $0.stringOrNil(2)) }
        guard !doomed.isEmpty else { return 0 }

        let inTrash = Store.trashedFilenames()
        var purged = 0
        for (id, filename, trashPath) in doomed {
            if let trashPath, FileManager.default.fileExists(atPath: trashPath) { continue }
            if inTrash.contains(filename) { continue }
            try deleteDocument(id)
            purged += 1
        }
        return purged
    }

    /// What is in the user's Trash right now, by filename. macOS renames a
    /// collision on the way in ("scan 2.pdf"), so this is a hint rather than a
    /// proof — but erring towards keeping a row costs a hundred bytes, and
    /// erring the other way costs everything anyone ever typed about it.
    private static func trashedFilenames() -> Set<String> {
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: trash, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants])
        else { return [] }
        return Set(contents.map(\.lastPathComponent))
    }

    // MARK: - Soft delete

    /// Marks a document deleted without forgetting it. `trashPath` is where the
    /// file ended up in the Trash, which is what Restore needs to put it back.
    func softDelete(_ docID: Int64, trashPath: String?) throws {
        let now = Date().timeIntervalSince1970
        try db.run("""
            UPDATE documents SET deleted_at=?, deleted_path=?, missing=1,
                                 missing_since=COALESCE(missing_since, ?)
            WHERE id=?
            """, [.double(now), .text(trashPath), .double(now), .int(docID)])
    }

    /// Where in the Trash a deleted document's file went, if it is still there.
    func trashedFile(_ docID: Int64) throws -> String? {
        guard let path = try db.first("SELECT deleted_path FROM documents WHERE id=?",
                                      [.int(docID)], { $0.stringOrNil(0) }) ?? nil
        else { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Brings a deleted document back. The caller puts the file back first;
    /// this revives the row, with everything that was ever on it.
    func restore(_ docID: Int64, at path: String? = nil) throws {
        if let path {
            try updatePath(docID, to: path)
        }
        try db.run("""
            UPDATE documents SET deleted_at=NULL, deleted_path=NULL, missing=0, missing_since=NULL
            WHERE id=?
            """, [.int(docID)])
    }

    /// Deleted rows past the grace period, for good. The file is the Trash's
    /// business; this only forgets the row.
    @discardableResult
    func purgeDeleted(olderThan seconds: TimeInterval = Store.missingGrace) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - seconds
        let doomed = try db.map(
            "SELECT id FROM documents WHERE deleted_at IS NOT NULL AND deleted_at < ?",
            [.double(cutoff)]) { $0.int(0) }
        for id in doomed { try deleteDocument(id) }
        return doomed.count
    }

    func deletedCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM documents WHERE deleted_at IS NOT NULL") {
            Int($0.int(0))
        } ?? 0
    }

    /// Records the content hash of the file as it is on disk now. `isOriginal`
    /// additionally stamps `original_hash`: the bytes as they arrived, before
    /// optimization rewrote them. Both are needed, because a document imported
    /// and then re-encoded no longer hashes to what its source file does.
    func setHash(_ id: Int64, _ hash: String, isOriginal: Bool = false) throws {
        if isOriginal {
            try db.run("UPDATE documents SET hash=?, original_hash=? WHERE id=?",
                       [.text(hash), .text(hash), .int(id)])
        } else {
            try db.run("UPDATE documents SET hash=? WHERE id=?", [.text(hash), .int(id)])
        }
    }

    /// Documents whose bytes match `hash`, as stored now or as they arrived.
    /// Matching both is what makes the check fire for documents Doctopus
    /// optimized itself — their `hash` is of the re-encoded file, which the
    /// original will never match.
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

    /// Finds any existing non-deleted document that matches `hash` either on disk
    /// or in its pre-optimized original form.
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

    /// Every document still present on disk, newest first. The input for a
    /// library-wide manual pass, which wants ids rather than whole rows.
    func allDocumentIDs(limit: Int = 20000) throws -> [Int64] {
        try db.map("SELECT id FROM documents WHERE missing=0 AND deleted_at IS NULL ORDER BY created_at DESC LIMIT ?",
                   [.int(limit)]) { $0.int(0) }
    }

    /// Absolute path of a document.
    func documentPath(_ id: Int64) throws -> String? {
        try db.first("SELECT path FROM documents WHERE id=?", [.int(id)]) { absPath($0.string(0)) }
    }

    /// Pages counted the last time the document was read, for a pass that asks
    /// the model about a document already in the index.
    func documentPageCount(_ id: Int64) throws -> Int? {
        try db.first("SELECT page_count FROM documents WHERE id=?", [.int(id)]) {
            $0.intOrNil(0).map(Int.init)
        } ?? nil
    }

    // MARK: - OCR

    func storeOCR(docID: Int64, text: String, confidence: Double, words: Int,
                  source: String, elapsedMS: Int, pageCount: Int?) throws {
        try db.transaction {
            try refreshSearchIndex(docID, body: text)
            try db.run("""
                INSERT INTO ocr_stats(doc_id, confidence, words, source, engine_ms)
                VALUES(?,?,?,?,?)
                ON CONFLICT(doc_id) DO UPDATE SET
                    confidence=excluded.confidence, words=excluded.words,
                    source=excluded.source, engine_ms=excluded.engine_ms
                """, [.int(docID), .double(confidence), .int(words), .text(source), .int(elapsedMS)])
            try db.run("UPDATE documents SET ocr_state=1, indexed_at=?, page_count=? WHERE id=?",
                       [.double(Date().timeIntervalSince1970), .int(pageCount.map(Int64.init)), .int(docID)])
        }
    }

    func markOCR(_ id: Int64, state: OCRState) throws {
        try db.run("UPDATE documents SET ocr_state=? WHERE id=?", [.int(state.rawValue), .int(id)])
    }

    /// The extracted text of one document. `doc_fts` is keyed by `rowid`, so
    /// this is a single row lookup rather than a scan of the whole corpus.
    func ocrText(_ id: Int64) throws -> String {
        try db.first("SELECT body FROM doc_fts WHERE rowid=?", [.int(id)]) { $0.string(0) } ?? ""
    }

    // MARK: - Search index

    /// `bm25()` weights for `doc_fts`, in column order: title, correspondent,
    /// doc_type, tags, fields, notes, filename, body. A title hit should
    /// outrank a body hit by a wide margin — the body is the longest column
    /// and would otherwise dominate purely by having more chances to match.
    static let bm25Weights = "10.0, 8.0, 4.0, 4.0, 2.0, 2.0, 3.0, 1.0"

    /// Rebuilds one document's row in `doc_fts` from whatever the index holds
    /// about it now. Pass `body` when the extracted text is what changed;
    /// otherwise the text already indexed is carried over, so a metadata or
    /// tag edit never costs a re-extraction.
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

    /// Every document that carries a tag, for refreshing the index after the
    /// tag itself is renamed, merged or dropped.
    func documentIDs(withTag tagID: Int64) throws -> [Int64] {
        try db.map("SELECT doc_id FROM document_tags WHERE tag_id=?", [.int(tagID)]) { $0.int(0) }
    }

    // MARK: - Metadata

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
        var confidence: Double?
        var source: String?
        var amount: String?
    }

    /// The patch carries names; the index stores the entity they refer to,
    /// making one if this is the first document to name it.
    func storeMetadata(_ p: MetadataPatch) throws {
        let correspondentID = try entityID(named: p.correspondent, builtin: "correspondent")
        let docTypeID = try entityID(named: p.docType, builtin: "doc_type")
        try db.run("""
            INSERT INTO metadata(doc_id, title, correspondent_id, doc_type_id, language, summary,
                                 intent, doc_date, date_source, confidence, source, amount,
                                 amount_value)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(doc_id) DO UPDATE SET
                title=COALESCE(excluded.title, metadata.title),
                correspondent_id=COALESCE(excluded.correspondent_id, metadata.correspondent_id),
                doc_type_id=COALESCE(excluded.doc_type_id, metadata.doc_type_id),
                language=COALESCE(excluded.language, metadata.language),
                summary=COALESCE(excluded.summary, metadata.summary),
                intent=COALESCE(excluded.intent, metadata.intent),
                doc_date=COALESCE(excluded.doc_date, metadata.doc_date),
                date_source=COALESCE(excluded.date_source, metadata.date_source),
                confidence=COALESCE(excluded.confidence, metadata.confidence),
                source=COALESCE(excluded.source, metadata.source),
                amount=COALESCE(excluded.amount, metadata.amount),
                amount_value=COALESCE(excluded.amount_value, metadata.amount_value)
            """, [.int(p.docID), .text(p.title), .int(correspondentID), .int(docTypeID),
                  .text(p.language), .text(p.summary), .text(p.intent),
                  .date(p.docDate.map { DayDate.startOfDay($0) }),
                  .text(p.dateSource), .double(p.confidence), .text(p.source), .text(p.amount),
                  .double(p.amount.flatMap { FieldType.number(from: $0) })])
        try refreshSearchIndex(p.docID)
    }

    /// User edits overwrite unconditionally (including clearing a field).
    func overwriteMetadataField(_ docID: Int64, column: String, value: String?) throws {
        guard Store.editableColumns.contains(column) else { return }
        try db.run("INSERT OR IGNORE INTO metadata(doc_id) VALUES(?)", [.int(docID)])
        // A taxonomy value is a row; typing a new name into the inspector makes
        // one, exactly as picking an existing name reuses it.
        if let idColumn = Store.entityColumns[column] {
            let id = try entityID(named: value, builtin: column)
            try db.run("UPDATE metadata SET \(idColumn)=? WHERE doc_id=?", [.int(id), .int(docID)])
            try refreshSearchIndex(docID)
            return
        }
        try db.run("UPDATE metadata SET \(column)=? WHERE doc_id=?", [.text(value), .int(docID)])
        // The amount's text keeps the currency; its number is what sorts.
        if column == "amount" {
            try db.run("UPDATE metadata SET amount_value=? WHERE doc_id=?",
                       [.double(value.flatMap { FieldType.number(from: $0) }), .int(docID)])
        }
        try refreshSearchIndex(docID)
    }

    /// A document is issued on a day, so that is what is stored: the UTC start
    /// of it, never an instant in a timezone nobody recorded.
    func setDocumentDate(_ docID: Int64, _ date: Date?, source: String = "manual") throws {
        try db.run("INSERT OR IGNORE INTO metadata(doc_id) VALUES(?)", [.int(docID)])
        try db.run("UPDATE metadata SET doc_date=?, date_source=? WHERE doc_id=?",
                   [.date(date.map { DayDate.startOfDay($0) }), .text(source), .int(docID)])
    }

    // MARK: - Date candidates

    /// Replaces the dates found for a document, best first. Keeping the ones
    /// that were not chosen is what lets the review offer them as a click
    /// rather than making someone retype the right one.
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

    /// The language most of this library's documents are in, which is what an
    /// automatic date order reads itself from.
    func dominantLanguage() throws -> String? {
        try db.first("""
            SELECT m.language FROM metadata m
            JOIN documents d ON d.id = m.doc_id AND d.missing=0 AND d.deleted_at IS NULL
            WHERE m.language IS NOT NULL AND TRIM(m.language) <> ''
            GROUP BY m.language COLLATE NOCASE ORDER BY COUNT(*) DESC LIMIT 1
            """) { $0.stringOrNil(0) } ?? nil
    }

    // MARK: - Tags

    /// Every tag, with how many live documents carry it, in the order the
    /// sidebar draws them: each parent immediately followed by its children,
    /// alphabetically within a level, and `depth` filled in so the view only
    /// has to indent.
    func tags() throws -> [Tag] {
        let flat = try db.map("""
            SELECT t.id, t.name, t.color, t.mirrors, t.folder, COUNT(dt.doc_id), t.parent_id
            FROM tags t
            LEFT JOIN document_tags dt ON dt.tag_id = t.id
            LEFT JOIN documents d ON d.id = dt.doc_id AND d.missing=0 AND d.deleted_at IS NULL
            GROUP BY t.id ORDER BY t.name COLLATE NOCASE
            """) {
            Tag(tagID: $0.int(0), name: $0.string(1), color: $0.int(2),
                mirrors: $0.bool(3), folder: $0.stringOrNil(4), count: Int($0.int(5)),
                parentID: $0.intOrNil(6))
        }
        return Store.nested(flat)
    }

    /// Flattens a tag list into drawing order, stamping each one's depth. A tag
    /// whose parent is missing — or which is part of a cycle some older build
    /// wrote — is treated as a root rather than being dropped.
    nonisolated static func nested(_ tags: [Tag]) -> [Tag] {
        var children: [Int64: [Tag]] = [:]
        var roots: [Tag] = []
        let known = Set(tags.map(\.tagID))
        for tag in tags {
            if let parent = tag.parentID, parent != tag.tagID, known.contains(parent) {
                children[parent, default: []].append(tag)
            } else {
                roots.append(tag)
            }
        }
        var out: [Tag] = []
        var placed = Set<Int64>()
        func walk(_ tag: Tag, depth: Int) {
            guard placed.insert(tag.tagID).inserted else { return }
            var stamped = tag
            stamped.depth = depth
            out.append(stamped)
            for child in children[tag.tagID] ?? [] { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        // Anything left is in a cycle; show it rather than losing it.
        for tag in tags where !placed.contains(tag.tagID) { walk(tag, depth: 0) }
        return out
    }

    /// The tags above this one, nearest parent first.
    func ancestors(of tagID: Int64) throws -> [Int64] {
        var out: [Int64] = []
        var current = tagID
        var guardrail = 0
        while guardrail < Tag.maxDepth + 1 {
            guardrail += 1
            guard let parent = try db.first("SELECT parent_id FROM tags WHERE id=?", [.int(current)],
                                            { $0.intOrNil(0) }) ?? nil else { break }
            guard !out.contains(parent), parent != tagID else { break }
            out.append(parent)
            current = parent
        }
        return out
    }

    /// Moves a tag under another, or to the top level with `nil`.
    ///
    /// Refuses a tag as its own parent, a descendant as its parent, and a move
    /// that would push the tree past its depth cap. Re-runs ancestor assignment
    /// over every document that already carries the tag, so the documents catch
    /// up with the new shape rather than being right only for what is tagged
    /// next.
    @discardableResult
    func setTagParent(_ tagID: Int64, to parentID: Int64?) throws -> Bool {
        guard tagID != parentID else { return false }
        if let parentID {
            // A descendant as the parent would make a cycle out of the tree.
            if try ancestors(of: parentID).contains(tagID) { return false }
            let above = try ancestors(of: parentID).count + 1
            let below = try depthBelow(tagID)
            guard above + below < Tag.maxDepth else { return false }
        }
        try db.run("UPDATE tags SET parent_id=? WHERE id=?", [.int(parentID), .int(tagID)])
        try reapplyAncestors(of: tagID)
        return true
    }

    /// How many levels of tags sit under this one.
    private func depthBelow(_ tagID: Int64) throws -> Int {
        let children = try db.map("SELECT id FROM tags WHERE parent_id=?", [.int(tagID)]) { $0.int(0) }
        guard !children.isEmpty else { return 0 }
        var deepest = 0
        for child in children where child != tagID {
            deepest = try max(deepest, depthBelow(child) + 1)
        }
        return deepest
    }

    /// Gives every document carrying `tagID` — or anything under it — the
    /// ancestors it should now have.
    func reapplyAncestors(of tagID: Int64) throws {
        var subtree = [tagID]
        var frontier = [tagID]
        var depth = 0
        while !frontier.isEmpty, depth <= Tag.maxDepth {
            depth += 1
            var next: [Int64] = []
            for id in frontier {
                next += try db.map("SELECT id FROM tags WHERE parent_id=?", [.int(id)]) { $0.int(0) }
            }
            next.removeAll { subtree.contains($0) }
            subtree += next
            frontier = next
        }
        for id in subtree {
            let above = try ancestors(of: id)
            guard !above.isEmpty else { continue }
            let docs = try documentIDs(withTag: id)
            for doc in docs {
                for parent in above {
                    try db.run("INSERT OR IGNORE INTO document_tags(doc_id, tag_id, auto) VALUES(?,?,1)",
                               [.int(doc), .int(parent)])
                }
            }
            try refreshSearchIndex(docs)
        }
    }

    @discardableResult
    func tagID(named name: String, color: Int64 = 0) throws -> Int64 {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        if let id = try db.first("SELECT id FROM tags WHERE name=? COLLATE NOCASE", [.text(clean)], { $0.int(0) }) {
            return id
        }
        return try db.run("INSERT INTO tags(name, color) VALUES(?,?)", [.text(clean), .int(color)])
    }

    /// Assigning a tag assigns everything it sits under too. That is what makes
    /// "Finances" find what is filed as "Finances / Invoices" — the ancestors
    /// are marked automatic, since nobody chose them by hand.
    func assign(tag tagID: Int64, to docID: Int64, auto: Bool = false) throws {
        guard tagID > 0 else { return }
        try db.run("INSERT OR IGNORE INTO document_tags(doc_id, tag_id, auto) VALUES(?,?,?)",
                   [.int(docID), .int(tagID), .bool(auto)])
        for parent in try ancestors(of: tagID) {
            try db.run("INSERT OR IGNORE INTO document_tags(doc_id, tag_id, auto) VALUES(?,?,1)",
                       [.int(docID), .int(parent)])
        }
        try refreshSearchIndex(docID)
    }

    func unassign(tag tagID: Int64, from docID: Int64) throws {
        try db.run("DELETE FROM document_tags WHERE doc_id=? AND tag_id=?", [.int(docID), .int(tagID)])
        try refreshSearchIndex(docID)
    }

    func deleteTag(_ id: Int64) throws {
        let affected = try documentIDs(withTag: id)
        try db.run("DELETE FROM tags WHERE id=?", [.int(id)])
        try refreshSearchIndex(affected)
    }

    func setTagMirroring(_ id: Int64, _ on: Bool, folder: String?) throws {
        try db.run("UPDATE tags SET mirrors=?, folder=? WHERE id=?",
                   [.bool(on), .text(folder), .int(id)])
    }

    func tags(for docID: Int64) throws -> [Tag] {
        try db.map("""
            SELECT t.id, t.name, t.color, t.mirrors, t.folder, t.parent_id FROM tags t
            JOIN document_tags dt ON dt.tag_id=t.id WHERE dt.doc_id=?
            ORDER BY t.name COLLATE NOCASE
            """, [.int(docID)]) {
            Tag(tagID: $0.int(0), name: $0.string(1), color: $0.int(2), mirrors: $0.bool(3),
                folder: $0.stringOrNil(4), parentID: $0.intOrNil(5))
        }
    }

    // MARK: - Aliases

    /// `path` is the absolute location of the alias file.
    func recordAlias(docID: Int64, tagID: Int64?, path: String) throws {
        try db.run("INSERT OR REPLACE INTO aliases(doc_id, tag_id, path, created_at) VALUES(?,?,?,?)",
                   [.int(docID), .int(tagID), .text(relPath(path)), .double(Date().timeIntervalSince1970)])
    }

    func aliases(for docID: Int64) throws -> [(id: Int64, tagID: Int64?, path: String)] {
        try db.map("SELECT id, tag_id, path FROM aliases WHERE doc_id=?", [.int(docID)]) {
            ($0.int(0), $0.intOrNil(1), absPath($0.string(2)))
        }
    }

    func deleteAlias(id: Int64) throws {
        try db.run("DELETE FROM aliases WHERE id=?", [.int(id)])
    }

    // MARK: - History and the processing queue
    //
    // Two different things, kept apart. `events` is the record of what happened
    // to a document: append-only, never trimmed, and the only honest answer to
    // "why is this file here". `processing` is the recency view the review
    // reads — bounded, with the one piece of state that is its own, whether an
    // entry has been signed off — and it reads everything else back from the
    // event it points at.

    /// How many entries the review queue keeps on show. The history behind it
    /// is not trimmed; only this view is.
    static let queueLength = 500

    func logProcessing(docID: Int64, action: String, detail: String?, confidence: Double?,
                       rule: String?, from: String?, to: String?, approved: Bool) throws {
        let eventID = try db.run("""
            INSERT INTO events(doc_id, at, action, detail, confidence, rule, from_path, to_path)
            VALUES(?,?,?,?,?,?,?,?)
            """, [.int(docID), .double(Date().timeIntervalSince1970), .text(action), .text(detail),
                  .double(confidence), .text(rule), .text(from), .text(to)])
        try db.run("INSERT INTO processing(event_id, doc_id, status) VALUES(?,?,?)",
                   [.int(eventID), .int(docID), .bool(approved)])
        // An entry that needs review makes the document need review, so the
        // status dot and the inspector agree with the queue. An approved entry
        // leaves the document as it was: a later "indexed" does not settle an
        // earlier question.
        if !approved {
            try db.run("UPDATE documents SET approved=0 WHERE id=?", [.int(docID)])
        }
        // Keep the view bounded. Ids are monotonic, so this is a range delete
        // rather than a sort of the whole table on every insert. The offset is
        // one short of the length because it names the oldest row to keep.
        try db.run("""
            DELETE FROM processing
            WHERE id < COALESCE((SELECT id FROM processing ORDER BY id DESC LIMIT 1 OFFSET ?), 0)
            """, [.int(Store.queueLength - 1)])
    }

    /// A change somebody made by hand. It joins the record but never the
    /// review queue: what the user typed is the answer, not a proposal, so
    /// recording it must not push the document back into review.
    func logEdit(docID: Int64, detail: String) throws {
        try db.run("INSERT INTO events(doc_id, at, action, detail) VALUES(?,?,?,?)",
                   [.int(docID), .double(Date().timeIntervalSince1970),
                    .text("edited"), .text(detail)])
    }

    func processingQueue(limit: Int = 200) throws -> [ProcessingEntry] {
        try db.map("""
            SELECT p.id, p.doc_id, e.at, e.action, e.detail, e.confidence, e.rule,
                   e.from_path, e.to_path, p.status, d.filename, d.missing
            FROM processing p
            JOIN events e ON e.id = p.event_id
            JOIN documents d ON d.id = p.doc_id
            ORDER BY e.at DESC LIMIT ?
            """, [.int(limit)]) {
            ProcessingEntry(id: $0.int(0), docID: $0.int(1),
                            at: Date(timeIntervalSince1970: $0.double(2)), action: $0.string(3),
                            detail: $0.stringOrNil(4), confidence: $0.doubleOrNil(5),
                            rule: $0.stringOrNil(6), fromPath: $0.stringOrNil(7),
                            toPath: $0.stringOrNil(8), approved: $0.bool(9),
                            filename: $0.string(10), missing: $0.bool(11))
        }
    }

    /// Everything that has happened to one document, newest first. Unlike the
    /// queue this is complete: nothing trims it, so an import from a year and
    /// fifty thousand documents ago is still here.
    func history(for docID: Int64, limit: Int = 200) throws -> [HistoryEvent] {
        try db.map("""
            SELECT id, at, action, detail, confidence, rule, from_path, to_path
            FROM events WHERE doc_id=? ORDER BY at DESC, id DESC LIMIT ?
            """, [.int(docID), .int(limit)]) {
            HistoryEvent(id: $0.int(0), at: Date(timeIntervalSince1970: $0.double(1)),
                         action: $0.string(2), detail: $0.stringOrNil(3),
                         confidence: $0.doubleOrNil(4), rule: $0.stringOrNil(5),
                         fromPath: $0.stringOrNil(6).map { absPath($0) },
                         toPath: $0.stringOrNil(7).map { absPath($0) })
        }
    }

    // MARK: - Notes

    /// A document's notes, newest first. This is the escape hatch for what the
    /// schema does not model — "cancelled by phone on the 4th", "the original
    /// is in the red folder" — and it is indexed, so it is findable.
    func notes(for docID: Int64) throws -> [Note] {
        try db.map("""
            SELECT id, body, created_at, updated_at FROM notes
            WHERE doc_id=? ORDER BY created_at DESC, id DESC
            """, [.int(docID)]) {
            Note(id: $0.int(0), body: $0.string(1),
                 createdAt: Date(timeIntervalSince1970: $0.double(2)),
                 updatedAt: $0.date(3))
        }
    }

    @discardableResult
    func addNote(_ body: String, to docID: Int64) throws -> Int64 {
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return 0 }
        let id = try db.run("INSERT INTO notes(doc_id, body, created_at) VALUES(?,?,?)",
                            [.int(docID), .text(clean), .double(Date().timeIntervalSince1970)])
        try refreshSearchIndex(docID)
        return id
    }

    /// Editing a note to nothing deletes it — an empty note is not a note.
    func updateNote(_ id: Int64, body: String) throws {
        guard let docID = try db.first("SELECT doc_id FROM notes WHERE id=?", [.int(id)],
                                       { $0.int(0) }) else { return }
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            try db.run("DELETE FROM notes WHERE id=?", [.int(id)])
        } else {
            try db.run("UPDATE notes SET body=?, updated_at=? WHERE id=?",
                       [.text(clean), .double(Date().timeIntervalSince1970), .int(id)])
        }
        try refreshSearchIndex(docID)
    }

    func deleteNote(_ id: Int64) throws {
        guard let docID = try db.first("SELECT doc_id FROM notes WHERE id=?", [.int(id)],
                                       { $0.int(0) }) else { return }
        try db.run("DELETE FROM notes WHERE id=?", [.int(id)])
        try refreshSearchIndex(docID)
    }

    /// How many events the library has recorded in total — the number the
    /// capped queue used to throw away.
    func eventCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM events") { Int($0.int(0)) } ?? 0
    }

    // MARK: - Classifier Training Data

    struct ClassifierTrainingData: Sendable {
        var docs: [DocumentClassifier.TrainingDoc]
        var fingerprint: String
    }

    /// The training set's fingerprint on its own, without loading a line of
    /// document text. Indexing asks once per document, where the corpus only
    /// changes when a document is approved or edited.
    func classifierTrainingFingerprint() throws -> String {
        let row = try db.first("""
            SELECT COUNT(*), COALESCE(MAX(mtime), 0)
            FROM documents
            WHERE missing=0 AND deleted_at IS NULL AND approved=1
            """) { (count: Int($0.int(0)), maxMtime: $0.double(1)) }
        return "\(row?.count ?? 0)-\(row?.maxMtime ?? 0)"
    }

    func classifierTrainingData() throws -> ClassifierTrainingData {
        let docs = try db.map("""
            SELECT d.id, ec.name, et.name,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id),
                   d.mtime
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL AND d.approved=1
            """) {
            (id: $0.int(0), correspondent: $0.stringOrNil(1), docType: $0.stringOrNil(2),
             text: $0.stringOrNil(3) ?? "", mtime: $0.double(4))
        }

        let docIDs = docs.map(\.id)
        let tagMap = (try? tags(forDocuments: docIDs).own) ?? [:]

        var trainingDocs: [DocumentClassifier.TrainingDoc] = []
        var maxMtime: Double = 0
        for doc in docs {
            let tNames = (tagMap[doc.id] ?? []).map(\.name)
            trainingDocs.append(DocumentClassifier.TrainingDoc(
                id: doc.id, text: doc.text,
                correspondent: doc.correspondent, docType: doc.docType,
                tags: tNames
            ))
            if doc.mtime > maxMtime { maxMtime = doc.mtime }
        }

        let fingerprint = "\(trainingDocs.count)-\(maxMtime)"
        return ClassifierTrainingData(docs: trainingDocs, fingerprint: fingerprint)
    }

    // MARK: - Optimization Originals

    var originalsDirectory: URL {
        containerURL.appendingPathComponent("originals", isDirectory: true)
    }

    func originalFileURL(for docID: Int64) throws -> URL? {
        guard let (path, originalHash) = try db.first(
            "SELECT path, original_hash FROM documents WHERE id=? AND original_size IS NOT NULL AND original_hash IS NOT NULL",
            [.int(docID)], { ($0.string(0), $0.string(1)) }) else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension
        let file = originalsDirectory.appendingPathComponent("\(originalHash).\(ext)")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// - Returns: whether this call is the one that wrote the copy. Originals
    ///   are content-addressed and therefore shared, so an already-present copy
    ///   belongs to an earlier optimization and is not the caller's to remove.
    @discardableResult
    func saveOriginalFile(for docID: Int64, from sourceURL: URL, hash: String) throws -> Bool {
        let fm = FileManager.default
        let dir = originalsDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("\(hash).\(sourceURL.pathExtension)")
        guard !fm.fileExists(atPath: target.path) else { return false }
        try fm.copyItem(at: sourceURL, to: target)
        return true
    }

    /// Drops a pre-optimization copy whose optimization never happened. Nothing
    /// records it in that case — `original_size` stays NULL — so left alone it
    /// would sit in `originals/` for the life of the library.
    func discardOriginalFile(hash: String, ext: String) {
        try? FileManager.default.removeItem(at: originalsDirectory.appendingPathComponent("\(hash).\(ext)"))
    }

    /// Frees a document's saved pre-optimization copy for good — the fallback
    /// `Revert to Original` offers, not the optimized file already in place,
    /// which is untouched. `original_size` is kept so the savings the
    /// optimization made stay on record; only `original_hash` is cleared,
    /// which is what `originalFileURL` and `revertOptimization` key off.
    func deleteOriginalFile(for docID: Int64) throws {
        guard let (path, originalHash) = try db.first("""
            SELECT path, original_hash FROM documents
            WHERE id=? AND original_size IS NOT NULL AND original_hash IS NOT NULL
            """, [.int(docID)], { ($0.string(0), $0.string(1)) }) else { return }
        try db.run("UPDATE documents SET original_hash=NULL WHERE id=?", [.int(docID)])
        // Originals are content-addressed and can be shared by more than one
        // document, so the file itself only goes once nothing else wants it.
        guard try db.first("SELECT 1 FROM documents WHERE original_hash=? LIMIT 1",
                           [.text(originalHash)], { _ in true }) == nil else { return }
        let ext = URL(fileURLWithPath: path).pathExtension
        try? FileManager.default.removeItem(at: originalsDirectory.appendingPathComponent("\(originalHash).\(ext)"))
    }

    func revertOptimization(_ docID: Int64) throws -> Bool {
        guard let (relPath, originalSize, originalHash) = try db.first("""
            SELECT path, original_size, original_hash
            FROM documents
            WHERE id=? AND original_size IS NOT NULL AND original_hash IS NOT NULL
            """, [.int(docID)], { ($0.string(0), $0.int(1), $0.string(2)) }) else { return false }

        let currentURL = URL(fileURLWithPath: absPath(relPath))
        let ext = currentURL.pathExtension
        let originalURL = originalsDirectory.appendingPathComponent("\(originalHash).\(ext)")
        guard FileManager.default.fileExists(atPath: originalURL.path) else { return false }

        let fm = FileManager.default
        // Stage the restore beside the live file and swap it in, so a failing
        // copy can never leave the row pointing at a file that no longer exists.
        let staged = currentURL.deletingLastPathComponent()
            .appendingPathComponent(".doctopus-revert-\(UUID().uuidString).\(ext)")
        try fm.copyItem(at: originalURL, to: staged)
        do {
            if fm.fileExists(atPath: currentURL.path) {
                _ = try fm.replaceItemAt(currentURL, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: currentURL)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }

        try db.run("""
            UPDATE documents SET size=?, original_size=NULL, hash=original_hash
            WHERE id=?
            """, [.int(originalSize), .int(docID)])
        try logProcessing(docID: docID, action: "reverted_optimization",
                          detail: "Reverted to original pre-optimization file",
                          confidence: nil, rule: nil, from: nil, to: currentURL.path, approved: true)
        return true
    }

    // MARK: - Verification queries

    struct VerificationDocInfo: Sendable {
        var id: Int64
        var path: String
        var filename: String
        var hash: String?
        var ocrState: OCRState
    }

    func verificationDocumentInfos() throws -> [VerificationDocInfo] {
        try db.map("""
            SELECT id, path, filename, hash, ocr_state
            FROM documents WHERE deleted_at IS NULL
            """) {
            VerificationDocInfo(id: $0.int(0), path: absPath($0.string(1)), filename: $0.string(2),
                                hash: $0.stringOrNil(3),
                                ocrState: OCRState(rawValue: $0.int(4)) ?? .pending)
        }
    }

    func allAliasRecords() throws -> [(id: Int64, docID: Int64, path: String)] {
        try db.map("SELECT id, doc_id, path FROM aliases") { ($0.int(0), $0.int(1), absPath($0.string(2))) }
    }

    func orphanedSuggestionsCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM tag_suggestions WHERE doc_id NOT IN (SELECT id FROM documents)") {
            Int($0.int(0))
        } ?? 0
    }

    func orphanedIconsCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM value_icons WHERE field_id NOT IN (SELECT id FROM fields)") {
            Int($0.int(0))
        } ?? 0
    }

    func orphanedFTSCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM doc_fts WHERE rowid NOT IN (SELECT id FROM documents)") {
            Int($0.int(0))
        } ?? 0
    }

    // MARK: - Undo

    /// Reverts the most recent undoable file event (such as a move, rename, or routing).
    ///
    /// Two of these are about aliases rather than about the file, and both
    /// carry the alias's own path as `to_path`:
    ///
    /// An `unfiled` event is a deleted alias. Nothing was moved, so nothing
    /// moves back — the alias is simply written again, pointing at wherever
    /// the document is now.
    ///
    /// A `promoted` event is a document that took the place of one of its own
    /// aliases when it was deleted. It is put back whole: the document returns
    /// to the folder it was deleted from *and* the alias it replaced is written
    /// again, because undoing a delete that quietly unfiled the document from
    /// somewhere else would be a worse surprise than the delete was.
    func undoLastEvent() async throws -> (action: String, filename: String)? {
        let fm = FileManager.default
        // Skips (and discards) events whose target file has since moved
        // outside Doctopus, so one stale event can't permanently block undo
        // of everything older than it.
        while true {
            guard let last = try db.first("""
                SELECT id, doc_id, action, from_path, to_path, detail
                FROM events
                WHERE action IN ('moved', 'renamed', 'routed', 'promoted', 'unfiled')
                  AND from_path IS NOT NULL AND to_path IS NOT NULL
                ORDER BY at DESC, id DESC LIMIT 1
                """, [], { (id: $0.int(0), docID: $0.int(1), action: $0.string(2),
                            from: absPath($0.string(3)), to: absPath($0.string(4)), detail: $0.stringOrNil(5)) }) else {
                return nil
            }

            // A deleted alias left nothing at `to` to put back, so this one is
            // undone by writing the alias again rather than by moving a file.
            // It is skipped, like any other stale event, when the document it
            // pointed at is itself gone.
            if last.action == "unfiled" {
                try db.run("DELETE FROM events WHERE id=?", [.int(last.id)])
                guard let current = try documentPath(last.docID),
                      fm.fileExists(atPath: current),
                      let alias = try? AliasManager.createAlias(
                          to: URL(fileURLWithPath: current),
                          in: URL(fileURLWithPath: last.to).deletingLastPathComponent())
                else { continue }
                try recordAlias(docID: last.docID, tagID: nil, path: alias.path)
                return (last.action, URL(fileURLWithPath: current).lastPathComponent)
            }

            guard fm.fileExists(atPath: last.to) else {
                try db.run("DELETE FROM events WHERE id=?", [.int(last.id)])
                continue
            }

            let targetDir = URL(fileURLWithPath: last.from).deletingLastPathComponent()
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let targetURL = Naming.uniqueURL(in: targetDir, filename: URL(fileURLWithPath: last.from).lastPathComponent)

            try fm.moveItem(at: URL(fileURLWithPath: last.to), to: targetURL)
            try updatePath(last.docID, to: targetURL.path)

            // Before pruning: an alias put back here is exactly what keeps the
            // folder from being read as empty and swept away.
            if last.action == "promoted",
               let alias = try? AliasManager.createAlias(
                   to: targetURL,
                   in: URL(fileURLWithPath: last.to).deletingLastPathComponent()) {
                try recordAlias(docID: last.docID, tagID: nil, path: alias.path)
            }

            FileScanner.pruneEmptyDirectories(startingFrom: URL(fileURLWithPath: last.to).deletingLastPathComponent(), upTo: root)

            try db.run("DELETE FROM events WHERE id=?", [.int(last.id)])

            let filename = targetURL.lastPathComponent
            return (last.action, filename)
        }
    }

    // MARK: - Saved Views

    func savedViews() throws -> [SavedView] {
        try db.map("""
            SELECT id, name, icon, query, sort_key, ascending, view_mode, position
            FROM saved_views ORDER BY position, id
            """) {
            SavedView(id: $0.int(0), name: $0.string(1),
                      icon: $0.stringOrNil(2) ?? "line.3.horizontal.decrease.circle",
                      query: $0.string(3), sortKey: $0.stringOrNil(4),
                      ascending: $0.bool(5), viewMode: $0.stringOrNil(6),
                      position: $0.int(7))
        }
    }

    @discardableResult
    func upsertSavedView(_ sv: SavedView) throws -> Int64 {
        if sv.id > 0 {
            try db.run("""
                UPDATE saved_views SET name=?, icon=?, query=?, sort_key=?, ascending=?,
                                       view_mode=?, position=?
                WHERE id=?
                """, [.text(sv.name), .text(sv.icon), .text(sv.query), .text(sv.sortKey),
                      .bool(sv.ascending), .text(sv.viewMode), .int(sv.position), .int(sv.id)])
            return sv.id
        }
        return try db.run("""
            INSERT INTO saved_views(name, icon, query, sort_key, ascending, view_mode, position)
            VALUES(?,?,?,?,?,?,?)
            """, [.text(sv.name), .text(sv.icon), .text(sv.query), .text(sv.sortKey),
                  .bool(sv.ascending), .text(sv.viewMode), .int(sv.position)])
    }

    func deleteSavedView(_ id: Int64) throws {
        try db.run("DELETE FROM saved_views WHERE id=?", [.int(id)])
    }

    // MARK: - Rules

    func rules() throws -> [Rule] {
        try db.map("""
            SELECT id, name, pattern, field, destination, tag_names, weight, enabled, priority,
                   match_mode, match_insensitive, set_correspondent, set_doc_type
            FROM rules ORDER BY priority DESC, id
            """) {
            Rule(id: $0.int(0), name: $0.string(1), pattern: $0.string(2), field: $0.string(3),
                 destination: $0.string(4), tagNames: $0.stringOrNil(5), weight: $0.double(6),
                 enabled: $0.bool(7), priority: $0.int(8),
                 mode: MatchMode(rawValue: $0.int(9)) ?? .anyWord,
                 caseInsensitive: $0.bool(10),
                 setCorrespondent: $0.stringOrNil(11),
                 setDocType: $0.stringOrNil(12))
        }
    }

    @discardableResult
    func upsertRule(_ r: Rule) throws -> Int64 {
        if r.id > 0 {
            try db.run("""
                UPDATE rules SET name=?, pattern=?, field=?, destination=?, tag_names=?,
                                 weight=?, enabled=?, priority=?, match_mode=?, match_insensitive=?,
                                 set_correspondent=?, set_doc_type=?
                WHERE id=?
                """, [.text(r.name), .text(r.pattern), .text(r.field), .text(r.destination),
                      .text(r.tagNames), .double(r.weight), .bool(r.enabled), .int(r.priority),
                      .int(r.mode.rawValue), .bool(r.caseInsensitive),
                      .text(r.setCorrespondent), .text(r.setDocType), .int(r.id)])
            return r.id
        }
        return try db.run("""
            INSERT INTO rules(name, pattern, field, destination, tag_names, weight, enabled, priority,
                              match_mode, match_insensitive, set_correspondent, set_doc_type)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(r.name), .text(r.pattern), .text(r.field), .text(r.destination),
                  .text(r.tagNames), .double(r.weight), .bool(r.enabled), .int(r.priority),
                  .int(r.mode.rawValue), .bool(r.caseInsensitive),
                  .text(r.setCorrespondent), .text(r.setDocType)])
    }

    func deleteRule(_ id: Int64) throws {
        try db.run("DELETE FROM rules WHERE id=?", [.int(id)])
    }

    /// Rewrites priorities so the rules run in exactly the order given, first
    /// to last. Spaced by ten, like field positions.
    func reorderRules(_ ids: [Int64]) throws {
        try db.transaction {
            for (index, id) in ids.enumerated() {
                try db.run("UPDATE rules SET priority=? WHERE id=?",
                           [.int(Int64((ids.count - index) * 10)), .int(id)])
            }
        }
    }

    /// What a rule sees of one document, for trying a pattern out before it is
    /// saved. Filename and extracted metadata as well as text, since a rule can
    /// be pointed at any of them.
    struct RuleSample: Sendable {
        var filename: String
        var text: String
        var correspondent: String?
        var docType: String?
    }

    struct RuleApplyResult: Sendable {
        var matched: Int = 0
        var moved: Int = 0
        var tagged: Int = 0
        var metadataUpdated: Int = 0
    }

    /// Applies a rule to all matching documents currently in the library.
    func applyRuleToExisting(ruleID: Int64) async throws -> RuleApplyResult {
        let allRules = try rules()
        guard let rule = allRules.first(where: { $0.id == ruleID }) else { return RuleApplyResult() }
        return try await applyRuleToExisting(rule)
    }

    /// The same, for a rule that has not been saved yet — the rule editor
    /// applies the draft in front of the user, and Cancel still has to leave
    /// the rule list untouched.
    func applyRuleToExisting(_ rule: Rule) async throws -> RuleApplyResult {
        let docs = try db.map("""
            SELECT d.id, d.path, d.filename, d.created_at, m.doc_date, ec.name, et.name,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id)
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL
            """) {
            (id: $0.int(0), path: absPath($0.string(1)), filename: $0.string(2),
             created: Date(timeIntervalSince1970: $0.double(3)),
             docDate: $0.date(4), correspondent: $0.stringOrNil(5),
             docType: $0.stringOrNil(6), text: $0.stringOrNil(7) ?? "")
        }

        var result = RuleApplyResult()
        let router = Router(rules: [rule], threshold: 0.0, derivedTemplate: "", root: root, deriveWhenNoRule: false)

        for doc in docs {
            let subject = Router.subject(for: rule.field, text: doc.text, filename: doc.filename,
                                         correspondent: doc.correspondent, docType: doc.docType)
            guard Router.matches(rule, in: subject) else { continue }
            result.matched += 1

            // Documents already processed above must count even if a later
            // one fails, so one bad row can't discard the whole batch's
            // progress — the caller only ever sees `try?`'s empty fallback.
            do {
                // 1. Assign tags
                if let tagNames = rule.tagNames {
                    let tags = tagNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    for tag in tags {
                        let tid = try tagID(named: tag)
                        try assign(tag: tid, to: doc.id, auto: true)
                    }
                    if !tags.isEmpty { result.tagged += 1 }
                }

                // 2. Assign metadata
                var patch = Store.MetadataPatch(docID: doc.id)
                var updatedMeta = false
                if let corr = rule.setCorrespondent, !corr.isEmpty {
                    patch.correspondent = corr
                    updatedMeta = true
                }
                if let dtype = rule.setDocType, !dtype.isEmpty {
                    patch.docType = dtype
                    updatedMeta = true
                }
                if updatedMeta {
                    try storeMetadata(patch)
                    result.metadataUpdated += 1
                }

                // 3. Move if destination template specified
                let destStr = rule.destination.trimmingCharacters(in: .whitespaces)
                if !destStr.isEmpty {
                    let destURL = router.expand(destStr, correspondent: patch.correspondent ?? doc.correspondent,
                                                docType: patch.docType ?? doc.docType, date: doc.docDate ?? doc.created)
                    if router.isInsideLibrary(destURL) {
                        let currentDir = URL(fileURLWithPath: doc.path).deletingLastPathComponent()
                        if currentDir.standardizedFileURL != destURL.standardizedFileURL {
                            try? FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
                            let target = Naming.uniqueURL(in: destURL, filename: doc.filename)
                            if (try? FileManager.default.moveItem(at: URL(fileURLWithPath: doc.path), to: target)) != nil {
                                try updatePath(doc.id, to: target.path)
                                FileScanner.pruneEmptyDirectories(startingFrom: currentDir, upTo: root)
                                try logProcessing(docID: doc.id, action: "routed", detail: "Applied rule “\(rule.name)”",
                                                  confidence: rule.weight, rule: rule.name,
                                                  from: doc.path, to: target.path, approved: true)
                                result.moved += 1
                            }
                        }
                    }
                }
            } catch {
                continue
            }
        }
        return result
    }

    /// The most recent documents, as rule samples. `doc_fts` is keyed by
    /// `rowid`, so each document's text is one indexed lookup — the corpus no
    /// longer has to be loaded into memory to avoid a scan per row.
    func ruleSamples(limit: Int = 5000) throws -> [RuleSample] {
        try db.map("""
            SELECT d.filename, ec.name, et.name,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id)
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL ORDER BY d.created_at DESC LIMIT ?
            """, [.int(Int64(limit))]) {
            RuleSample(filename: $0.string(0), text: $0.stringOrNil(3) ?? "",
                       correspondent: $0.stringOrNil(1), docType: $0.stringOrNil(2))
        }
    }

    // MARK: - Moves & renames

    /// `newPath` is absolute.
    func updatePath(_ docID: Int64, to newPath: String) throws {
        let url = URL(fileURLWithPath: newPath)
        try db.run("""
            UPDATE documents SET path=?, directory=?, filename=?, ext=?, missing=0, missing_since=NULL WHERE id=?
            """, [.text(relPath(newPath)), .text(relPath(url.deletingLastPathComponent().path)),
                  .text(url.lastPathComponent), .text(url.pathExtension.lowercased()), .int(docID)])
        try refreshSearchIndex(docID)
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
