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
        static let unreadableAppWide = "appSettings_v1.unreadable"
    }

    /// Settings that do not decode are copied aside before anything can save
    /// defaults over them, and read as defaults until then.
    static var appWide: AppWideSettings {
        get {
            guard let raw = defaults.string(forKey: Key.appWide) else { return AppWideSettings() }
            if let settings = AppWideSettings.decodedIfReadable(from: Data(raw.utf8)) { return settings }
            defaults.set(raw, forKey: Key.unreadableAppWide)
            appWideUnreadable = true
            return AppWideSettings()
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

    /// Set when the stored app-wide settings did not decode; cleared once said.
    static var appWideUnreadable = false

    static func uiState(_ key: String) -> String? { defaults.string(forKey: "ui.\(key)") }
    static func setUIState(_ key: String, _ value: String) { defaults.set(value, forKey: "ui.\(key)") }
}

extension AppSettings {
    static let storageKey = "app_settings_v1"

    static let unreadableKey = "app_settings_v1.unreadable"

    /// `problem` says what could not be read. Library settings that do not
    /// decode are copied aside first, so the defaults read in their place
    /// cannot be saved over the only copy.
    @MainActor
    static func load(from store: Store) async -> (settings: AppSettings, problem: String?) {
        var problems: [String] = []
        let raw: String
        do {
            raw = try await store.setting(storageKey) ?? ""
        } catch {
            raw = ""
            problems.append("its settings could not be read (\(error.localizedDescription))")
        }
        var library = LibrarySettings()
        if let decoded = LibrarySettings.decodedIfReadable(from: Data(raw.utf8)) {
            library = decoded
        } else {
            do {
                try await store.setSetting(unreadableKey, raw)
                problems.append("its settings could not be read, and a copy was kept in its index")
            } catch {
                problems.append("its settings could not be read or kept aside (\(error.localizedDescription))")
            }
        }
        let appWide = Preferences.appWide
        if Preferences.appWideUnreadable {
            Preferences.appWideUnreadable = false
            problems.append("the app-wide settings could not be read, and a copy was kept aside")
        }
        let problem = problems.isEmpty ? nil
            : "Using default settings for \(store.root.lastPathComponent): " + problems.joined(separator: "; ") + "."
        return (AppSettings(library: library, appWide: appWide), problem)
    }

    /// Each half goes where it belongs. Only the library's own settings reach
    /// the blob, so no library ends up holding somebody's API key.
    @MainActor
    func save(to store: Store) async throws {
        Preferences.appWide = appWide
        guard let data = try? JSONEncoder().encode(library),
              let raw = String(data: data, encoding: .utf8) else { return }
        try await store.setSetting(Self.storageKey, raw)
    }
}
