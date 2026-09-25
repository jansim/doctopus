import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct DocumentInsight: Sendable {
    var summary: String?
    var correspondent: String?
    var docType: String?
    var language: String?
    var intent: String?
    var title: String?
    var tags: [String] = []
    var source: String = "llm"
}

/// FoundationModels only exists on macOS 26 with Apple Intelligence, so it is
/// weak-linked and every touchpoint sits behind an availability check.
actor LLMService {
    private(set) var status: LLMStatus = .unsupported("Requires macOS 26 with Apple Intelligence")
    private var probed = false

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private var sessionBox: LanguageModelSession? {
        get { _session as? LanguageModelSession }
        set { _session = newValue }
    }
    #endif
    private var _session: AnyObject?
    private var sessionInstructions: String?

    func probe() -> LLMStatus {
        if probed { return status }
        probed = true
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                status = .ready("Apple on-device model")
            case .unavailable(let reason):
                status = .unavailable(Self.describe(reason))
            @unknown default:
                status = .unavailable("Unknown model state")
            }
            return status
        }
        #endif
        status = .unsupported("Requires macOS 26 with Apple Intelligence")
        return status
    }

    var isAvailable: Bool { probe().isReady }

    func enrich(text: String, filename: String, question: LLMPrompt.Question = .init(),
                limit: Int, candidateTags: [String] = [],
                examples: [FilingExample] = []) async -> DocumentInsight? {
        guard probe().isReady else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let prompt = LLMPrompt.user(text: text, filename: filename, limit: limit,
                                        candidateTags: candidateTags,
                                        examples: examples, fields: question.fields)
            do {
                let session = currentSession(instructions: question.instructions())
                let response = try await session.respond(to: prompt, schema: try Self.schema(question.fields))
                guard var insight = RemoteLLMService.parse(response.content.jsonString,
                                                           fields: question.fields) else { return nil }
                insight.source = "llm:v\(MetadataSource.promptVersion)"
                return insight
            } catch {
                // A single failure (context overflow, guardrail, model unloaded)
                // must not poison the rest of the batch.
                _session = nil
                return nil
            }
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    /// Built at run time so the model only produces the fields that were asked for.
    @available(macOS 26.0, *)
    private static func schema(_ fields: Set<InsightField>) throws -> GenerationSchema {
        let text = DynamicGenerationSchema(type: String.self)
        let properties = LLMPrompt.Question(fields: fields).asked.map { field in
            DynamicGenerationSchema.Property(
                name: field.rawValue,
                description: nil,
                schema: field == .tags
                    ? DynamicGenerationSchema(arrayOf: text, minimumElements: 0, maximumElements: 4)
                    : text)
        }
        let root = DynamicGenerationSchema(name: "DocumentInsight", description: nil,
                                           properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Instructions are fixed per session, so a changed prompt needs a new one.
    @available(macOS 26.0, *)
    private func currentSession(instructions: String) -> LanguageModelSession {
        if let existing = sessionBox, sessionInstructions == instructions { return existing }
        let s = LanguageModelSession(instructions: instructions)
        sessionBox = s
        sessionInstructions = instructions
        return s
    }

    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "This Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings"
        case .modelNotReady: return "The on-device model is still downloading"
        @unknown default: return "On-device model unavailable"
        }
    }
    #endif
}
