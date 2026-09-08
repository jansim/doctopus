import Foundation

/// Everything the pipeline needs to know, persisted as one JSON blob in the
/// `settings` table so the UI can hand an immutable snapshot to background work.
struct AppSettings: Codable, Sendable, Equatable {
    var namingTemplate: String = Naming.defaultTemplate
    var derivedTemplate: String = "{correspondent}/{year}"
    var routingThreshold: Double = 0.75
    var autoRouteImports = true
    var deriveWhenNoRule = true
    var optimizeOnImport = true
    var optimizeExisting = false
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
    /// Global default for mirroring tag membership as Finder aliases.
    var mirrorTagsAsAliases = false
    var ocrConcurrency = 0        // 0 = auto
    var scanDestination = "Inbox"
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
                        timeout: remoteTimeout, parallelRequests: remoteParallelRequests)
    }

    var effectiveConcurrency: Int {
        if ocrConcurrency > 0 { return min(ocrConcurrency, 16) }
        return max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    static let storageKey = "app_settings_v1"

    static func load(from store: Store) async -> AppSettings {
        guard let raw = try? await store.setting(storageKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save(to store: Store) async {
        guard let data = try? JSONEncoder().encode(self),
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
            optimizeExisting: value(.optimizeExisting, d.optimizeExisting),
            llmBackend: value(.llmBackend, Self.legacyBackend(decoder) ?? d.llmBackend),
            remoteEndpoint: value(.remoteEndpoint, d.remoteEndpoint),
            remoteModel: value(.remoteModel, d.remoteModel),
            remoteAPIKey: value(.remoteAPIKey, d.remoteAPIKey),
            remoteTimeout: value(.remoteTimeout, d.remoteTimeout),
            remoteParallelRequests: value(.remoteParallelRequests, d.remoteParallelRequests),
            llmExcerptLimit: value(.llmExcerptLimit, d.llmExcerptLimit),
            mirrorTagsAsAliases: value(.mirrorTagsAsAliases, d.mirrorTagsAsAliases),
            ocrConcurrency: value(.ocrConcurrency, d.ocrConcurrency),
            scanDestination: value(.scanDestination, d.scanDestination),
            viewMode: value(.viewMode, d.viewMode),
            galleryThumbnailSize: value(.galleryThumbnailSize, d.galleryThumbnailSize),
            jpegQuality: value(.jpegQuality, d.jpegQuality),
            targetDPI: value(.targetDPI, d.targetDPI))
    }
}
