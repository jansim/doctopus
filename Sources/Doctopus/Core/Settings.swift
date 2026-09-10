import Foundation

/// The half of the settings that belongs to the app rather than to any one
/// library: which model answers the enrichment questions, how much of the
/// machine to spend, and how documents are looked at.
///
/// Kept in `UserDefaults` rather than in each `library.doctopus`, for two
/// reasons: a library folder is meant to be portable and shareable, and an API
/// key has no business travelling with one; and a choice like "gallery view" is
/// about this Mac, not about a folder.
struct AppWideSettings: Codable, Sendable, Equatable {
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
    var ocrConcurrency = 0        // 0 = auto
    var viewMode: ViewMode = .list
    var galleryThumbnailSize: Double = 150
    var jpegQuality: Double = 0.6
    var targetDPI: Double = 150
}

/// Everything the pipeline needs to know, as one immutable snapshot the UI can
/// hand to background work.
///
/// It spans both halves of the configuration: the per-library ingest settings,
/// persisted as a JSON blob in that library's own `settings` table, and the
/// app-wide ones above, which are merged in on load and written back to
/// `UserDefaults` on save. The pipeline never has to know which is which.
struct AppSettings: Codable, Sendable, Equatable {
    var namingTemplate: String = Naming.defaultTemplate
    var derivedTemplate: String = "{correspondent}/{year}"
    var routingThreshold: Double = 0.75
    var autoRouteImports = true
    var deriveWhenNoRule = true
    /// Imports and scans only. There is deliberately no setting to rewrite
    /// files already in the library while indexing: those are the user's, and
    /// Optimize in the context menu is the way to ask for it. An older library
    /// may still carry `optimizeExisting` in its settings; it is ignored.
    var optimizeOnImport = true
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
    /// When a model-proposed tag exactly matches one already in the library,
    /// assign it directly instead of leaving it for the user to accept.
    var autoAcceptMatchingTagSuggestions = false
    /// Global default for mirroring tag membership as Finder aliases.
    var mirrorTagsAsAliases = false
    var ocrConcurrency = 0        // 0 = auto
    var scanDestination = "Inbox"
    var viewMode: ViewMode = .list
    var galleryThumbnailSize: Double = 150

    var jpegQuality: Double = 0.6
    var targetDPI: Double = 150

    /// The app-wide half, projected in and out of the flat snapshot. Written by
    /// hand rather than synthesized so adding a setting to one half is a
    /// compile error in the other rather than a silently dropped value.
    var appWide: AppWideSettings {
        get {
            AppWideSettings(
                llmBackend: llmBackend, remoteEndpoint: remoteEndpoint, remoteModel: remoteModel,
                remoteAPIKey: remoteAPIKey, remoteTimeout: remoteTimeout,
                remoteParallelRequests: remoteParallelRequests, llmExcerptLimit: llmExcerptLimit,
                ocrConcurrency: ocrConcurrency, viewMode: viewMode,
                galleryThumbnailSize: galleryThumbnailSize,
                jpegQuality: jpegQuality, targetDPI: targetDPI)
        }
        set {
            llmBackend = newValue.llmBackend
            remoteEndpoint = newValue.remoteEndpoint
            remoteModel = newValue.remoteModel
            remoteAPIKey = newValue.remoteAPIKey
            remoteTimeout = newValue.remoteTimeout
            remoteParallelRequests = newValue.remoteParallelRequests
            llmExcerptLimit = newValue.llmExcerptLimit
            ocrConcurrency = newValue.ocrConcurrency
            viewMode = newValue.viewMode
            galleryThumbnailSize = newValue.galleryThumbnailSize
            jpegQuality = newValue.jpegQuality
            targetDPI = newValue.targetDPI
        }
    }

    var optimizerOptions: Optimizer.Options {
        var o = Optimizer.Options()
        o.jpegQuality = CGFloat(jpegQuality)
        o.targetDPI = CGFloat(targetDPI)
        return o
    }

    var remoteConfig: RemoteLLMConfig {
        RemoteLLMConfig(endpoint: remoteEndpoint, model: remoteModel, apiKey: remoteAPIKey,
                        timeout: remoteTimeout, parallelRequests: remoteParallelRequests)
    }

