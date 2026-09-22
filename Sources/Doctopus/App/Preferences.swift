import Foundation

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

    static var appWide: AppWideSettings {
        get {
            guard let raw = defaults.string(forKey: Key.appWide) else { return AppWideSettings() }
            return AppWideSettings.decoded(from: Data(raw.utf8))
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8) else { return }
            defaults.set(raw, forKey: Key.appWide)
        }
    }

    static var libraryBookmarks: [Data] {
        get { (defaults.array(forKey: Key.openLibraries) as? [Data]) ?? [] }
        set { defaults.set(newValue, forKey: Key.openLibraries) }
    }

    static var libraryFolderName: String {
        get {
            let name = defaults.string(forKey: Key.libraryFolderName) ?? ""
            return name.isEmpty ? "library.doctopus" : name
        }
        set { defaults.set(newValue, forKey: Key.libraryFolderName) }
    }

    static func uiState(_ key: String) -> String? { defaults.string(forKey: "ui.\(key)") }
    static func setUIState(_ key: String, _ value: String) { defaults.set(value, forKey: "ui.\(key)") }
}
