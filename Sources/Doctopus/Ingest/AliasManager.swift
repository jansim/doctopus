import Foundation

enum AliasManager {

    static func tagFolder(root: URL, tag: Tag) -> URL {
        if let custom = tag.folder?.nilIfBlank {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return root.appendingPathComponent("Tags", isDirectory: true)
                   .appendingPathComponent(safe(tag.name), isDirectory: true)
    }

    @discardableResult
    static func createAlias(to target: URL, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = Naming.uniqueURL(in: folder, filename: target.lastPathComponent)
        let data = try (target as NSURL).bookmarkData(
            options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try NSURL.writeBookmarkData(data, to: dest, options: 0)
        return dest
    }

    /// Deletes an alias Doctopus made — and nothing else. Anything could be at that
    /// path now, so it is removed only if it is still an alias (to `target`, when
    /// given). Returns whether anything was deleted.
    @discardableResult
    static func removeAlias(at path: String, pointingTo target: URL? = nil) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard isAlias(url) else { return false }
        if let target, let resolved = resolve(url),
           Store.canonical(resolved.standardizedFileURL.path) != Store.canonical(target.standardizedFileURL.path),
           FileManager.default.fileExists(atPath: resolved.path) {
            return false
        }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    static func resolve(_ url: URL) -> URL? {
        guard let data = try? NSURL.bookmarkData(withContentsOf: url) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func distance(from: URL, to: URL) -> Int {
        let a = from.standardizedFileURL.pathComponents
        let b = to.standardizedFileURL.pathComponents
        var shared = 0
        while shared < a.count, shared < b.count, a[shared] == b[shared] { shared += 1 }
        return (a.count - shared) + (b.count - shared)
    }

    static func isAlias(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    }

    private static func safe(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
    }
}
