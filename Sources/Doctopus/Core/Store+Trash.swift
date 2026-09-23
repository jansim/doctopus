import Foundation

extension Store {

    static let missingGrace: TimeInterval = 30 * 24 * 3600

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

    func softDelete(_ docID: Int64, trashPath: String?) throws {
        let now = Date().timeIntervalSince1970
        try db.run("""
            UPDATE documents SET deleted_at=?, deleted_path=?, missing=1,
                                 missing_since=COALESCE(missing_since, ?)
            WHERE id=?
            """, [.double(now), .text(trashPath), .double(now), .int(docID)])
    }

    func trashedFile(_ docID: Int64) throws -> String? {
        guard let path = try db.first("SELECT deleted_path FROM documents WHERE id=?",
                                      [.int(docID)], { $0.stringOrNil(0) }) ?? nil
        else { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func restore(_ docID: Int64, at path: String? = nil) throws {
        if let path {
            try updatePath(docID, to: path)
        }
        try db.run("""
            UPDATE documents SET deleted_at=NULL, deleted_path=NULL, missing=0, missing_since=NULL
            WHERE id=?
            """, [.int(docID)])
    }

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
}
