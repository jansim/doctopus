import Foundation

protocol StoredSettings: Codable {
    init()
}

extension StoredSettings {
    /// Decodes `data`, taking every key it does not carry from a fresh `Self`,
    /// so that adding a setting does not reset the ones already stored.
    static func decoded(from data: Data) -> Self {
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = try? JSONEncoder().encode(Self()),
              var merged = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any]
        else { return Self() }
        merged.merge(stored) { _, written in written }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return decoded
    }
}

/// Kept in `UserDefaults` rather than the library: a library folder is meant to
/// be shareable, and an API key must never travel with one.
struct AppWideSettings: StoredSettings, Sendable, Equatable {
    var llmBackend: LLMBackend = .onDevice
    var remoteEndpoint = "http://localhost:1234/v1"
    var remoteModel = ""
    var remoteAPIKey = ""
    var remoteTimeout: Double = 120
    var remoteParallelRequests = 2
    var llmExcerptLimit = 6000
    var remoteVision = false
    var remoteVisionImageSize = 1024
    /// Raw values of the `InsightField`s switched off, rather than the ones
    /// switched on: a field added later starts out on, and a stored name that
    /// no longer exists cannot fail the decode and reset every other setting.
    var unpredictedFields: [String] = []
    /// Empty means `LLMPrompt.defaultTemplate`, so a user who never touched the
    /// prompt picks up improvements to it with the next version.
    var llmPromptTemplate = ""
    var ocrConcurrency = 0        // 0 = auto
    var viewMode: ViewMode = .list
    var galleryThumbnailSize: Double = 150
    var jpegQuality: Double = 0.6
    var targetDPI: Double = 150

    var optimizerOptions: Optimizer.Options {
        var o = Optimizer.Options()
        o.jpegQuality = CGFloat(jpegQuality)
        o.targetDPI = CGFloat(targetDPI)
        return o
    }

    var remoteConfig: RemoteLLMConfig {
        RemoteLLMConfig(endpoint: remoteEndpoint, model: remoteModel, apiKey: remoteAPIKey,
                        timeout: remoteTimeout, parallelRequests: remoteParallelRequests,
                        vision: remoteVision, visionImageSize: remoteVisionImageSize)
    }

    var sendsPageImage: Bool { llmBackend == .remote && remoteVision }

    var predictedFields: Set<InsightField> {
        get { Set(InsightField.allCases.filter { !unpredictedFields.contains($0.rawValue) }) }
        set { unpredictedFields = InsightField.allCases.filter { !newValue.contains($0) }.map(\.rawValue) }
    }

    var effectiveConcurrency: Int {
        if ocrConcurrency > 0 { return min(ocrConcurrency, 16) }
        return max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }
}

struct LibrarySettings: StoredSettings, Sendable, Equatable {
    var namingTemplate: String = Naming.defaultTemplate
    var derivedTemplate: String = "{correspondent}/{year}"
    var routingThreshold: Double = 0.75
    var autoRouteImports = true
    var deriveWhenNoRule = true
    /// Imports and scans only. There is deliberately no setting to rewrite
    /// files already in the library while indexing: those are the user's, and
    /// Optimize in the context menu is the way to ask for it.
    var optimizeOnImport = true
    var autoAcceptMatchingTagSuggestions = false
    var mirrorTagsAsAliases = false
    var scanDestination = "Inbox"
    var dateOrder: DateOrder = .automatic
    var ignoredDates = ""

    var ignoredDays: Set<String> {
        Set(ignoredDates.split(separator: ",")
            .compactMap { $0.trimmingCharacters(in: .whitespaces).nilIfBlank }
            .compactMap { DayDate.parse($0).map { DayDate.text($0) } })
    }
}

@dynamicMemberLookup
struct AppSettings: Sendable, Equatable {
    var library = LibrarySettings()
    var appWide = AppWideSettings()

    subscript<T>(dynamicMember keyPath: WritableKeyPath<LibrarySettings, T>) -> T {
        get { library[keyPath: keyPath] }
        set { library[keyPath: keyPath] = newValue }
    }

    subscript<T>(dynamicMember keyPath: WritableKeyPath<AppWideSettings, T>) -> T {
        get { appWide[keyPath: keyPath] }
        set { appWide[keyPath: keyPath] = newValue }
    }

    var ignoredDays: Set<String> { library.ignoredDays }
    var optimizerOptions: Optimizer.Options { appWide.optimizerOptions }
    var remoteConfig: RemoteLLMConfig { appWide.remoteConfig }
    var sendsPageImage: Bool { appWide.sendsPageImage }
    var predictedFields: Set<InsightField> {
        get { appWide.predictedFields }
        set { appWide.predictedFields = newValue }
    }
    var effectiveConcurrency: Int { appWide.effectiveConcurrency }

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
