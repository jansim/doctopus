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
        static let apiKeyAccount = "remote-llm-api-key"
    }

    /// Settings that do not decode are copied aside before anything can save
    /// defaults over them, and read as defaults until then.
    static var appWide: AppWideSettings {
        get {
            guard let raw = defaults.string(forKey: Key.appWide) else { return withAPIKey(AppWideSettings()) }
            if let settings = AppWideSettings.decodedIfReadable(from: Data(raw.utf8)) {
                // Written by a build that kept the key among the preferences:
                // saved straight back, which moves it to the keychain.
                if usesKeychain, !settings.remoteAPIKey.isEmpty {
                    Preferences.appWide = settings
                    return settings
                }
                return withAPIKey(settings)
            }
            defaults.set(raw, forKey: Key.unreadableAppWide)
            appWideUnreadable = true
            return withAPIKey(AppWideSettings())
        }
        set {
            var newValue = newValue
            if usesKeychain {
                let key = newValue.remoteAPIKey
                // Left among the preferences only if the keychain will not
                // take it: a key kept in the wrong place beats a key lost.
                if key == storedAPIKey || Keychain.write(key, Key.apiKeyAccount) {
                    storedAPIKey = key
                    newValue.remoteAPIKey = ""
                }
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8) else { return }
            defaults.set(raw, forKey: Key.appWide)
        }
    }

    /// The headless checks keep to their throwaway suite, and out of the
    /// keychain of whoever runs them.
    private static var usesKeychain: Bool { defaults == .standard }

    /// The key as the keychain last had it, so that saving the settings does
    /// not ask the keychain again for every other setting that changes.
    private static var storedAPIKey: String?

    private static func withAPIKey(_ settings: AppWideSettings) -> AppWideSettings {
        guard usesKeychain else { return settings }
        if storedAPIKey == nil { storedAPIKey = Keychain.read(Key.apiKeyAccount) ?? "" }
        var settings = settings
        settings.remoteAPIKey = storedAPIKey ?? ""
        return settings
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
        try? await store.setHistoryLimit(library.historyLimit)
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
        try await store.setHistoryLimit(library.historyLimit)
    }
}
