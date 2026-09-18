import Foundation

/// Settings persisted as a JSON blob, where a stored blob may be missing a key
/// because it was written before that setting existed.
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

/// The half of the settings that belongs to the app rather than to any one
/// library: which model answers the enrichment questions, how much of the
/// machine to spend, and how documents are looked at.
///
/// Kept in `UserDefaults` rather than in each `library.doctopus`, for two
/// reasons: a library folder is meant to be portable and shareable, and an API
/// key has no business travelling with one; and a choice like "gallery view" is
/// about this Mac, not about a folder.
struct AppWideSettings: StoredSettings, Sendable, Equatable {
    /// Which model answers the enrichment questions, if any.
    var llmBackend: LLMBackend = .onDevice
    var remoteEndpoint = "http://localhost:1234/v1"
    var remoteModel = ""
    var remoteAPIKey = ""
    var remoteTimeout: Double = 120
    var remoteParallelRequests = 2
    /// Characters of document text sent per request. The on-device model has a
    /// small fixed window; a server's is whatever it was loaded with, so this
    /// is worth turning up when the machine on the other end can take it.
    var llmExcerptLimit = 6000
    /// Send the first page of each document to the API as an image as well as
    /// its text — worth having where the endpoint is a vision model, and
    /// refused by every endpoint that is not.
    var remoteVision = false
    /// Longest edge, in pixels, of that page image.
    var remoteVisionImageSize = 1024
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

    /// True when each document's first page is sent as an image as well as its
    /// text. A document OCR found nothing in is still worth asking about then —
    /// a scan whose text layer is noise is exactly what a vision model is for.
    var sendsPageImage: Bool { llmBackend == .remote && remoteVision }

    var effectiveConcurrency: Int {
        if ocrConcurrency > 0 { return min(ocrConcurrency, 16) }
        return max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }
}

/// The half that belongs to the library: how its documents are named, routed
/// and read. Persisted as a JSON blob in that library's own `settings` table,
/// so it travels with the folder it describes.
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
    /// When a model-proposed tag exactly matches one already in the library,
    /// assign it directly instead of leaving it for the user to accept.
    var autoAcceptMatchingTagSuggestions = false
    /// Global default for mirroring tag membership as Finder aliases.
    var mirrorTagsAsAliases = false
    var scanDestination = "Inbox"
    /// How to read an ambiguous numeric date like `03/04/2026`. Per library,
    /// because it is a property of the paperwork, not of the Mac reading it.
    var dateOrder: DateOrder = .automatic
    /// Days that are never a document date — the date printed in a letterhead,
    /// a form's revision date — as `yyyy-MM-dd`, comma separated.
    var ignoredDates = ""

    /// The days the analyzer must never take as a document date.
    var ignoredDays: Set<String> {
        Set(ignoredDates.split(separator: ",")
            .compactMap { $0.trimmingCharacters(in: .whitespaces).nilIfBlank }
            .compactMap { DayDate.parse($0).map { DayDate.text($0) } })
    }
}

/// Everything the pipeline needs to know, as one immutable snapshot the UI can
/// hand to background work.
///
/// It spans both halves, each setting declared once in the half that decides
/// where it is written. Reading one goes through whichever half holds it
/// without naming it, so the pipeline never has to know which is which.
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
    var effectiveConcurrency: Int { appWide.effectiveConcurrency }

    static let storageKey = "app_settings_v1"

    /// The library's own settings, with the app-wide half laid over the top.
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
