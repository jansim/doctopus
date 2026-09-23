import Foundation

protocol StoredSettings: Codable {
    init()
}

extension StoredSettings {
    /// Decodes `data`, taking every key it does not carry from a fresh `Self`,
    /// so that adding a setting does not reset the ones already stored.
    static func decoded(from data: Data) -> Self {
        decodedIfReadable(from: data) ?? Self()
    }

    /// Nil when `data` holds something that does not decode, so the caller can
    /// keep it rather than save defaults over it. Nothing stored is a fresh start.
    static func decodedIfReadable(from data: Data) -> Self? {
        guard !data.isEmpty else { return Self() }
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = try? JSONEncoder().encode(Self()),
              var merged = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any]
        else { return nil }
        merged.merge(stored) { _, written in written }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
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
    /// Stored as switched-off raw values: new fields start on, and a stale name cannot fail the decode.
    var unpredictedFields: [String] = []
    /// Empty means `LLMPrompt.defaultTemplate`, so an untouched prompt follows the default.
    var llmPromptTemplate = ""
    var ocrConcurrency = 0        // 0 = auto
    var viewMode: ViewMode = .list
    var galleryThumbnailSize: Double = 150
    var jpegQuality: Double = 0.6
    var targetDPI: Double = 150

    var effectiveConcurrency: Int {
        if ocrConcurrency > 0 { return min(ocrConcurrency, 16) }
        return max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }
}

struct LibrarySettings: StoredSettings, Sendable, Equatable {
    var namingTemplate: String = Naming.defaultTemplate
    var filenameUnderscoresForSpaces = false
    var filenameASCIIOnly = false
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

    var namingOptions: Naming.Options {
        Naming.Options(underscoresForSpaces: filenameUnderscoresForSpaces, asciiOnly: filenameASCIIOnly)
    }

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
    var namingOptions: Naming.Options { library.namingOptions }
    var effectiveConcurrency: Int { appWide.effectiveConcurrency }
}

enum LLMBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case onDevice
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Heuristics only"
        case .onDevice: return "Apple on-device model"
        case .remote: return "API endpoint"
        }
    }

    var metadataSource: String? {
        switch self {
        case .off: return nil
        case .onDevice: return "llm"
        case .remote: return "remote"
        }
    }
}
