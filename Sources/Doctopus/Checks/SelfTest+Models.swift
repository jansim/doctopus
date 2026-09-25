import Foundation

/// The language models: what is asked of them, and how an answer is read.
extension SelfTest {
    static func metadataSource() {
        print("\nMETADATA SOURCE")
        Check.that("an on-device analysis is labelled as one",
                   MetadataSource("llm:v\(MetadataSource.promptVersion)").label == "On-device model")
        Check.that("an API analysis is labelled as one, whatever its version",
                   MetadataSource("remote:v9").label == "API model")
        Check.that("a model name is read back out of the source",
                   MetadataSource("remote:llama3:8b:v2").model == "llama3:8b")
        Check.that("a source with no model names none",
                   MetadataSource("remote:v2").model == nil)
        Check.that("anything else is heuristics",
                   MetadataSource("heuristic").label == "Heuristics")
    }

    static func endpoints() {
        print("\nMODEL BACKENDS")
        let pasted = [
            "http://localhost:1234": "http://localhost:1234/v1",
            "http://localhost:1234/": "http://localhost:1234/v1",
            "http://localhost:1234/v1": "http://localhost:1234/v1",
            "http://localhost:1234/v1/chat/completions": "http://localhost:1234/v1",
            "localhost:11434/v1": "http://localhost:11434/v1",
        ]
        var normalized = true
        for (input, expected) in pasted.sorted(by: { $0.key < $1.key }) {
            let got = RemoteLLMConfig(endpoint: input).baseURL?.absoluteString
            if got != expected { normalized = false }
            print("  \(input.padded(46)) → \(got ?? "nothing")")
        }
        Check.that("an endpoint is normalized however it was pasted", normalized)
        Check.that("an empty endpoint is not a URL", RemoteLLMConfig(endpoint: " ").baseURL == nil)
    }

