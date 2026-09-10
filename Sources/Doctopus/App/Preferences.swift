import Foundation

/// App-wide settings that are not tied to any one library — chiefly the list of
/// libraries to reopen at launch. Per-library configuration (tags, fields,
/// rules, ingest settings) lives in each `library.doctopus` instead.
@MainActor
enum Preferences {
    /// `.standard` in the app; the headless UI checks point this at a throwaway
    /// suite so a run never touches real preferences.
    static var defaults: UserDefaults = .standard

    private enum Key {
        static let openLibraries = "openLibraries_v1"
        static let libraryFolderName = "libraryFolderName"
        static let appWide = "appSettings_v1"
    }

    /// False until the app-wide settings have been written once — the signal
    /// that a library opened before the split still holds the only copy.
    static var hasAppWide: Bool { defaults.string(forKey: Key.appWide) != nil }

    /// The half of the settings that is not tied to a library. See
    /// `AppWideSettings` for why these live out here.
    static var appWide: AppWideSettings {
        get {
            guard let raw = defaults.string(forKey: Key.appWide),
                  let decoded = try? JSONDecoder().decode(AppWideSettings.self, from: Data(raw.utf8))
            else { return AppWideSettings() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8) else { return }
            defaults.set(raw, forKey: Key.appWide)
        }
    }

    /// Security-scoped bookmarks to each open `library.doctopus` directory.
    static var libraryBookmarks: [Data] {
        get { (defaults.array(forKey: Key.openLibraries) as? [Data]) ?? [] }
        set { defaults.set(newValue, forKey: Key.openLibraries) }
    }

    /// Name of the container directory created inside a folder when a new
    /// library is made. Visible in Finder; `library.doctopus` by default.
    static var libraryFolderName: String {
        get {
            let name = defaults.string(forKey: Key.libraryFolderName) ?? ""
            return name.isEmpty ? "library.doctopus" : name
        }
        set { defaults.set(newValue, forKey: Key.libraryFolderName) }
    }

    // MARK: - UI state (column layout, collapsed folders, sort)

    static func uiState(_ key: String) -> String? { defaults.string(forKey: "ui.\(key)") }
    static func setUIState(_ key: String, _ value: String) { defaults.set(value, forKey: "ui.\(key)") }
}
