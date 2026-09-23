import Foundation
import AppKit

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

    /// Also what the Dock icon's menu lists. Skipped for the headless checks.
    static func noteRecentLibrary(_ container: URL) {
        guard defaults == .standard else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(container)
    }

    static func uiState(_ key: String) -> String? { defaults.string(forKey: "ui.\(key)") }
    static func setUIState(_ key: String, _ value: String) { defaults.set(value, forKey: "ui.\(key)") }
}

extension AppSettings {
    static let storageKey = "app_settings_v1"

    @MainActor
    static func load(from store: Store) async -> AppSettings {
        let raw = (try? await store.setting(storageKey)) ?? ""
        return AppSettings(library: LibrarySettings.decoded(from: Data(raw.utf8)),
                           appWide: Preferences.appWide)
    }

    /// Each half goes where it belongs. Only the library's own settings reach
    /// the blob, so no library ends up holding somebody's API key.
    @MainActor
    func save(to store: Store) async {
        Preferences.appWide = appWide
        guard let data = try? JSONEncoder().encode(library),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? await store.setSetting(Self.storageKey, raw)
    }
}
