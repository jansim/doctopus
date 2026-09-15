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

    /// Retrains models on approved library documents if the training set has changed.
    func trainIfNeeded(docs: [TrainingDoc], fingerprint: String) {
        guard fingerprint != lastFingerprint else { return }
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

        // 1. Train Correspondent Model
        var corrModel = Model()
        var corrVocab = Set<String>()
        for doc in docs {
            guard let c = doc.correspondent?.nilIfBlank else { continue }
            let tokens = tokenize(doc.text)
            guard !tokens.isEmpty else { continue }
            corrModel.totalDocuments += 1
            var stats = corrModel.classes[c] ?? ClassStats()
            stats.documentCount += 1
            for token in tokens {
                stats.wordCounts[token, default: 0] += 1
                stats.totalWords += 1
                corrVocab.insert(token)
            }
            corrModel.classes[c] = stats
        }
        corrModel.vocabularySize = corrVocab.count
        correspondentModel = corrModel.classes.count >= 2 ? corrModel : nil

        // 2. Train DocType Model
        var typeModel = Model()
        var typeVocab = Set<String>()
        for doc in docs {
            guard let t = doc.docType?.nilIfBlank else { continue }
            let tokens = tokenize(doc.text)
            guard !tokens.isEmpty else { continue }
            typeModel.totalDocuments += 1
            var stats = typeModel.classes[t] ?? ClassStats()
            stats.documentCount += 1
            for token in tokens {
                stats.wordCounts[token, default: 0] += 1
                stats.totalWords += 1
                typeVocab.insert(token)
            }
            typeModel.classes[t] = stats
        }
        typeModel.vocabularySize = typeVocab.count
        docTypeModel = typeModel.classes.count >= 2 ? typeModel : nil

        // 3. Train Multi-Label Tag Models
        var allTags = Set<String>()
        for doc in docs { for tag in doc.tags { allTags.insert(tag) } }

        var tModels: [String: Model] = [:]
        for tag in allTags {
            var tagModel = Model()
            var tagVocab = Set<String>()
            var posCount = 0
            var negCount = 0

            for doc in docs {
                let tokens = tokenize(doc.text)
                guard !tokens.isEmpty else { continue }
                let isPos = doc.tags.contains(tag)
                let label = isPos ? "pos" : "neg"
                if isPos { posCount += 1 } else { negCount += 1 }
                tagModel.totalDocuments += 1

                var stats = tagModel.classes[label] ?? ClassStats()
                stats.documentCount += 1
                for token in tokens {
                    stats.wordCounts[token, default: 0] += 1
                    stats.totalWords += 1
                    tagVocab.insert(token)
                }
                tagModel.classes[label] = stats
            }
            tagModel.vocabularySize = tagVocab.count
            if posCount >= 2 && negCount >= 1 {
                tModels[tag] = tagModel
            }
        }
        tagModels = tModels.isEmpty ? nil : tModels
    }

    func predictCorrespondent(text: String) -> Prediction? {
        guard let model = correspondentModel else { return nil }
        return predict(text: text, model: model)
    }

    func predictDocType(text: String) -> Prediction? {
        guard let model = docTypeModel else { return nil }
        return predict(text: text, model: model)
    }

    func predictTags(text: String) -> [Prediction] {
        guard let tagModels else { return [] }
        var out: [Prediction] = []
        for (tag, model) in tagModels {
            if let pred = predictBinary(text: text, model: model), pred.confidence >= confidenceThreshold {
                out.append(Prediction(label: tag, confidence: pred.confidence))
            }
        }
        return out.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Probability scoring

    private func predict(text: String, model: Model) -> Prediction? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty, !model.classes.isEmpty else { return nil }

        let totalDocs = Double(model.totalDocuments)
        let vocabSize = Double(max(1, model.vocabularySize))
        var logScores: [(classLabel: String, score: Double)] = []

        for (className, stats) in model.classes {
            guard stats.documentCount > 0 else { continue }
            var logProb = log(Double(stats.documentCount) / totalDocs)
            let totalWordsInClass = Double(stats.totalWords) + vocabSize

            for token in tokens {
                let count = Double(stats.wordCounts[token] ?? 0)
                logProb += log((count + 1.0) / totalWordsInClass)
            }
            logScores.append((className, logProb))
        }

        guard !logScores.isEmpty else { return nil }

        let maxLog = logScores.map(\.score).max() ?? 0
        let expScores = logScores.map { ($0.classLabel, exp($0.score - maxLog)) }
        let sumExp = expScores.map(\.1).reduce(0, +)
        guard sumExp > 0 else { return nil }

        let probs = expScores.map { ($0.0, $0.1 / sumExp) }
            .sorted { $0.1 > $1.1 }

        if let best = probs.first, best.1 >= confidenceThreshold {
            return Prediction(label: best.0, confidence: best.1)
        }
        return nil
    }

    private func predictBinary(text: String, model: Model) -> Prediction? {
        guard let posStats = model.classes["pos"], let negStats = model.classes["neg"],
              posStats.documentCount > 0, negStats.documentCount > 0 else { return nil }

        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }

        let totalDocs = Double(model.totalDocuments)
        let vocabSize = Double(max(1, model.vocabularySize))

        var posLog = log(Double(posStats.documentCount) / totalDocs)
        var negLog = log(Double(negStats.documentCount) / totalDocs)

        let posTotalWords = Double(posStats.totalWords) + vocabSize
        let negTotalWords = Double(negStats.totalWords) + vocabSize

        for token in tokens {
            let posCount = Double(posStats.wordCounts[token] ?? 0)
            let negCount = Double(negStats.wordCounts[token] ?? 0)
            posLog += log((posCount + 1.0) / posTotalWords)
            negLog += log((negCount + 1.0) / negTotalWords)
        }

        let maxLog = max(posLog, negLog)
        let posExp = exp(posLog - maxLog)
        let negExp = exp(negLog - maxLog)
        let probPos = posExp / (posExp + negExp)

        if probPos >= confidenceThreshold {
            return Prediction(label: "pos", confidence: probPos)
        }
        return nil
    }

    private func tokenize(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "this", "that", "from", "are", "was",
            "der", "die", "das", "und", "für", "fuer", "mit", "von", "ist", "ein", "eine"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }
}
