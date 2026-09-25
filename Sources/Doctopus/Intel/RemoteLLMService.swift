import Foundation

struct RemoteLLMConfig: Sendable, Equatable {
    var endpoint = "http://localhost:1234/v1"
    var model = ""
    var apiKey = ""
    var timeout: Double = 120
    var parallelRequests = 2
    var vision = false
    var visionImageSize = 1024

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

/// Any OpenAI-compatible chat completions server. Unlike the on-device backend
/// this sends document text off the machine, so it is never the default.
actor RemoteLLMService {
    private var cached: (config: RemoteLLMConfig, status: LLMStatus)?

    private var formats: [String: ResponseFormat] = [:]

    private var textOnly: Set<String> = []

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

        func body(_ question: LLMPrompt.Question) -> [String: Any]? {
            switch self {
            case .schema:
                return ["type": "json_schema",
                        "json_schema": ["name": "document_insight", "strict": true,
                                        "schema": question.jsonSchema]]
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

    func forget() {
        cached = nil
        textOnly.removeAll()
    }

    func status(_ config: RemoteLLMConfig) async -> LLMStatus {
        if let cached, cached.config == config { return cached.status }
        return await check(config)
    }

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
            if !names.isEmpty, !names.contains(config.trimmedModel) {
                return .unavailable("\(base.host ?? "The server") has no model named “\(config.trimmedModel)”")
            }
            return .ready("\(config.trimmedModel) at \(base.host ?? base.absoluteString)")
        } catch {
            return .unavailable(Self.describe(error, base: base))
        }
    }

    func models(_ config: RemoteLLMConfig) async -> [String] {
        (try? await fetchModels(config)) ?? []
    }

    private func fetchModels(_ config: RemoteLLMConfig) async throws -> [String] {
        guard let base = config.baseURL else { throw RemoteError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = min(config.timeout, 15)
        authorize(&request, config)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    func enrich(text: String, filename: String, question: LLMPrompt.Question = .init(),
                pageImage: PageImage.Rendered? = nil,
                pageCount: Int? = nil, config: RemoteLLMConfig, limit: Int,
                candidateTags: [String] = [], examples: [FilingExample] = []) async -> DocumentInsight? {
        guard let base = config.baseURL, config.isConfigured else { return nil }
        let key = base.absoluteString
        let imageKey = "\(key)|\(config.trimmedModel)"
        var image = textOnly.contains(imageKey) ? nil : pageImage
        var format = formats[key] ?? .schema

        while true {
            let prompt = LLMPrompt.user(text: text, filename: filename, limit: limit,
                                        candidateTags: candidateTags, pageCount: pageCount,
                                        hasPageImage: image != nil,
                                        examples: examples, fields: question.fields)
            do {
                let reply = try await complete(prompt: prompt, question: question, image: image,
                                               config: config, base: base, format: format)
                // Remembered only once it has actually answered, so a 400 for
                // some unrelated reason cannot talk us out of a format the
                // server does support.
                formats[key] = format
                if reply.truncated {
                    Self.log("\(filename): the reply was cut off at \(reply.tokens ?? 0) tokens")
                }
                guard let insight = Self.parse(reply.content, fields: question.fields,
                                               model: config.trimmedModel,
                                               vision: image != nil) else {
                    Self.log("\(filename): could not read a document from \(format.rawValue) reply: \(reply.content.prefix(400))")
                    return nil
                }
                return insight
            } catch RemoteError.rejectedImage {
                textOnly.insert(imageKey)
                Self.log("\(base.host ?? key) would not take a page image; asking again with text alone")
                image = nil
            } catch RemoteError.rejectedFormat {
                guard let fallback = format.next else {
                    guard image != nil else { return nil }
                    textOnly.insert(imageKey)
                    Self.log("\(base.host ?? key) refused every format with a page image attached; asking again with text alone")
                    image = nil
                    format = formats[key] ?? .schema
                    continue
                }
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

    private struct Reply {
        var content: String
        var truncated: Bool
        var tokens: Int?
    }

    private static let debug = ProcessInfo.processInfo.environment["DOCTOPUS_LLM_DEBUG"] == "1"

    private static func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data(("doctopus/llm: " + message() + "\n").utf8))
    }

    static func userMessage(prompt: String, image: PageImage.Rendered?) -> [String: Any] {
        guard let image else { return ["role": "user", "content": prompt] }
        let parts: [[String: Any]] = [
            ["type": "text", "text": prompt],
            ["type": "image_url", "image_url": ["url": image.dataURL]],
        ]
        return ["role": "user", "content": parts]
    }

    private func complete(prompt: String, question: LLMPrompt.Question, image: PageImage.Rendered?,
                          config: RemoteLLMConfig, base: URL,
                          format: ResponseFormat) async throws -> Reply {
        let messages: [[String: Any]] = [
            ["role": "system", "content": question.instructions(withPageImage: image != nil)],
            Self.userMessage(prompt: prompt, image: image),
        ]
        var body: [String: Any] = [
            "model": config.trimmedModel,
            "messages": messages,
            "temperature": 0.1,
            // Room for a reasoning model to think before it answers. The answer
            // itself is under a hundred tokens; a local model left unconstrained
            // can spend several hundred getting there, and a ceiling it runs
            // into produces truncated JSON rather than an error.
            "max_tokens": 4000,
            "stream": false,
        ]
        body["response_format"] = format.body(question)

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, config)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data, format: format, hasImage: image != nil)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else { throw RemoteError.malformedResponse }

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

    private enum RemoteError: Error {
        case notConfigured
        case malformedResponse
        case rejectedFormat
        case rejectedImage
        case http(Int, String?)
    }

    private static func validate(_ response: URLResponse, data: Data,
                                 format: ResponseFormat = .plain, hasImage: Bool = false) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let detail = message(in: data)
        if hasImage, mentionsImage(detail) {
            log("\(http.statusCode) for a request with a page image: \(detail ?? "no detail")")
            throw RemoteError.rejectedImage
        }
        if format != .plain, http.statusCode == 400 {
            log("400 for \(format.rawValue): \(detail ?? "no detail")")
            throw RemoteError.rejectedFormat
        }
        throw RemoteError.http(http.statusCode, detail)
    }

    private static func mentionsImage(_ detail: String?) -> Bool {
        guard let detail = detail?.lowercased() else { return false }
        return ["image", "vision", "multimodal", "multi-modal"].contains { detail.contains($0) }
    }

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
            case .rejectedImage:
                return "\(host) will not take a page image — turn the page image off, or point it at a vision model"
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

    /// Also reads the on-device backend's JSON, so both clean up a reply the same way.
    static func parse(_ content: String, fields: Set<InsightField> = Set(InsightField.allCases),
                      model: String? = nil, vision: Bool = false) -> DocumentInsight? {
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
        let modelPart = model.flatMap { $0.nilIfBlank }.map { ":\($0)" } ?? ""
        insight.source = "\(vision ? "vlm" : "remote")\(modelPart):v\(MetadataSource.promptVersion)"

        insight = insight.keeping(fields)
        // A response where every field came back empty is a failure dressed up
        // as a success, and storing it would overwrite real heuristic findings.
        guard insight.summary != nil || insight.correspondent != nil
                || insight.docType != nil || insight.title != nil
                || insight.language != nil || insight.intent != nil
                || !insight.tags.isEmpty else { return nil }
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

    private static func languageCode(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !clean.isEmpty, clean.allSatisfy({ $0.isLetter }) else { return nil }
        if clean.count == 2 { return clean }
        if clean.count == 3, let two = Locale.LanguageCode(clean).identifier(.alpha2)?.nilIfBlank {
            return two
        }
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

    /// The first balanced object, not the outermost braces: in a thinking trace the
    /// last `}` is often not the one that closes the first `{`.
    static func jsonObject(in content: String) -> Data? {
        let chars = Array(content)
        let wanted = Set(InsightField.allCases.map(\.rawValue))
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

extension AppSettings {
    var remoteConfig: RemoteLLMConfig {
        let s = appWide
        return RemoteLLMConfig(endpoint: s.remoteEndpoint, model: s.remoteModel, apiKey: s.remoteAPIKey,
                               timeout: s.remoteTimeout, parallelRequests: s.remoteParallelRequests,
                               vision: s.remoteVision, visionImageSize: s.remoteVisionImageSize)
    }

    var sendsPageImage: Bool { appWide.llmBackend == .remote && appWide.remoteVision }
}
