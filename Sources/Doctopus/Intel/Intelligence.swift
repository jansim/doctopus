import Foundation

/// Whether an enrichment backend can run, and what to call it in the UI.
enum LLMStatus: Sendable, Equatable {
    /// The backend cannot exist on this machine, or is switched off.
    case unsupported(String)
    /// The backend exists but is not usable right now.
    case unavailable(String)
    /// Usable, labelled with whatever identifies it — model name or endpoint.
    case ready(String)

    var label: String {
        switch self {
        case .unsupported(let s), .unavailable(let s), .ready(let s): return s
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Which model answers the enrichment questions.
enum LLMBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Deterministic heuristics only — the pipeline still fills in dates,
    /// correspondents, types and titles, it just never asks a model.
    case off
    /// Apple's on-device Foundation model.
    case onDevice
    /// Any OpenAI-compatible endpoint: LM Studio, Ollama, llama.cpp, a hosted API.
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Heuristics only"
        case .onDevice: return "Apple on-device model"
        case .remote: return "API endpoint"
        }
    }

    /// The value written to `metadata.source` so the inspector can say where a
    /// field came from long after the fact.
    var metadataSource: String? {
        switch self {
        case .off: return nil
        case .onDevice: return "llm"
        case .remote: return "remote"
        }
    }
}

/// The task itself, shared by both backends.
///
/// Asking the two models different questions would make their answers
/// incomparable, and `metadata.source` would stop meaning anything — so the
/// wording lives here once and each backend only decides how to transport it.
enum LLMPrompt {
    static let instructions = """
    You classify scanned personal and business documents for a filing system. \
    Answer only from the text you are given. If a field is genuinely not \
    determinable, return an empty string rather than guessing. Never invent \
    names, amounts or dates. Be terse.
    """

    /// The fields asked for, in one place. The JSON schema sent to servers that
    /// support structured output and the prose spelled out for those that do
    /// not are both generated from this, so the two cannot drift apart.
    static let fields: [(key: String, description: String)] = [
        ("summary", "One or two sentences on what this document is and what it concerns."),
        ("correspondent", "The organisation or person that issued or sent it."),
        ("documentType", "Category, e.g. Invoice, Receipt, Contract, Bank Statement, Tax, Insurance, Payslip, Medical, Certificate, Letter."),
        ("language", "The two-letter ISO 639-1 code of the document body and nothing else, e.g. en, de, fr — never the name of the language."),
        ("intent", "What the reader is expected to do: exactly one of pay, sign, file, read, respond, none."),
        ("title", "A short canonical title, at most 8 words, without a date."),
    ]
    static let tagsDescription = "Two to four lowercase topical tags."

    /// The same job stated for a server that has no schema-guided decoding.
    static var jsonInstructions: String {
        let keys = fields.map { "\"\($0.key)\": \($0.description)" }
            + ["\"tags\": \(tagsDescription) An array of strings."]
        return instructions + """


        Reply with one JSON object and nothing else — no prose, no code fence, no
        reasoning. Keys:
        \(keys.joined(separator: "\n"))

        Use "" for any string you cannot determine and [] for no tags.
        """
    }

    /// The same fields as a JSON schema.
    ///
    /// Worth reaching for first wherever a server takes it: a constrained
    /// decode is not just more reliable to parse, it stops a reasoning model
    /// emitting a thinking trace at all, which on a local model is the
    /// difference between four seconds and half a minute per document.
    static var jsonSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for field in fields {
            properties[field.key] = ["type": "string", "description": field.description]
        }
        properties["tags"] = ["type": "array", "description": tagsDescription,
                              "items": ["type": "string"]]
        return [
            "type": "object",
            "properties": properties,
            "required": fields.map(\.key) + ["tags"],
            "additionalProperties": false,
        ]
    }

    static func user(text: String, filename: String, limit: Int) -> String {
        """
        File name: \(filename)

        Document text:
        \(excerpt(text, limit: limit))
        """
    }

    /// Head and tail carry the letterhead and the totals/signature block; the
    /// middle of a long document rarely changes the classification.
    static func excerpt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 3)
        return head + "\n…\n" + tail
    }

    /// Below this there is nothing worth spending a model call on.
    static let minimumCharacters = 40
}

/// Picks the enrichment backend and gives the pipeline one door to knock on.
///
/// Both backends answer the same question and return the same `DocumentInsight`,
/// so nothing downstream — routing, tagging, the inspector — knows or cares
/// which one ran.
actor Intelligence {
    private let onDevice = LLMService()
    private let remote = RemoteLLMService()

    private var backend: LLMBackend = .onDevice
    private var config = RemoteLLMConfig()
    private var excerptLimit = 6000

    func update(settings: AppSettings) async {
        backend = settings.llmBackend
        config = settings.remoteConfig
        excerptLimit = settings.llmExcerptLimit
    }

    var isEnabled: Bool { backend != .off }
    var activeBackend: LLMBackend { backend }

    /// Cheap — both backends cache what they last concluded.
    func status() async -> LLMStatus {
        switch backend {
        case .off:
            return .unsupported("Model enrichment is off")
        case .onDevice:
            return await onDevice.probe()
        case .remote:
            return await remote.status(config)
        }
    }

    /// Asks again rather than trusting the cached answer. This is what the
    /// Test button in Settings runs.
    func refreshStatus() async -> LLMStatus {
        await remote.forget()
        return await status()
    }

    func enrich(text: String, filename: String) async -> DocumentInsight? {
        guard text.count >= LLMPrompt.minimumCharacters else { return nil }
        switch backend {
        case .off:
            return nil
        case .onDevice:
            return await onDevice.enrich(text: text, filename: filename, limit: excerptLimit)
        case .remote:
            return await remote.enrich(text: text, filename: filename,
                                       config: config, limit: excerptLimit)
        }
    }

    /// How many documents may be in flight at once. The on-device session is
    /// serialized inside its own actor, so asking for more there buys nothing;
    /// a server on the other end of a socket happily takes a few at a time.
    var width: Int { backend == .remote ? max(1, config.parallelRequests) : 1 }

    // MARK: - Settings pane

    /// Checks a configuration that is not necessarily the active one, so the
    /// Test button works before the change is committed.
    func check(_ config: RemoteLLMConfig) async -> LLMStatus {
        await remote.check(config)
    }

    func models(_ config: RemoteLLMConfig) async -> [String] {
        await remote.models(config)
    }
}
