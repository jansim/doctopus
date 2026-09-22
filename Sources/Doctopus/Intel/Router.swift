import Foundation

/// Decides where a new document belongs: user rules first, then the derived
/// path. A matching rule is certain, but rules naming different folders leave
/// the document for review, and the derived path has to clear the threshold.
/// Destinations outside the library are never candidates.
struct Router: Sendable {

    struct Candidate: Sendable, Equatable {
        var destination: URL
        var confidence: Double
        var rule: String
        var explanation: String
    }

    struct Decision: Sendable {
        var destination: URL?
        var confidence: Double
        var rule: String
        var tags: [String]
        var tagsFromRule: Bool = false
        var explanation: String
        var candidates: [Candidate] = []
        var ambiguous = false
        var setCorrespondent: String?
        var setDocType: String?
        var rename: String?

        var shouldMove: Bool { destination != nil }
    }

    var rules: [Rule]
    var threshold: Double
    var derivedTemplate: String
    var root: URL
    var deriveWhenNoRule: Bool

    func evaluate(text: String, filename: String, findings: DocumentAnalyzer.Findings,
                  insight: DocumentInsight?, currentDirectory: URL) -> Decision {
        let subject = Rule.Subject(text: text, filename: filename,
                                   correspondent: insight?.correspondent ?? findings.correspondent,
                                   docType: insight?.docType ?? findings.docType)
        return evaluate(subject, date: findings.date, confidence: findings.confidence,
                        derivedConfidence: findings.confidence * qualityFactor(findings, insight),
                        suggestedTags: insight?.tags ?? [], currentDirectory: currentDirectory)
    }

