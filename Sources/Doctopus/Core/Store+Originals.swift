import Foundation

extension Store {

    var originalsDirectory: URL {
        containerURL.appendingPathComponent("originals", isDirectory: true)
    }

    /// The saved original a document can be put back to, where it goes, and its size.
    func savedOriginal(_ docID: Int64) throws -> (file: URL, current: URL, size: Int64)? {
        guard let (path, size, hash) = try db.first("""
            SELECT path, original_size, original_hash FROM documents
            WHERE id=? AND original_size IS NOT NULL AND original_hash IS NOT NULL
            """, [.int(docID)], { ($0.string(0), $0.int(1), $0.string(2)) }) else { return nil }
        let current = URL(fileURLWithPath: absPath(path))
        let file = originalsDirectory.appendingPathComponent("\(hash).\(current.pathExtension)")
        return FileManager.default.fileExists(atPath: file.path) ? (file, current, size) : nil
    }

    func originalFileURL(for docID: Int64) throws -> URL? {
        try savedOriginal(docID)?.file
    }

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

    func discardOriginalFile(hash: String, ext: String) {
        try? FileManager.default.removeItem(at: originalsDirectory.appendingPathComponent("\(hash).\(ext)"))
    }

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

    func markReverted(_ docID: Int64, size: Int64) throws {
        try db.run("UPDATE documents SET size=?, original_size=NULL, hash=original_hash WHERE id=?",
                   [.int(size), .int(docID)])
    }
}
