import Foundation
import CryptoKit

/// Walks a root directory in place. Nothing is moved, renamed or written.
enum FileScanner {
    static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg"]

    struct Found: Sendable {
        var url: URL
        var size: Int64
        var mtime: Date
        var created: Date
    }

    /// A `library.doctopus` directory (or any `*.doctopus`) is Doctopus's own
    /// storage, not content: never index or react to anything inside one.
    static func isInsideLibraryContainer(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasSuffix(".doctopus") }
    }

    static func scan(root: URL) -> [Found] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isAliasFileKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        ]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var out: [Found] = []
        out.reserveCapacity(512)
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if url.lastPathComponent.hasSuffix(".doctopus") { e.skipDescendants() }
                continue
            }
            if isInsideLibraryContainer(url) { continue }
            // Aliases we (or the user) generated are pointers, not documents.
            if v.isAliasFile == true { continue }
            guard v.isRegularFile == true,
                  supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            out.append(Found(url: url,
                             size: Int64(v.fileSize ?? 0),
                             mtime: v.contentModificationDate ?? .distantPast,
                             created: v.creationDate ?? v.contentModificationDate ?? Date()))
        }
        return out
    }

    /// Streaming SHA-256 so a 500 MB PDF never lands in memory.
    static func hash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