    var effectiveConcurrency: Int {
        if ocrConcurrency > 0 { return min(ocrConcurrency, 16) }
        return max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    static let storageKey = "app_settings_v1"

    /// The library's own settings, with the app-wide half laid over the top.
    @MainActor
    static func load(from store: Store) async -> AppSettings {
        var settings = AppSettings()
        var fromLibrary = false
        if let raw = try? await store.setting(storageKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
            fromLibrary = true
        }
        // The app-wide half used to be written into the library blob along with
        // everything else. The first library opened after the split hands its
        // copy over rather than letting a configured endpoint quietly reset.
        if !Preferences.hasAppWide, fromLibrary {
            Preferences.appWide = settings.appWide
        }
        settings.appWide = Preferences.appWide
        return settings
    }

    /// Each half goes where it belongs. The blob written to the library carries
    /// the app-wide fields at their defaults, so no library ends up holding a
    /// stale copy of somebody's endpoint — or their API key.
    @MainActor
    func save(to store: Store) async {
        Preferences.appWide = appWide
        var libraryOnly = self
        libraryOnly.appWide = AppWideSettings()
        guard let data = try? JSONEncoder().encode(libraryOnly),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? await store.setSetting(AppSettings.storageKey, raw)
    }
}

/// Decoded key by key, each one falling back to its default.
///
/// The synthesized `init(from:)` ignores the defaults above and throws on the
/// first key it cannot find, and `load` turns any throw into a fresh
/// `AppSettings` — so without this, every release that adds a setting silently
/// resets all the others, view mode and thumbnail size included. Written in an
/// extension so the memberwise initializer survives.
extension AppSettings {
    /// `useOnDeviceModel` was a single on/off switch before there was more than
    /// one backend to choose between. Someone who turned it off meant it, so
    /// their setting is carried over rather than reset to the new default.
    private enum LegacyKeys: String, CodingKey { case useOnDeviceModel }

    private static func legacyBackend(_ decoder: Decoder) -> LLMBackend? {
        guard let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
              let wanted = try? legacy.decodeIfPresent(Bool.self, forKey: .useOnDeviceModel)
        else { return nil }
        return wanted ? .onDevice : .off
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(
            namingTemplate: value(.namingTemplate, d.namingTemplate),
            derivedTemplate: value(.derivedTemplate, d.derivedTemplate),
            routingThreshold: value(.routingThreshold, d.routingThreshold),
            autoRouteImports: value(.autoRouteImports, d.autoRouteImports),
            deriveWhenNoRule: value(.deriveWhenNoRule, d.deriveWhenNoRule),
            optimizeOnImport: value(.optimizeOnImport, d.optimizeOnImport),
            llmBackend: value(.llmBackend, Self.legacyBackend(decoder) ?? d.llmBackend),
            remoteEndpoint: value(.remoteEndpoint, d.remoteEndpoint),
            remoteModel: value(.remoteModel, d.remoteModel),
            remoteAPIKey: value(.remoteAPIKey, d.remoteAPIKey),
            remoteTimeout: value(.remoteTimeout, d.remoteTimeout),
            remoteParallelRequests: value(.remoteParallelRequests, d.remoteParallelRequests),
            llmExcerptLimit: value(.llmExcerptLimit, d.llmExcerptLimit),
            autoAcceptMatchingTagSuggestions: value(.autoAcceptMatchingTagSuggestions, d.autoAcceptMatchingTagSuggestions),
            mirrorTagsAsAliases: value(.mirrorTagsAsAliases, d.mirrorTagsAsAliases),
            ocrConcurrency: value(.ocrConcurrency, d.ocrConcurrency),
            scanDestination: value(.scanDestination, d.scanDestination),
            viewMode: value(.viewMode, d.viewMode),
            galleryThumbnailSize: value(.galleryThumbnailSize, d.galleryThumbnailSize),
            jpegQuality: value(.jpegQuality, d.jpegQuality),
            targetDPI: value(.targetDPI, d.targetDPI))
    }
}

/// Decoded key by key for the same reason `AppSettings` is: a release that adds
/// one app-wide setting must not reset the rest.
extension AppWideSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppWideSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(
            llmBackend: value(.llmBackend, d.llmBackend),
            remoteEndpoint: value(.remoteEndpoint, d.remoteEndpoint),
            remoteModel: value(.remoteModel, d.remoteModel),
            remoteAPIKey: value(.remoteAPIKey, d.remoteAPIKey),
            remoteTimeout: value(.remoteTimeout, d.remoteTimeout),
            remoteParallelRequests: value(.remoteParallelRequests, d.remoteParallelRequests),
            llmExcerptLimit: value(.llmExcerptLimit, d.llmExcerptLimit),
            ocrConcurrency: value(.ocrConcurrency, d.ocrConcurrency),
            viewMode: value(.viewMode, d.viewMode),
            galleryThumbnailSize: value(.galleryThumbnailSize, d.galleryThumbnailSize),
            jpegQuality: value(.jpegQuality, d.jpegQuality),
            targetDPI: value(.targetDPI, d.targetDPI))
    }
}
