import Foundation

/// Creates and prunes real macOS Finder aliases so that tag membership can be
/// mirrored into the file tree without ever duplicating a document's bytes.
///
/// Aliases are written with `NSURL.writeBookmarkData(to:options:)`, which is the
/// same mechanism Finder's "Make Alias" uses — they survive the target moving.
enum AliasManager {

    /// Directory that holds mirrored tag folders, e.g. `<root>/.Tags/Invoices/`.
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

    /// Deletes an alias Doctopus made — and nothing else.
    ///
    /// The registry only records where an alias *was* written. Anything could
    /// be at that path now: the user may have replaced the alias with the real
    /// file, or with an alias of their own to something else. So the item is
    /// only removed when it is still an alias file and, when `target` is given,
    /// still points at that document (or at nothing, if the document is gone).
    /// Returns whether anything was deleted.
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

    /// Resolves an alias file back to its target, used when the tree scan meets one.
    static func resolve(_ url: URL) -> URL? {
        guard let data = try? NSURL.bookmarkData(withContentsOf: url) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func isAlias(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    }

    private static func safe(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
    }
}
