import Foundation

/// Whether a folder is kept in step by a file-syncing service. SQLite in such
/// a folder is at risk: the service copies the index and its write-ahead log
/// separately and whenever it likes, so another Mac can end up with a pair
/// that never existed together.
enum SyncedFolder {
    /// The service's name, or nil for an ordinary local folder.
    static func service(for folder: URL) -> String? {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if path.contains("/Library/Mobile Documents/") { return "iCloud Drive" }
        if (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return "iCloud Drive"
        }
        // File Provider services each mount under ~/Library/CloudStorage/<Service>-<account>.
        if let range = path.range(of: "/Library/CloudStorage/") {
            let mount = path[range.upperBound...].prefix { $0 != "/" }
            let provider = mount.prefix { $0 != "-" }
            switch provider.lowercased() {
            case "dropbox": return "Dropbox"
            case "onedrive": return "OneDrive"
            case "googledrive": return "Google Drive"
            case "box": return "Box"
            default: return provider.isEmpty ? "a syncing service" : String(provider)
            }
        }
        // The older Dropbox client marks its root folder rather than mounting it.
        var probe = URL(fileURLWithPath: path)
        while probe.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: probe.appendingPathComponent(".dropbox").path) {
                return "Dropbox"
            }
            probe.deleteLastPathComponent()
        }
        return nil
    }

    static func warning(for name: String, in service: String) -> String {
        "\(name) is in \(service). A syncing service can copy the index halfway through a write, "
            + "which can corrupt it on another Mac; Doctopus keeps the library open on one Mac at a time, "
            + "but a folder that is not synced is safer."
    }
}
