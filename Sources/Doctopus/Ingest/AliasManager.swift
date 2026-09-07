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

    static func removeAlias(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
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
