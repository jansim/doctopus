import Foundation

/// Connection details for an OpenAI-compatible chat completions server.
struct RemoteLLMConfig: Sendable, Equatable {
    var endpoint = "http://localhost:1234/v1"
    var model = ""
    var apiKey = ""
    var timeout: Double = 120
    var parallelRequests = 2

    /// Tolerates the endpoint people actually paste. LM Studio shows
    /// `http://localhost:1234`, Ollama `http://localhost:11434`, hosted APIs a
    /// full `https://…/v1`, and copying from a curl example brings the
    /// `/chat/completions` along with it — all four end up in the same place.
    var baseURL: URL? {
        var text = endpoint.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/chat/completions", "/completions"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url.path.isEmpty || url.path == "/" ? url.appendingPathComponent("v1") : url
    }

    var trimmedModel: String { model.trimmingCharacters(in: .whitespaces) }
    var isConfigured: Bool { baseURL != nil && !trimmedModel.isEmpty }
}

/// Any OpenAI-compatible chat completions server: LM Studio, Ollama, llama.cpp,
/// vLLM, or a hosted API.
///
/// One request shape covers all of them, so there is no per-vendor code here —
/// only the endpoint and the model name change. Unlike the on-device backend
/// this one sends document text off the machine, which is why it is never the
/// default and the settings pane says so plainly.
actor RemoteLLMService {
    private var cached: (config: RemoteLLMConfig, status: LLMStatus)?

    /// How each endpoint likes to be asked, once we have found out. A rejection
    /// is refused before any inference happens, so walking the ladder costs
    /// milliseconds — but only once per endpoint per session.
    private var formats: [String: ResponseFormat] = [:]

    /// Most to least constrained. `json_schema` is worth insisting on: it is
    /// the only one of the three that stops a reasoning model spending its
    /// whole token budget on a thinking trace before it starts the answer.
    enum ResponseFormat: String, Sendable {
        case schema, jsonObject, plain

        var next: ResponseFormat? {
            switch self {
            case .schema: return .jsonObject
            case .jsonObject: return .plain
            case .plain: return nil
            }
        }

        var body: [String: Any]? {
            switch self {
            case .schema:
                return ["type": "json_schema",
                        "json_schema": ["name": "document_insight", "strict": true,
                                        "schema": LLMPrompt.jsonSchema]]
            case .jsonObject:
                return ["type": "json_object"]
            case .plain:
                return nil
            }
        }
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    /// Forgets the cached verdict, so the next question hits the server.
    func forget() { cached = nil }

    /// The last known verdict, checking only if there is not one already.
    func status(_ config: RemoteLLMConfig) async -> LLMStatus {
        if let cached, cached.config == config { return cached.status }
        return await check(config)
    }

    /// Asks the server whether it is there and whether it has the model.
    @discardableResult
    func check(_ config: RemoteLLMConfig) async -> LLMStatus {
        let status = await probe(config)
        cached = (config, status)
        return status
    }

    private func probe(_ config: RemoteLLMConfig) async -> LLMStatus {
        guard let base = config.baseURL else {
            return .unsupported("Enter the address of an OpenAI-compatible server")
        }
        guard !config.trimmedModel.isEmpty else {
            return .unavailable("Choose a model to use at \(base.host ?? base.absoluteString)")
        }
        do {
            let names = try await fetchModels(config)
            // An empty list is not a failure: some servers load a model lazily
            // and list nothing until they have, and plenty of gateways do not
            // implement /models at all.
            if !names.isEmpty, !names.contains(config.trimmedModel) {
                return .unavailable("\(base.host ?? "The server") has no model named “\(config.trimmedModel)”")
            }
            return .ready("\(config.trimmedModel) at \(base.host ?? base.absoluteString)")
        } catch {
            return .unavailable(Self.describe(error, base: base))
        }
    }

    /// The models the server is offering, for the picker in Settings.
    func models(_ config: RemoteLLMConfig) async -> [String] {
        (try? await fetchModels(config)) ?? []
    }

    private func fetchModels(_ config: RemoteLLMConfig) async throws -> [String] {
        guard let base = config.baseURL else { throw RemoteError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        // A model list should answer immediately even when the chat timeout is
        // generous, otherwise the Test button sits there for two minutes.
        request.timeoutInterval = min(config.timeout, 15)
        authorize(&request, config)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: - Enrichment

    func enrich(text: String, filename: String,
                config: RemoteLLMConfig, limit: Int) async -> DocumentInsight? {
        guard let base = config.baseURL, config.isConfigured else { return nil }
        let prompt = LLMPrompt.user(text: text, filename: filename, limit: limit)
        let key = base.absoluteString
        var format = formats[key] ?? .schema

        while true {
            do {
                let reply = try await complete(prompt: prompt, config: config,
                                               base: base, format: format)
                // Remembered only once it has actually answered, so a 400 for
                // some unrelated reason cannot talk us out of a format the
                // server does support.
                formats[key] = format
                if reply.truncated {
                    Self.log("\(filename): the reply was cut off at \(reply.tokens ?? 0) tokens")
                }
                guard let insight = Self.parse(reply.content) else {
                    Self.log("\(filename): could not read a document from \(format.rawValue) reply: \(reply.content.prefix(400))")
                    return nil
                }
                return insight
            } catch RemoteError.rejectedFormat {
                guard let fallback = format.next else { return nil }
                Self.log("\(base.host ?? key) refused \(format.rawValue); trying \(fallback.rawValue)")
                format = fallback
            } catch {
                // A single failure — a timeout, a context overflow, a model
                // being swapped out — must not poison the rest of the batch.
                Self.log("\(filename): \(Self.describe(error, base: base))")
                cached = nil
                return nil
            }
        }
    }

    /// What came back, beyond the text itself: a reply the server cut off is
    /// worth naming, because truncated JSON is indistinguishable from a model
    /// that simply answered badly.
    private struct Reply {
        var content: String
        var truncated: Bool
        var tokens: Int?
    }

    /// Set `DOCTOPUS_LLM_DEBUG=1` to see why an endpoint is not producing
    /// results. Off by default: this runs once per document.
    private static let debug = ProcessInfo.processInfo.environment["DOCTOPUS_LLM_DEBUG"] == "1"

    private static func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data(("doctopus/llm: " + message() + "\n").utf8))
    }

    private func complete(prompt: String, config: RemoteLLMConfig,
                          base: URL, format: ResponseFormat) async throws -> Reply {
        var body: [String: Any] = [
            "model": config.trimmedModel,
            "messages": [
                ["role": "system", "content": LLMPrompt.jsonInstructions],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.1,
            // Room for a reasoning model to think before it answers. The answer
            // itself is under a hundred tokens; a local model left unconstrained
            // can spend several hundred getting there, and a ceiling it runs
            // into produces truncated JSON rather than an error.
            "max_tokens": 4000,
            "stream": false,
        ]
        body["response_format"] = format.body

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, config)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data, format: format)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else { throw RemoteError.malformedResponse }

        // A reasoning model puts its trace either in a field of its own or
        // inline in the content. When the field is separate the content is
        // sometimes empty and the answer is in the trace, so fall back to it.
        var content = (message["content"] as? String) ?? ""
        if Self.jsonObject(in: content) == nil,
           let reasoning = message["reasoning_content"] as? String ?? message["reasoning"] as? String {
            content = reasoning
        }
        let usage = object["usage"] as? [String: Any]
        return Reply(content: content,
                     truncated: (choice["finish_reason"] as? String) == "length",
                     tokens: usage?["completion_tokens"] as? Int)
    }

    private func authorize(_ request: inout URLRequest, _ config: RemoteLLMConfig) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Errors

    private enum RemoteError: Error {
        case notConfigured
        case malformedResponse
        case rejectedFormat
        case http(Int, String?)
    }

    private static func validate(_ response: URLResponse, data: Data,
                                 format: ResponseFormat = .plain) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let detail = message(in: data)
        // A server refuses a response format it does not implement with a plain
        // 400 and no machine-readable marker, so the decision to step down the
        // ladder is made from what we asked for rather than from the wording.
        if format != .plain, http.statusCode == 400 {
            log("400 for \(format.rawValue): \(detail ?? "no detail")")
            throw RemoteError.rejectedFormat
        }
        throw RemoteError.http(http.statusCode, detail)
    }

    /// OpenAI-shaped errors carry `{"error": {"message": …}}`; llama.cpp and
    /// friends sometimes send a bare string. Take whichever is there.
    private static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8)?.nilIfBlank
        }
        if let error = object["error"] as? [String: Any], let m = error["message"] as? String { return m }
        if let error = object["error"] as? String { return error }
        return object["message"] as? String
    }

    private static func describe(_ error: Error, base: URL) -> String {
        let host = base.host ?? base.absoluteString
        if let remote = error as? RemoteError {
            switch remote {
            case .notConfigured:
                return "Enter the address of an OpenAI-compatible server"
            case .malformedResponse:
                return "\(host) answered with something that is not a chat completion"
            case .rejectedFormat:
                return "\(host) refused every response format offered"
            case .http(401, _), .http(403, _):
                return "\(host) rejected the API key"
            case .http(404, _):
                return "No API found at \(base.absoluteString) — check the path, most servers use /v1"
            case .http(let code, let detail):
                return detail.map { "\(host) said \(code): \($0)" } ?? "\(host) said HTTP \(code)"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost:
                let port = base.port.map { ":\($0)" } ?? ""
                return "Nothing is listening at \(host)\(port)"
            case .timedOut:
                return "\(host) did not answer in time"
            case .appTransportSecurityRequiresSecureConnection:
                return "macOS blocked the plain-HTTP connection to \(host)"
            default:
                break
            }
        }
        return (error as NSError).localizedDescription
    }

    // MARK: - Parsing

    /// Models are asked for bare JSON and usually oblige, but a code fence or a
    /// sentence of preamble is common enough that it is cheaper to tolerate
    /// than to re-prompt.
    static func parse(_ content: String) -> DocumentInsight? {
        guard let data = jsonObject(in: content),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = object[key] as? String, let clean = value.nilIfBlank { return clean }
            }
            return nil
        }

        var insight = DocumentInsight()
        insight.summary = string("summary")
        insight.correspondent = string("correspondent", "sender", "from")
        insight.docType = string("documentType", "document_type", "type", "category")
        insight.language = string("language", "lang").flatMap(languageCode)
        insight.intent = string("intent", "action")?.lowercased()
        insight.title = string("title")
        insight.tags = tags(object["tags"])
        insight.source = "remote"
        // The same weight the on-device backend claims: a model that answered
        // at all should not outrank or underrank the other one by provenance.
        insight.confidence = 0.9

        // A response where every field came back empty is a failure dressed up
        // as a success, and storing it would overwrite real heuristic findings.
        guard insight.summary != nil || insight.correspondent != nil
                || insight.docType != nil || insight.title != nil else { return nil }
        return insight
    }

    private static func tags(_ value: Any?) -> [String] {
        let raw: [String]
        switch value {
        case let list as [String]: raw = list
        case let list as [Any]: raw = list.compactMap { $0 as? String }
        case let text as String: raw = text.split(separator: ",").map(String.init)
        default: return []
        }
        return raw
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased() }
            .filter { !$0.isEmpty && $0.count < 32 }
    }

    /// Asked for a two-letter code, a model will sometimes answer "German" —
    /// and storing "germa" would put a nonsense value in the sidebar next to
    /// the real ones. Take the code, resolve a name to its code, or take
    /// nothing at all.
    private static func languageCode(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !clean.isEmpty, clean.allSatisfy({ $0.isLetter }) else { return nil }
        if clean.count == 2 { return clean }
        if clean.count == 3, let two = Locale.LanguageCode(clean).identifier(.alpha2)?.nilIfBlank {
            return two
        }
        // The name, in English or in the language itself.
        let english = Locale(identifier: "en_US_POSIX")
        for code in Locale.LanguageCode.isoLanguageCodes {
            guard let id = code.identifier(.alpha2) else { continue }
            if english.localizedString(forLanguageCode: id)?.lowercased() == clean
                || Locale(identifier: id).localizedString(forLanguageCode: id)?.lowercased() == clean {
                return id
            }
        }
        return nil
    }

    /// The first balanced object, so a fenced block, a chatty preamble or a
    /// thinking trace that reasons its way through braces of its own still
    /// leaves something parseable. Scanning for balance rather than taking the
    /// outermost braces matters once a trace is in the content: the last `}` in
    /// the reply is often not the one that closes the first `{`.
    static func jsonObject(in content: String) -> Data? {
        let chars = Array(content)
        let wanted = Set(LLMPrompt.fields.map(\.key) + ["tags"])
        var best: Data?
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false

        for i in chars.indices {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let s = start {
                    if let data = String(chars[s...i]).data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       !object.isEmpty {
                        // A trace often drafts an object before committing to
                        // one, so the answer is the last object rather than the
                        // first — but only an object carrying a field we asked
                        // for is allowed to displace an earlier candidate.
                        if best == nil || object.keys.contains(where: wanted.contains) {
                            best = data
                        }
                    }
                    start = nil
                }
            default: break
            }
        }
        return best
    }
}
