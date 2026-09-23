import Foundation

actor DocumentClassifier {
    struct Prediction: Sendable {
        var label: String
        var confidence: Double
    }

    struct Model: Sendable {
        var classes: [String: ClassStats] = [:]
        var totalDocuments: Int = 0
        var vocabularySize: Int = 0
    }

    struct ClassStats: Sendable {
        var documentCount: Int = 0
        var wordCounts: [String: Int] = [:]
        var totalWords: Int = 0
    }

    private var correspondentModel: Model?
    private var docTypeModel: Model?
    private var tagModels: [String: Model]?
    private var lastFingerprint: String?
    private let confidenceThreshold: Double

    init(confidenceThreshold: Double = 0.60) {
        self.confidenceThreshold = confidenceThreshold
    }

    func needsTraining(fingerprint: String) -> Bool { fingerprint != lastFingerprint }

    func trainIfNeeded(docs: [TrainingDoc], fingerprint: String) {
        guard needsTraining(fingerprint: fingerprint) else { return }
        train(docs: docs)
        lastFingerprint = fingerprint
    }

    func train(docs: [TrainingDoc]) {
        guard !docs.isEmpty else {
            correspondentModel = nil
            docTypeModel = nil
            tagModels = nil
            return
        }

        let corpus: [(doc: TrainingDoc, tokens: [String])] = docs.compactMap {
            let tokens = tokenize($0.text)
            return tokens.isEmpty ? nil : (doc: $0, tokens: tokens)
        }

        correspondentModel = Self.choosing(Self.fit(corpus, label: { $0.correspondent?.nilIfBlank }))
        docTypeModel = Self.choosing(Self.fit(corpus, label: { $0.docType?.nilIfBlank }))

        var tModels: [String: Model] = [:]
        for tag in Set(docs.flatMap(\.tags)) {
            guard let model = Self.fit(corpus, label: { $0.tags.contains(tag) ? "pos" : "neg" }),
                  (model.classes["pos"]?.documentCount ?? 0) >= 2,
                  (model.classes["neg"]?.documentCount ?? 0) >= 1
            else { continue }
            tModels[tag] = model
        }
        tagModels = tModels.isEmpty ? nil : tModels
    }

    private static func choosing(_ model: Model?) -> Model? {
        (model?.classes.count ?? 0) >= 2 ? model : nil
    }

    private static func fit(_ corpus: [(doc: TrainingDoc, tokens: [String])],
                            label: (TrainingDoc) -> String?) -> Model? {
        var model = Model()
        var vocabulary = Set<String>()
        for (doc, tokens) in corpus {
            guard let label = label(doc) else { continue }
            model.totalDocuments += 1
            var stats = model.classes[label] ?? ClassStats()
            stats.documentCount += 1
            for token in tokens {
                stats.wordCounts[token, default: 0] += 1
                stats.totalWords += 1
                vocabulary.insert(token)
            }
            model.classes[label] = stats
        }
        guard model.totalDocuments > 0 else { return nil }
        model.vocabularySize = vocabulary.count
        return model
    }

    func predictCorrespondent(text: String) -> Prediction? {
        correspondentModel.flatMap { predict(tokenize(text), $0) }
    }

    func predictDocType(text: String) -> Prediction? {
        docTypeModel.flatMap { predict(tokenize(text), $0) }
    }

    func predictTags(text: String) -> [Prediction] {
        guard let tagModels else { return [] }
        let tokens = tokenize(text)
        return tagModels
            .compactMap { tag, model in
                guard let pred = predict(tokens, model), pred.label == "pos" else { return nil }
                return Prediction(label: tag, confidence: pred.confidence)
            }
            .sorted { $0.confidence > $1.confidence }
    }

    private func predict(_ tokens: [String], _ model: Model) -> Prediction? {
        guard !tokens.isEmpty, model.totalDocuments > 0 else { return nil }
        let totalDocs = Double(model.totalDocuments)
        let vocabSize = Double(max(1, model.vocabularySize))

        var logScores: [(label: String, score: Double)] = []
        for (label, stats) in model.classes where stats.documentCount > 0 {
            var logProb = log(Double(stats.documentCount) / totalDocs)
            let totalWordsInClass = Double(stats.totalWords) + vocabSize
            for token in tokens {
                let count = Double(stats.wordCounts[token] ?? 0)
                logProb += log((count + 1.0) / totalWordsInClass)
            }
            logScores.append((label, logProb))
        }
        guard let maxLog = logScores.map(\.score).max() else { return nil }

        let weights = logScores.map { ($0.label, exp($0.score - maxLog)) }
        let sum = weights.reduce(0) { $0 + $1.1 }
        guard sum > 0, let best = weights.max(by: { $0.1 < $1.1 }) else { return nil }
        let probability = best.1 / sum
        guard probability >= confidenceThreshold else { return nil }
        return Prediction(label: best.0, confidence: probability)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "are", "was",
        "der", "die", "das", "und", "für", "fuer", "mit", "von", "ist", "ein", "eine",
    ]

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
    }
}

extension Store {

    struct ClassifierTrainingData: Sendable {
        var docs: [TrainingDoc]
        var fingerprint: String
    }

    func classifierTrainingFingerprint() throws -> String {
        let row = try db.first("""
            SELECT COUNT(*), COALESCE(MAX(mtime), 0)
            FROM documents
            WHERE missing=0 AND deleted_at IS NULL AND approved=1
            """) { (count: Int($0.int(0)), maxMtime: $0.double(1)) }
        return "\(row?.count ?? 0)-\(row?.maxMtime ?? 0)"
    }

    func classifierTrainingData() throws -> ClassifierTrainingData {
        let docs = try db.map("""
            SELECT d.id, ec.name, et.name,
                   (SELECT f.body FROM doc_fts f WHERE f.rowid = d.id),
                   d.mtime
            FROM documents d
            LEFT JOIN metadata m ON m.doc_id = d.id
            LEFT JOIN entities ec ON ec.id = m.correspondent_id
            LEFT JOIN entities et ON et.id = m.doc_type_id
            WHERE d.missing=0 AND d.deleted_at IS NULL AND d.approved=1
            """) {
            (id: $0.int(0), correspondent: $0.stringOrNil(1), docType: $0.stringOrNil(2),
             text: $0.stringOrNil(3) ?? "", mtime: $0.double(4))
        }

        let docIDs = docs.map(\.id)
        let tagMap = (try? tags(forDocuments: docIDs).own) ?? [:]

        var trainingDocs: [TrainingDoc] = []
        var maxMtime: Double = 0
        for doc in docs {
            let tNames = (tagMap[doc.id] ?? []).map(\.name)
            trainingDocs.append(TrainingDoc(
                id: doc.id, text: doc.text,
                correspondent: doc.correspondent, docType: doc.docType,
                tags: tNames
            ))
            if doc.mtime > maxMtime { maxMtime = doc.mtime }
        }

        let fingerprint = "\(trainingDocs.count)-\(maxMtime)"
        return ClassifierTrainingData(docs: trainingDocs, fingerprint: fingerprint)
    }
}
