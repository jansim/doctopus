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

    private struct Meta: Codable { var id: String; var formatVersion: Int; var name: String? }

    private static func loadOrCreateMeta(in container: URL) throws -> LibraryID {
        let metaURL = container.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(Meta.self, from: data),
           !meta.id.isEmpty {
            return meta.id
        }
        let meta = Meta(id: UUID().uuidString, formatVersion: 1,
                        name: container.deletingLastPathComponent().lastPathComponent)
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
            "SELECT id, size, mtime, ocr_state FROM documents WHERE path=?", [.text(relative)]
        ) { ($0.int(0), $0.int(1), $0.double(2), $0.int(3)) }

        if let (id, size, mtime, state) = existing {
            let changed = size != f.size || abs(mtime - f.mtime.timeIntervalSince1970) > 1
            try db.run("""
                UPDATE documents SET size=?, mtime=?, missing=0, missing_since=NULL,
                                     directory=?, filename=?, ext=?
                WHERE id=?
                """, [.int(f.size), .double(f.mtime.timeIntervalSince1970),
                      .text(dir), .text(name), .text(ext), .int(id)])
            if changed { try db.run("UPDATE documents SET hash=NULL, ocr_state=0 WHERE id=?", [.int(id)]) }
            return (id, false, changed || state == OCRState.pending.rawValue)
        }

        let id = try db.run("""
            INSERT INTO documents(path, directory, filename, ext, size, mtime, created_at, ocr_state)
            VALUES(?,?,?,?,?,?,?,0)
            """, [.text(relative), .text(dir), .text(name), .text(ext),
                  .int(f.size), .double(f.mtime.timeIntervalSince1970),
                  .double(f.created.timeIntervalSince1970)])
        return (id, true, true)
    }

    /// Disk is the source of truth: a vanished path that reappears elsewhere with
    /// the same content is a move, not a deletion. `seenPaths` are absolute.
    func reconcileMissing(seenPaths: Set<String>) throws -> Int {
        let seenRelative = Set(seenPaths.map { relPath($0) })
        var stale: [Int64] = []
        try db.query("SELECT id, path FROM documents WHERE missing=0") { row in
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
            "SELECT id FROM documents WHERE hash=? AND missing=1 LIMIT 1", [.text(hash)],
            { $0.int(0) })
        guard let id = match else { return nil }
        let url = URL(fileURLWithPath: newPath)
        try db.run("""
            UPDATE documents SET path=?, directory=?, filename=?, missing=0, missing_since=NULL
            WHERE id=?
            """, [.text(relPath(newPath)), .text(relPath(url.deletingLastPathComponent().path)),
                  .text(url.lastPathComponent), .int(id)])
        return id
    }

    /// `path` is absolute.
    func markMissing(path: String) throws {
        try db.run("UPDATE documents SET missing=1, missing_since=COALESCE(missing_since,?) WHERE path=?",
                   [.double(Date().timeIntervalSince1970), .text(relPath(path))])
    }

    /// Missing rows are kept for a while on purpose: they are what lets a file
    /// moved in Finder be relinked by content hash with its tags and metadata
    /// intact. Past the grace period they are just dead weight.
    @discardableResult
    func purgeMissing(olderThan seconds: TimeInterval) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - seconds
        let doomed = try db.map(
            "SELECT id FROM documents WHERE missing=1 AND COALESCE(missing_since, 0) < ?",
            [.double(cutoff)]) { $0.int(0) }
        for id in doomed { try deleteDocument(id) }
        return doomed.count
    }

    func setHash(_ id: Int64, _ hash: String) throws {
        try db.run("UPDATE documents SET hash=? WHERE id=?", [.text(hash), .int(id)])
    }

    func documentIDsNeedingOCR(limit: Int = 5000) throws -> [(id: Int64, path: String, ext: String)] {
        try db.map("""
            SELECT id, path, ext FROM documents
            WHERE ocr_state=0 AND missing=0 ORDER BY created_at DESC LIMIT ?
            """, [.int(limit)]) { ($0.int(0), absPath($0.string(1)), $0.string(2)) }
    }

    /// Every document still present on disk, newest first. The input for a
    /// library-wide manual pass, which wants ids rather than whole rows.
    func allDocumentIDs(limit: Int = 20000) throws -> [Int64] {
        try db.map("SELECT id FROM documents WHERE missing=0 ORDER BY created_at DESC LIMIT ?",
                   [.int(limit)]) { $0.int(0) }
    }

    /// Absolute path of a document.
    func documentPath(_ id: Int64) throws -> String? {
        try db.first("SELECT path FROM documents WHERE id=?", [.int(id)]) { absPath($0.string(0)) }
    }

    // MARK: - OCR

    func storeOCR(docID: Int64, text: String, confidence: Double, words: Int,
                  source: String, elapsedMS: Int, pageCount: Int?) throws {
        try db.transaction {
            try db.run("DELETE FROM ocr_content WHERE doc_id=?", [.int(docID)])
            if !text.isEmpty {
                try db.run("INSERT INTO ocr_content(text, doc_id) VALUES(?,?)",
                           [.text(text), .int(docID)])
            }
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

    func ocrText(_ id: Int64) throws -> String {
        try db.first("SELECT text FROM ocr_content WHERE doc_id=?", [.int(id)]) { $0.string(0) } ?? ""
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

    func storeMetadata(_ p: MetadataPatch) throws {
        try db.run("""
            INSERT INTO metadata(doc_id, title, correspondent, doc_type, language, summary,
                                 intent, doc_date, date_source, confidence, source, amount)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(doc_id) DO UPDATE SET
                title=COALESCE(excluded.title, metadata.title),
                correspondent=COALESCE(excluded.correspondent, metadata.correspondent),
                doc_type=COALESCE(excluded.doc_type, metadata.doc_type),
                language=COALESCE(excluded.language, metadata.language),
                summary=COALESCE(excluded.summary, metadata.summary),
                intent=COALESCE(excluded.intent, metadata.intent),
                doc_date=COALESCE(excluded.doc_date, metadata.doc_date),
                date_source=COALESCE(excluded.date_source, metadata.date_source),
                confidence=COALESCE(excluded.confidence, metadata.confidence),
                source=COALESCE(excluded.source, metadata.source),
                amount=COALESCE(excluded.amount, metadata.amount)
            """, [.int(p.docID), .text(p.title), .text(p.correspondent), .text(p.docType),
                  .text(p.language), .text(p.summary), .text(p.intent), .date(p.docDate),
                  .text(p.dateSource), .double(p.confidence), .text(p.source), .text(p.amount)])
    }

    /// User edits overwrite unconditionally (including clearing a field).
    func overwriteMetadataField(_ docID: Int64, column: String, value: String?) throws {
        let allowed = ["title", "correspondent", "doc_type", "language", "summary", "intent", "amount"]
        guard allowed.contains(column) else { return }
        try db.run("INSERT OR IGNORE INTO metadata(doc_id) VALUES(?)", [.int(docID)])
        try db.run("UPDATE metadata SET \(column)=? WHERE doc_id=?", [.text(value), .int(docID)])
    }

    func setDocumentDate(_ docID: Int64, _ date: Date?) throws {
        try db.run("INSERT OR IGNORE INTO metadata(doc_id) VALUES(?)", [.int(docID)])
        try db.run("UPDATE metadata SET doc_date=?, date_source='manual' WHERE doc_id=?",
                   [.date(date), .int(docID)])
    }

    // MARK: - Tags

    func tags() throws -> [Tag] {
        try db.map("""
            SELECT t.id, t.name, t.color, t.mirrors, t.folder, COUNT(dt.doc_id)
            FROM tags t
            LEFT JOIN document_tags dt ON dt.tag_id = t.id
            LEFT JOIN documents d ON d.id = dt.doc_id AND d.missing=0
            GROUP BY t.id ORDER BY t.name COLLATE NOCASE
            """) {
            Tag(tagID: $0.int(0), name: $0.string(1), color: $0.int(2),
                mirrors: $0.bool(3), folder: $0.stringOrNil(4), count: Int($0.int(5)))
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

    func assign(tag tagID: Int64, to docID: Int64, auto: Bool = false) throws {
        guard tagID > 0 else { return }
        try db.run("INSERT OR IGNORE INTO document_tags(doc_id, tag_id, auto) VALUES(?,?,?)",
                   [.int(docID), .int(tagID), .bool(auto)])
    }

    func unassign(tag tagID: Int64, from docID: Int64) throws {
        try db.run("DELETE FROM document_tags WHERE doc_id=? AND tag_id=?", [.int(docID), .int(tagID)])
    }

    func deleteTag(_ id: Int64) throws {
        try db.run("DELETE FROM tags WHERE id=?", [.int(id)])
    }

    func setTagMirroring(_ id: Int64, _ on: Bool, folder: String?) throws {
        try db.run("UPDATE tags SET mirrors=?, folder=? WHERE id=?",
                   [.bool(on), .text(folder), .int(id)])
    }

    func tags(for docID: Int64) throws -> [Tag] {
        try db.map("""
            SELECT t.id, t.name, t.color, t.mirrors, t.folder FROM tags t
            JOIN document_tags dt ON dt.tag_id=t.id WHERE dt.doc_id=?
            ORDER BY t.name COLLATE NOCASE
            """, [.int(docID)]) {
            Tag(tagID: $0.int(0), name: $0.string(1), color: $0.int(2), mirrors: $0.bool(3), folder: $0.stringOrNil(4))
        }
    }

    /// Tags whose documents should be mirrored to disk as Finder aliases.
    func mirroringTags(for docID: Int64) throws -> [Tag] {
        try tags(for: docID).filter { $0.mirrors }
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

    func allAliasPaths() throws -> Set<String> {
        Set(try db.map("SELECT path FROM aliases") { absPath($0.string(0)) })
    }

    // MARK: - Processing queue

    func logProcessing(docID: Int64, action: String, detail: String?, confidence: Double?,
                       rule: String?, from: String?, to: String?, approved: Bool) throws {
        try db.run("""
            INSERT INTO processing(doc_id, at, action, detail, confidence, rule, from_path, to_path, status)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, [.int(docID), .double(Date().timeIntervalSince1970), .text(action), .text(detail),
                  .double(confidence), .text(rule), .text(from), .text(to), .bool(approved)])
        // Keep the queue bounded; it is a recency view, not an audit log.
        try db.run("DELETE FROM processing WHERE id NOT IN (SELECT id FROM processing ORDER BY at DESC LIMIT 500)")
    }

    func processingQueue(limit: Int = 200) throws -> [ProcessingEntry] {
        try db.map("""
            SELECT p.id, p.doc_id, p.at, p.action, p.detail, p.confidence, p.rule,
                   p.from_path, p.to_path, p.status, d.filename, d.missing
            FROM processing p JOIN documents d ON d.id=p.doc_id
            ORDER BY p.at DESC LIMIT ?
            """, [.int(limit)]) {
            ProcessingEntry(id: $0.int(0), docID: $0.int(1),
                            at: Date(timeIntervalSince1970: $0.double(2)), action: $0.string(3),
                            detail: $0.stringOrNil(4), confidence: $0.doubleOrNil(5),
                            rule: $0.stringOrNil(6), fromPath: $0.stringOrNil(7),
                            toPath: $0.stringOrNil(8), approved: $0.bool(9),
                            filename: $0.string(10), missing: $0.bool(11))
        }
    }

    func setProcessingApproved(_ id: Int64, _ approved: Bool) throws {
        try db.run("UPDATE processing SET status=? WHERE id=?", [.bool(approved), .int(id)])
        let owner = try db.first("SELECT doc_id FROM processing WHERE id=?", [.int(id)], { $0.int(0) })
        if let docID = owner {
            try db.run("UPDATE documents SET approved=? WHERE id=?", [.bool(approved), .int(docID)])
        }
    }

    func pendingReviewCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM processing WHERE status=0") { Int($0.int(0)) } ?? 0
    }

    // MARK: - Rules

    func rules() throws -> [Rule] {
        try db.map("""
            SELECT id, name, pattern, field, destination, tag_names, weight, enabled, priority
            FROM rules ORDER BY priority DESC, id
            """) {
            Rule(id: $0.int(0), name: $0.string(1), pattern: $0.string(2), field: $0.string(3),
                 destination: $0.string(4), tagNames: $0.stringOrNil(5), weight: $0.double(6),
                 enabled: $0.bool(7), priority: $0.int(8))
        }
    }

    @discardableResult
    func upsertRule(_ r: Rule) throws -> Int64 {
        if r.id > 0 {
            try db.run("""
                UPDATE rules SET name=?, pattern=?, field=?, destination=?, tag_names=?,
                                 weight=?, enabled=?, priority=? WHERE id=?
                """, [.text(r.name), .text(r.pattern), .text(r.field), .text(r.destination),
                      .text(r.tagNames), .double(r.weight), .bool(r.enabled), .int(r.priority), .int(r.id)])
            return r.id
        }
        return try db.run("""
            INSERT INTO rules(name, pattern, field, destination, tag_names, weight, enabled, priority)
            VALUES(?,?,?,?,?,?,?,?)
            """, [.text(r.name), .text(r.pattern), .text(r.field), .text(r.destination),
                  .text(r.tagNames), .double(r.weight), .bool(r.enabled), .int(r.priority)])
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

    /// The most recent documents, as rule samples. Text is read in one pass
    /// over the FTS table rather than joined per row: `doc_id` is unindexed
    /// there, so a join would scan it once for every document.
    func ruleSamples(limit: Int = 5000) throws -> [RuleSample] {
        var texts: [Int64: String] = [:]
        try db.query("SELECT doc_id, text FROM ocr_content") { texts[$0.int(0)] = $0.string(1) }
        return try db.map("""
            SELECT d.id, d.filename, m.correspondent, m.doc_type FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            WHERE d.missing=0 ORDER BY d.created_at DESC LIMIT ?
            """, [.int(Int64(limit))]) {
            RuleSample(filename: $0.string(1), text: texts[$0.int(0)] ?? "",
                       correspondent: $0.stringOrNil(2), docType: $0.stringOrNil(3))
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
    }

    func setSizes(_ docID: Int64, size: Int64, originalSize: Int64?) throws {
        try db.run("UPDATE documents SET size=?, original_size=COALESCE(?, original_size) WHERE id=?",
                   [.int(size), .int(originalSize), .int(docID)])
    }

    func deleteDocument(_ docID: Int64) throws {
        try db.run("DELETE FROM ocr_content WHERE doc_id=?", [.int(docID)])
        try db.run("DELETE FROM documents WHERE id=?", [.int(docID)])
    }
}