    /// The same decision from what is already on record, for a document whose
    /// fields or rules changed after it was read.
    func evaluate(_ subject: Rule.Subject, date: Date?, confidence: Double,
                  derivedConfidence: Double, suggestedTags: [String] = [],
                  currentDirectory: URL) -> Decision {
        let correspondent = subject.correspondent
        let docType = subject.docType

        var matched: [Rule] = []
        var ruleCandidates: [Candidate] = []
        var outside: [String] = []
        for rule in rules where rule.enabled && rule.hasEffect && rule.matches(subject) {
            matched.append(rule)
            guard let template = rule.destination else { continue }
            let dest = expand(template, correspondent: correspondent, docType: docType, date: date)
            guard isInsideLibrary(dest) else { outside.append(rule.name); continue }
            ruleCandidates.append(Candidate(destination: dest, confidence: 1, rule: rule.name,
                                            explanation: Self.why(rule, subject)))
        }

        var derived: Candidate?
        if deriveWhenNoRule, let correspondent, !correspondent.isEmpty {
            let dest = expand(derivedTemplate, correspondent: correspondent, docType: docType, date: date)
            if isInsideLibrary(dest), dest.standardizedFileURL != root.standardizedFileURL {
                derived = Candidate(destination: dest,
                                    confidence: derivedConfidence,
                                    rule: "derived",
                                    explanation: "Derived from correspondent “\(correspondent)”")
            }
        }

        // Tags are the union of every matching rule; single-valued actions take the first.
        var tags: [String] = []
        var seenTags = Set<String>()
        for rule in matched {
            for tag in rule.tagNames where seenTags.insert(tag.lowercased()).inserted {
                tags.append(tag)
            }
        }
        var decision = Decision(destination: nil, confidence: confidence,
                                rule: matched.first?.name ?? "none",
                                tags: matched.isEmpty ? suggestedTags : tags,
                                tagsFromRule: !matched.isEmpty,
                                explanation: "",
                                candidates: Self.deduplicated(ruleCandidates + (derived.map { [$0] } ?? [])),
                                setCorrespondent: matched.lazy.compactMap(\.setCorrespondent).first,
                                setDocType: matched.lazy.compactMap(\.setDocType).first,
                                rename: matched.lazy.compactMap(\.rename).first)

        let folders = Self.deduplicated(ruleCandidates)
        if let best = folders.first {
            decision.confidence = 1
            decision.rule = best.rule
            decision.explanation = best.explanation
            if folders.count > 1 {
                decision.ambiguous = true
                decision.explanation = "“\(folders[0].rule)” and “\(folders[1].rule)” file this in different places — left for you to choose"
            } else if best.destination.standardizedFileURL == currentDirectory.standardizedFileURL {
                decision.explanation = "Already in the right place"
            } else {
                decision.destination = best.destination
            }
            return decision
        }

        if let derived {
            decision.confidence = derived.confidence
            if matched.isEmpty { decision.rule = derived.rule }
            if derived.confidence < threshold {
                decision.explanation = "Would file under \(derived.destination.lastPathComponent), but confidence \(pct(derived.confidence)) is below \(pct(threshold))"
            } else if derived.destination.standardizedFileURL == currentDirectory.standardizedFileURL {
                decision.explanation = "Already in the right place"
            } else {
                decision.explanation = derived.explanation
                decision.destination = derived.destination
            }
            return decision
        }

        decision.explanation = if let first = outside.first {
            "“\(first)” matched but points outside the library, so nothing was moved"
        } else if let first = matched.first {
            "“\(first.name)” matched, but no rule moves this anywhere"
        } else {
            "No rule matched and no correspondent was identified"
        }
        return decision
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.destination.standardizedFileURL.path).inserted }
    }

    /// Routing may only move a file within its own library, and never into
    /// Doctopus's own storage. An absolute or `~` destination that leaves the
    /// root is refused rather than followed.
    func isInsideLibrary(_ url: URL) -> Bool {
        let path = Store.canonical(url.standardizedFileURL.path)
        let rootPath = Store.canonical(root.standardizedFileURL.path)
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        return !FileScanner.isInsideLibraryContainer(URL(fileURLWithPath: path))
    }

    private static func why(_ rule: Rule, _ subject: Rule.Subject) -> String {
        let live = rule.liveConditions
        let hits = live.filter { $0.matches(subject) }
        guard live.count > 1 else {
            return "Rule “\(rule.name)” matched \(live.first?.field.phrase ?? "the document")"
        }
        let where_ = Set(hits.map(\.field.phrase)).sorted().joined(separator: " and ")
        return rule.requiresAll
            ? "Rule “\(rule.name)” matched all \(live.count) conditions"
            : "Rule “\(rule.name)” matched \(hits.count) of \(live.count) conditions, on \(where_)"
    }

    private func qualityFactor(_ f: DocumentAnalyzer.Findings, _ i: DocumentInsight?) -> Double {
        guard let i else { return 0.85 }
        var factor = 0.9
        if let a = i.correspondent?.lowercased(), let b = f.correspondent?.lowercased(),
           a.contains(b) || b.contains(a) { factor += 0.08 }
        if i.docType != nil, i.docType == f.docType { factor += 0.05 }
        return min(1.0, factor)
    }

    enum PatternKind: Equatable {
        case empty
        case words([String])
        case phrase
        case regex
        case invalidRegex(String)
        case fuzzy([String])
    }

    static func kind(of pattern: String, mode: MatchMode = .anyWord) -> PatternKind {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return .empty }
        switch mode {
        case .anyWord, .allWords: return .words(PatternMatcher.words(in: p))
        case .exactPhrase: return .phrase
        case .fuzzy: return .fuzzy(PatternMatcher.words(in: p))
        case .regex:
            do {
                _ = try NSRegularExpression(pattern: p, options: [.caseInsensitive])
                return .regex
            } catch {
                return .invalidRegex((error as NSError).localizedDescription)
            }
        }
    }

    func expand(_ template: String, correspondent: String?, docType: String?, date: Date?) -> URL {
        let ctx = Naming.Context(date: date, correspondent: correspondent, title: nil,
                                 docType: docType, language: nil, counter: nil,
                                 originalStem: "Unfiled", ext: "")
        var path = template
        if path.hasPrefix("/") || path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: path)
        }
        let components = Naming.renderPath(path, ctx)
        return components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

extension String {
    func startsWithWord(_ needle: String) -> Bool {
        var searchStart = startIndex
        while let found = range(of: needle, range: searchStart..<endIndex) {
            if found.lowerBound == startIndex {
                return true
            }
            let before = self[index(before: found.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            searchStart = index(after: found.lowerBound)
        }
        return false
    }
}
