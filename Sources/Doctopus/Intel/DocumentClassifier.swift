import Foundation

/// Fast on-device Multinomial Naive Bayes classifier trained on the library's
/// approved documents.
///
/// Runs entirely in memory, needs no external model or network, and predicts
/// correspondent, document type, and tags with a confidence threshold below
/// which it abstains.
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

    struct TrainingDoc: Sendable {
        var id: Int64
        var text: String
        var correspondent: String?
        var docType: String?
        var tags: [String]
    }

    /// Whether `fingerprint` differs from the one the models were trained on,
    /// so a caller can skip assembling a corpus that would change nothing.
    func needsTraining(fingerprint: String) -> Bool { fingerprint != lastFingerprint }

    /// Retrains models on approved library documents if the training set has changed.
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

        // Tokenizing is by far the expensive part and all three models below
        // want the same tokens, so each document is tokenized once here rather
        // than twice plus once more for every tag in the library.
        let corpus: [(doc: TrainingDoc, tokens: [String])] = docs.compactMap {
            let tokens = tokenize($0.text)
            return tokens.isEmpty ? nil : (doc: $0, tokens: tokens)
        }

        // A correspondent or a type is one class per value, and needs two
        // values before it can choose between them.
        correspondentModel = Self.choosing(Self.fit(corpus, label: { $0.correspondent?.nilIfBlank }))
        docTypeModel = Self.choosing(Self.fit(corpus, label: { $0.docType?.nilIfBlank }))

        // A tag is one yes/no model each: every document is an example, either
        // for the tag or against it.
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

    /// A model with only one class has nothing to choose between, so it is no
    /// model at all.
    private static func choosing(_ model: Model?) -> Model? {
        (model?.classes.count ?? 0) >= 2 ? model : nil
    }

    /// Counts one model's classes over the corpus. Documents the label says
    /// nothing about are left out of it entirely.
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

    /// Every tag whose own model says yes. One tokenization for the lot: there
    /// is a model per tag in the library, and they all read the same words.
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

    // MARK: - Probability scoring

    /// The likeliest class, when it clears the confidence threshold. Scores are
    /// compared in log space and normalised against the highest of them, so a
    /// long document cannot underflow every class to zero.
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
