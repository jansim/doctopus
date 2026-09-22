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

    static func directories(root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var out: [URL] = []
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if url.lastPathComponent.hasSuffix(".doctopus") { e.skipDescendants(); continue }
            out.append(url)
        }
        return out
    }

    static func importable(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true {
                guard v?.isPackage != true, !url.lastPathComponent.hasSuffix(".doctopus") else { continue }
                out += scan(root: url).map(\.url)
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    static func hash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Prunes empty directories climbing up from `dir` towards (and stopping
    /// before) `root`. A directory counts as empty only when it holds nothing
    /// but a `.DS_Store`, so the library root, nested `.doctopus` libraries and
    /// any other hidden file are all left where they are.
    static func pruneEmptyDirectories(startingFrom dir: URL, upTo root: URL) {
        let fm = FileManager.default
        let rootStandardized = root.standardizedFileURL.path
        var current = dir.standardizedFileURL
        while current.path != rootStandardized && current.path.hasPrefix(rootStandardized + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path) else { break }
            // .DS_Store is the only disposable entry. Everything else counts as
            // content — including dot-files like .git and nested .doctopus
            // libraries — because the removeItem below is recursive.
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { break }
            let dsStore = current.appendingPathComponent(".DS_Store")
            if fm.fileExists(atPath: dsStore.path) { try? fm.removeItem(at: dsStore) }
            // Re-check rather than trust the filter: only ever remove a
            // directory that is genuinely empty right now, so a failed
            // .DS_Store removal cannot escalate into a recursive delete.
            guard let remaining = try? fm.contentsOfDirectory(atPath: current.path),
                  remaining.isEmpty else { break }
            do {
                try fm.removeItem(at: current)
                current = current.deletingLastPathComponent()
            } catch {
                break
            }
        }
    }
}
