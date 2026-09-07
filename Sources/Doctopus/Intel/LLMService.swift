import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Structured result of the enrichment pass, independent of who produced it.
struct DocumentInsight: Sendable {
    var summary: String?
    var correspondent: String?
    var docType: String?
    var language: String?
    var intent: String?
    var title: String?
    var tags: [String] = []
    var confidence: Double = 0
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct GeneratedInsight {
    @Guide(description: "One or two sentences describing what this document is and what it concerns. No preamble.")
    var summary: String

    @Guide(description: "The organisation or person that issued or sent the document. Empty string if unclear.")
    var correspondent: String

    @Guide(description: "Document category, e.g. Invoice, Receipt, Contract, Bank Statement, Tax, Insurance, Payslip, Medical, Certificate, Letter.")
    var documentType: String

    @Guide(description: "ISO 639-1 language code of the document body, e.g. en, de, fr.")
    var language: String

    @Guide(description: "What the reader is expected to do: pay, sign, file, read, respond, or none.")
    var intent: String

    @Guide(description: "A short canonical title, at most 8 words, without a date.")
    var title: String

    @Guide(description: "Two to four lowercase topical tags, comma separated, no hashes.")
    var tags: String
}
#endif

/// Apple on-device Foundation model, when the machine has one.
///
/// The framework only exists on macOS 26 with Apple Intelligence enabled, so it
/// is weak-linked and every touchpoint is behind an availability check. On any
/// other machine `isAvailable` is false and the pipeline keeps its heuristic
/// results — the app never degrades into a broken state.
actor LLMService {
    enum Status: Sendable, Equatable {
        case unsupported(String)
        case unavailable(String)
        case ready
    }

    private(set) var status: Status = .unsupported("Requires macOS 26 with Apple Intelligence")
    private var probed = false

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private var sessionBox: LanguageModelSession? {
        get { _session as? LanguageModelSession }
        set { _session = newValue }
    }
    #endif
    private var _session: AnyObject?

    private static let instructions = """
    You classify scanned personal and business documents for a filing system. \
    Answer only from the text you are given. If a field is genuinely not \
    determinable, return an empty string rather than guessing. Never invent \
    names, amounts or dates. Be terse.
    """

    func probe() -> Status {
        if probed { return status }
        probed = true
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                status = .ready
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

    var isAvailable: Bool { probe() == .ready }

    func enrich(text: String, filename: String) async -> DocumentInsight? {
        guard probe() == .ready else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Head and tail carry the letterhead and the totals/signature block;
            // the middle of a long document rarely changes the classification.
            let excerpt = Self.excerpt(text)
            guard excerpt.count > 40 else { return nil }
            let prompt = """
            File name: \(filename)

            Document text:
            \(excerpt)
            """
            do {
                let session = try currentSession()
                let response = try await session.respond(to: prompt, generating: GeneratedInsight.self)
                let g = response.content
                return DocumentInsight(
                    summary: g.summary.nilIfBlank,
                    correspondent: g.correspondent.nilIfBlank,
                    docType: g.documentType.nilIfBlank,
                    language: g.language.nilIfBlank.map { String($0.prefix(5)).lowercased() },
                    intent: g.intent.nilIfBlank?.lowercased(),
                    title: g.title.nilIfBlank,
                    tags: g.tags.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty && $0.count < 32 },
                    confidence: 0.9)
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
    @available(macOS 26.0, *)
    private func currentSession() throws -> LanguageModelSession {
        if let existing = sessionBox { return existing }
        let s = LanguageModelSession(instructions: Self.instructions)
        sessionBox = s
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

    private static func excerpt(_ text: String, limit: Int = 6000) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 3)
        return head + "\n…\n" + tail
    }
}

extension LLMService.Status {
    var label: String {
        switch self {
        case .ready: return "On-device model ready"
        case .unavailable(let r): return r
        case .unsupported(let r): return r
        }
    }
    var isReady: Bool { self == .ready }
}