    static func replies(indexer: Indexer, settings: AppSettings, rows: [DocumentRow]) async {
        let fenced = """
        Here you go:
        ```json
        {"summary": "A gas bill.", "correspondent": "Stadtwerke", "documentType": "Invoice",
         "language": "DE", "intent": "Pay", "title": "Gas bill", "tags": ["utilities", "#GAS"]}
        ```
        """
        let parsed = RemoteLLMService.parse(fenced)
        print("  parsed: \(parsed?.docType ?? "—") · \(parsed?.correspondent ?? "—") · \(parsed.map { $0.tags.joined(separator: ", ") } ?? "")")
        Check.that("a fenced, chatty JSON reply still parses",
                   parsed?.correspondent == "Stadtwerke" && parsed?.docType == "Invoice"
                       && parsed?.language == "de" && parsed?.intent == "pay"
                       && parsed?.tags == ["utilities", "gas"] && parsed?.source.hasPrefix("remote") == true)
        Check.that("a reply with nothing in it is a failure, not empty metadata",
                   RemoteLLMService.parse("{\"summary\": \"\", \"tags\": []}") == nil)
        Check.that("prose with no JSON in it is a failure",
                   RemoteLLMService.parse("I could not read that document.") == nil)

        let thinking = """
        <think>
        Let me draft this: {"summary": "unsure", "title": ""} — no, that is wrong,
        the letterhead says Northwind. The braces above should not be my answer.
        </think>
        {"summary": "An insurance policy renewal.", "correspondent": "Northwind Insurance Ltd",
         "documentType": "Insurance", "language": "German", "intent": "file",
         "title": "Policy renewal", "tags": ["insurance"]}
        """
        let thought = RemoteLLMService.parse(thinking)
        print("  through a thinking trace: \(thought?.correspondent ?? "—") · \(thought?.language ?? "—")")
        Check.that("a thinking trace in the content does not become the answer",
                   thought?.correspondent == "Northwind Insurance Ltd"
                       && thought?.title == "Policy renewal")
        Check.that("a language given by name is stored as its code", thought?.language == "de")
        Check.that("a language that is neither is dropped",
                   RemoteLLMService.parse(#"{"title": "T", "language": "Klingon-ish"}"#)?.language == nil)

        var noModel = settings
        noModel.llmBackend = .off
        await indexer.update(settings: noModel)
        let blocked = await indexer.analyze(ids: rows.map(\.doc))
        print("  analyze with no backend: \(blocked.blocked ?? "ran anyway")")
        Check.that("a manual run with no model reports why", blocked.blocked != nil)

        let trimmed = parsed?.keeping([.summary, .correspondent])
        Check.that("only the fields asked for are kept from an answer",
                   trimmed?.summary == "A gas bill." && trimmed?.correspondent == "Stadtwerke"
                       && trimmed?.title == nil && trimmed?.docType == nil && trimmed?.language == nil
                       && trimmed?.intent == nil && trimmed?.tags.isEmpty == true)

        var nothingAsked = settings
        nothingAsked.llmBackend = .onDevice
        nothingAsked.predictedFields = []
        Check.that("switched-off fields survive being stored",
                   nothingAsked.appWide.unpredictedFields.count == InsightField.allCases.count
                       && AppWideSettings.decoded(from: (try? JSONEncoder().encode(nothingAsked.appWide)) ?? Data())
                           .predictedFields.isEmpty)
        Check.that("a stored field name that no longer exists is ignored",
                   AppWideSettings.decoded(from: Data(#"{"unpredictedFields": ["horoscope", "tags"]}"#.utf8))
                       .predictedFields == Set(InsightField.allCases).subtracting([.tags]))
        await indexer.update(settings: nothingAsked)
        let nothingToAsk = await indexer.analyze(ids: rows.map(\.doc))
        Check.that("a manual run with every field off reports why",
                   nothingToAsk.blocked?.contains("switched off") == true)
        await indexer.update(settings: noModel)
    }

    static func prompts() {
        let testPrompt = LLMPrompt.user(text: "Sample Document", filename: "invoice.pdf", limit: 1000, candidateTags: ["finances", "invoices"])
        Check.that("prompt includes untrusted user data marker", testPrompt.contains("untrusted user data"))
        Check.that("prompt includes candidate taxonomy tags", testPrompt.contains("finances, invoices"))
        Check.that("a page image is only spoken of when one is attached",
                   !testPrompt.contains("attached image"))

        let visionPrompt = LLMPrompt.user(text: "Sample Document", filename: "invoice.pdf", limit: 1000,
                                          pageCount: 12, hasPageImage: true)
        Check.that("prompt states how many pages the document has", visionPrompt.contains("Pages: 12"))
        Check.that("prompt says the attached image is the document's first page",
                   visionPrompt.contains("first page of the document"))
        Check.that("the system message tells a vision model to read the page too",
                   LLMPrompt.Question().instructions(withPageImage: true).contains("page image")
                       && !LLMPrompt.Question().instructions().contains("page image"))
        Check.that("the system message asks for the document's own language",
                   LLMPrompt.Question().instructions().contains("language the document"))

        let everything = LLMPrompt.Question().instructions()
        let tagsOnly = LLMPrompt.Question(fields: [.tags]).instructions()
        print("  tags-only prompt: \(tagsOnly.count) of \(everything.count) characters")
        Check.that("the prompt only asks for the fields that are switched on",
                   tagsOnly.contains("\"tags\":") && !tagsOnly.contains("\"summary\":")
                       && !tagsOnly.contains("\"title\":") && everything.contains("\"summary\":"))
        Check.that("a rendered prompt carries no template tags and no gaps where fields were",
                   !tagsOnly.contains("{{") && !everything.contains("{{")
                       && !tagsOnly.contains("\n\n\n") && everything.contains("Keys:\n\"summary\":"))
        Check.that("a field left out does not leave its mention in the closing line",
                   !LLMPrompt.Question(fields: [.title]).instructions().contains("[] for no tags"))
        Check.that("a broken template still renders instead of failing",
                   PromptTemplate.render("a {{#x}}b {{name}}", flags: ["x"]) == "a b {{name}}"
                       && PromptTemplate.render("a {{^x}}b", flags: ["x"]) == "a ")
        let schema = LLMPrompt.Question(fields: [.title, .tags]).jsonSchema
        Check.that("the response schema holds exactly the fields asked for",
                   (schema["required"] as? [String]) == ["title", "tags"]
                       && (schema["properties"] as? [String: Any])?.count == 2)
        Check.that("an answer to a tags-only question is not mistaken for an empty one",
                   RemoteLLMService.parse(#"{"tags": ["gas"]}"#, fields: [.tags])?.tags == ["gas"])
    }

    static func pageImages(store: Store) async {
        let pdfs = (try? await store.listDocuments(selection: .all, query: SearchQuery("ext:pdf"),
                                                   sort: .added, ascending: false)) ?? []
        if let pdf = pdfs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let rendered = PageImage.firstPage(of: pdf.url, maxDimension: 768)
            print("  page image: " + (rendered.map { "\($0.width)×\($0.height), \($0.kilobytes) KB, \($0.pageCount ?? 0) page(s)" } ?? "none"))
            Check.that("the first page of a PDF renders as a JPEG",
                       rendered?.jpeg.starts(with: [0xFF, 0xD8, 0xFF]) == true)
            Check.that("the rendered page fits the size it was asked for",
                       rendered.map { max($0.width, $0.height) <= 768 } ?? false,
                       rendered.map { "\($0.width)×\($0.height)" } ?? "—")
            Check.that("rendering the page also counts the document's pages",
                       (rendered?.pageCount ?? 0) >= 1)
            Check.that("the page travels as an inline data URL",
                       rendered?.dataURL.hasPrefix("data:image/jpeg;base64,") == true)
        } else {
            Check.that("a PDF fixture is there to render a page from", false)
        }

        let stubPage = PageImage.Rendered(jpeg: Data([0xFF, 0xD8, 0xFF]), width: 8, height: 8, pageCount: 3)
        let withImage = RemoteLLMService.userMessage(prompt: "prompt", image: stubPage)
        let parts = withImage["content"] as? [[String: Any]]
        Check.that("a page image travels beside the text as an image_url part",
                   parts?.count == 2 && parts?.first?["type"] as? String == "text"
                       && parts?.last?["type"] as? String == "image_url")
        Check.that("the image part carries the page inline",
                   ((parts?.last?["image_url"] as? [String: Any])?["url"] as? String)?
                       .hasPrefix("data:image/jpeg;base64,") == true)
        Check.that("with no image the user turn stays the plain string it always was",
                   RemoteLLMService.userMessage(prompt: "prompt", image: nil)["content"] as? String == "prompt")

        let visionSource = RemoteLLMService.parse(#"{"title": "T"}"#, model: "qwen2.5-vl", vision: true)?.source
        Check.that("what a vision model answered is stored as its own source",
                   visionSource == "vlm:qwen2.5-vl:v\(MetadataSource.promptVersion)", visionSource ?? "—")
        Check.that("a vision answer reads back as an API model that saw the page",
                   MetadataSource(visionSource ?? "") == .remote(model: "qwen2.5-vl", vision: true))
        Check.that("a vision answer is not stale under the current prompt",
                   !(visionSource ?? "").isEmpty
                       && (visionSource ?? "").hasSuffix(":v\(MetadataSource.promptVersion)"))

        let staleHits = (try? await store.listDocuments(selection: .all, query: SearchQuery("is:stale-analysis"), sort: .added, ascending: false)) ?? []
        Check.that("is:stale-analysis returns heuristic documents needing model analysis", !staleHits.isEmpty)
    }

    static func liveModel(store: Store, indexer: Indexer, intelligence: Intelligence, settings: AppSettings,
                          rows: [DocumentRow]) async {
        // A live run against a real server, when one is pointed at. This is how
        // a configuration is verified without the UI:
        //   DOCTOPUS_LLM_ENDPOINT=http://localhost:1234/v1 DOCTOPUS_LLM_MODEL=… --selftest …
        let env = ProcessInfo.processInfo.environment
        if let endpoint = env["DOCTOPUS_LLM_ENDPOINT"]?.nilIfBlank {
            print("\nLIVE MODEL (\(endpoint))")
            var live = settings
            live.llmBackend = .remote
            live.remoteEndpoint = endpoint
            live.remoteModel = env["DOCTOPUS_LLM_MODEL"] ?? ""
            live.remoteAPIKey = env["DOCTOPUS_LLM_API_KEY"] ?? ""
            live.remoteTimeout = 60
            live.remoteVision = env["DOCTOPUS_LLM_VISION"] == "1"
            await intelligence.update(settings: live)

            let offered = await intelligence.models(live.remoteConfig)
            print("  models: \(offered.isEmpty ? "none listed" : offered.joined(separator: ", "))")
            if live.remoteModel.isEmpty, let first = offered.first { live.remoteModel = first }
            await intelligence.update(settings: live)

            let reachable = await intelligence.refreshStatus()
            print("  status: \(reachable.label)")
            Check.that("the configured endpoint is reachable", reachable.isReady, reachable.label)

            await indexer.update(settings: live)
            let subject = Array(rows.prefix(2).map(\.doc))
            let run = await indexer.analyze(ids: subject)
            print("  analyzed \(run.updated), skipped \(run.skipped), failed \(run.failed)"
                  + (run.blocked.map { " — blocked: \($0)" } ?? ""))
            Check.that("the manual run enriched documents over the API",
                       run.updated == subject.count && run.blocked == nil)

            var enriched: [DocumentDetail] = []
            for id in subject {
                if let d = try? await store.detail(id) { enriched.append(d) }
            }
            for d in enriched {
                print("  \(d.row.filename.padded(40)) \(d.metadataSource ?? "—")  \(d.row.summary ?? "no summary")")
            }
            Check.that("what the API returned is stored as its own source",
                       !enriched.isEmpty && enriched.allSatisfy {
                           if case .remote = MetadataSource($0.metadataSource ?? "") { return $0.row.summary != nil }
                           return false
                       })
        }
    }

    static func localClassifier() async {
        print("\nLOCAL CLASSIFIER")
        let classifier = DocumentClassifier(confidenceThreshold: 0.5)
        let sampleDocs = [
            TrainingDoc(id: 1, text: "Rechnung Stadtwerke München Gas Strom Energie Abrechnung", correspondent: "Stadtwerke München", docType: "Invoice", tags: ["utilities", "bills"]),
            TrainingDoc(id: 2, text: "Stadtwerke München Jahresabrechnung Strom Erdgas", correspondent: "Stadtwerke München", docType: "Invoice", tags: ["utilities", "bills"]),
            TrainingDoc(id: 3, text: "Deutsche Bank Kontoauszug Finanzstatus Saldo Überweisung", correspondent: "Deutsche Bank AG", docType: "Bank Statement", tags: ["finance"]),
            TrainingDoc(id: 4, text: "Kontoauszug Deutsche Bank Girokonto Buchung", correspondent: "Deutsche Bank AG", docType: "Bank Statement", tags: ["finance"])
        ]
        await classifier.train(docs: sampleDocs)
        let predCorr = await classifier.predictCorrespondent(text: "Stadtwerke München Abschlagszahlung Gas")
        let predType = await classifier.predictDocType(text: "Deutsche Bank Auszug Buchungsbestätigung")
        let predTags = await classifier.predictTags(text: "Rechnung Strom Energie")
        Check.that("classifier predicts correspondent on matching vocabulary", predCorr?.label == "Stadtwerke München")
        Check.that("classifier predicts doc_type on matching vocabulary", predType?.label == "Bank Statement")
        Check.that("classifier predicts multi-label tags", predTags.contains { $0.label == "utilities" || $0.label == "bills" })
    }
}
