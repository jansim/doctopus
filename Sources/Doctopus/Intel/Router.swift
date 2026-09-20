import Foundation

/// Decides where a new document belongs on disk.
///
/// Two sources of truth, in order: explicit user rules, then a derived
/// correspondent/year path built from what was understood. Every place that
/// fits is kept as a candidate, best first, and the document is only moved to
/// the best one when that is a clear call:
///
/// - below the confidence threshold it stays where it landed, and
/// - when another candidate fits about as well (within `ambiguityMargin`) it
///   stays too — two equally good homes is a question for a person, not a
///   coin toss.
///
/// Either way it lands in the queue as "Needs Review" with the candidates kept,
/// so choosing between them is one click. Destinations outside the library
/// are never candidates: routing only ever moves a file within its library.
struct Router: Sendable {

    /// One place a document could go, and why.
    struct Candidate: Sendable, Equatable {
        var destination: URL
        var confidence: Double
        /// The rule's name, or "derived".
        var rule: String
        var explanation: String
    }

    struct Decision: Sendable {
        /// Where to move the document; nil means it stays where it is.
        var destination: URL?
        var confidence: Double
        var rule: String
        var tags: [String]
        /// True when `tags` came from an explicit user rule; false when there
        /// was no matching rule and they fell back to the model's own
        /// suggestions, which still deserve a human's sign-off.
        var tagsFromRule: Bool = false
        var explanation: String
        /// Every place that fits, best first. Kept whether or not the
        /// document moved, so the review can offer the alternatives.
        var candidates: [Candidate] = []
        /// True when the best candidates were too close to call.
        var ambiguous = false
        var setCorrespondent: String?
        var setDocType: String?

        var shouldMove: Bool { destination != nil }
    }

    /// How close a runner-up has to be to the best candidate for the two to
    /// count as equally good.
    static let ambiguityMargin = 0.05

    var rules: [Rule]
    var threshold: Double
    var derivedTemplate: String   // e.g. "{correspondent}/{year}"
    var root: URL
    var deriveWhenNoRule: Bool

    func evaluate(text: String, filename: String, findings: DocumentAnalyzer.Findings,
                  insight: DocumentInsight?, currentDirectory: URL) -> Decision {
        let correspondent = insight?.correspondent ?? findings.correspondent
        let docType = insight?.docType ?? findings.docType
        let quality = qualityFactor(findings, insight)
        let subject = Rule.Subject(text: text, filename: filename,
                                   correspondent: correspondent, docType: docType)

        // Every enabled rule that matches, in the order the user put them. A
        // rule that only tags or only sets a correspondent matches like any
        // other; it simply has no folder to offer, so it never becomes a
        // candidate and never competes for the move.
        var matched: [Rule] = []
        var candidatesByRule: [(rule: Rule, candidate: Candidate)] = []
        var outside: [String] = []
        for rule in rules where rule.enabled && rule.hasEffect {
            guard rule.matches(subject) else { continue }
            matched.append(rule)
            guard let template = rule.destination else { continue }
            let dest = expand(template, correspondent: correspondent,
                              docType: docType, date: findings.date)
            guard isInsideLibrary(dest) else { outside.append(rule.name); continue }
            let confidence = min(0.99, rule.weight * quality)
            candidatesByRule.append((rule, Candidate(destination: dest, confidence: confidence, rule: rule.name,
                                                     explanation: Self.why(rule, subject))))
        }

        // The derived path is the fallback when no rule matches, and an extra
        // suggestion when one does.
        var derived: Candidate?
        if deriveWhenNoRule, let correspondent, !correspondent.isEmpty {
            let dest = expand(derivedTemplate, correspondent: correspondent,
                              docType: docType, date: findings.date)
            if isInsideLibrary(dest), dest.standardizedFileURL != root.standardizedFileURL {
                derived = Candidate(destination: dest, confidence: findings.confidence * quality,
                                    rule: "derived",
                                    explanation: "Derived from correspondent “\(correspondent)”")
            }
        }

        var candidates = Self.deduplicated(candidatesByRule.map(\.candidate) + (derived.map { [$0] } ?? []))

        // Destination is winner-takes-all; everything else is the union of
        // every rule that matched, whether or not it had a folder to offer.
        var unionTags: [String] = []
        var seenTags = Set<String>()
        for rule in matched {
            for tag in rule.tagNames where seenTags.insert(tag.lowercased()).inserted {
                unionTags.append(tag)
            }
        }
        let setCorr = matched.compactMap(\.setCorrespondent).first
        let setType = matched.compactMap(\.setDocType).first

        // Nothing to move it by: the derived path, if there is one, decides on
        // its own. Tags and metadata a matching rule asked for still apply.
        guard let first = candidatesByRule.first else {
            guard let derived else {
                let why = outside.isEmpty
                    ? (matched.isEmpty
                       ? "No rule matched and no correspondent was identified"
                       : "“\(matched[0].name)” matched, but no rule files this anywhere")
                    : "“\(outside[0])” matched but points outside the library, so nothing was moved"
                return Decision(destination: nil, confidence: findings.confidence,
                                rule: matched.first?.name ?? "none",
                                tags: matched.isEmpty ? (insight?.tags ?? []) : unionTags,
                                tagsFromRule: !matched.isEmpty,
                                explanation: why, candidates: candidates,
                                setCorrespondent: setCorr, setDocType: setType)
            }
            return decide(best: derived, runnerUp: nil,
                          tags: matched.isEmpty ? (insight?.tags ?? []) : unionTags,
                          tagsFromRule: !matched.isEmpty,
                          setCorrespondent: setCorr, setDocType: setType,
                          candidates: candidates, currentDirectory: currentDirectory)
        }

        // The first matching rule is the user's own choice of winner, unless a
        // later one — pointing somewhere else — fits about as well.
        let rival = candidatesByRule.dropFirst()
            .map(\.candidate)
            .filter { $0.destination.standardizedFileURL != first.candidate.destination.standardizedFileURL }
            .max { $0.confidence < $1.confidence }
        let ambiguous = rival.map { $0.confidence >= first.candidate.confidence - Self.ambiguityMargin } ?? false
        if ambiguous, let rival, rival.confidence > first.candidate.confidence {
            // Offer the stronger of the two first.
            candidates = Self.deduplicated([rival] + candidates)
        }
        return decide(best: first.candidate, runnerUp: ambiguous ? rival : nil,
                      tags: unionTags, tagsFromRule: true,
                      setCorrespondent: setCorr, setDocType: setType,
                      candidates: candidates, currentDirectory: currentDirectory)
    }

    /// Turns the best candidate into a move — or, when it is not a clear
    /// enough call, into a document that stays put with its candidates.
    private func decide(best: Candidate, runnerUp: Candidate?, tags: [String], tagsFromRule: Bool,
                        setCorrespondent: String? = nil, setDocType: String? = nil,
                        candidates: [Candidate], currentDirectory: URL) -> Decision {
        var decision = Decision(destination: nil, confidence: best.confidence, rule: best.rule,
                                tags: tags, tagsFromRule: tagsFromRule, explanation: best.explanation,
                                candidates: candidates, ambiguous: false,
                                setCorrespondent: setCorrespondent, setDocType: setDocType)
        if let runnerUp {
            decision.ambiguous = true
            decision.explanation = "“\(best.rule)” (\(pct(best.confidence))) and “\(runnerUp.rule)” (\(pct(runnerUp.confidence))) fit equally well — left for you to choose"
            return decision
        }
        guard best.confidence >= threshold else {
            decision.explanation = best.rule == "derived"
                ? "Would file under \(best.destination.lastPathComponent), but confidence \(pct(best.confidence)) is below \(pct(threshold))"
                : "Matched “\(best.rule)” but confidence \(pct(best.confidence)) is below the \(pct(threshold)) threshold"
            return decision
        }
        if best.destination.standardizedFileURL == currentDirectory.standardizedFileURL {
            decision.explanation = "Already in the right place"
            return decision
        }
        decision.destination = best.destination
        return decision
    }

    /// One candidate per folder, keeping the first (best) occurrence.
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

    /// Why a rule fired, in the words of the conditions that did it. With one
    /// condition that is the sentence it always was; with several, the review
    /// still has to be able to tell which of them the document tripped.
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

    /// The LLM agreeing with the heuristics is the strongest signal we have.
    private func qualityFactor(_ f: DocumentAnalyzer.Findings, _ i: DocumentInsight?) -> Double {
        guard let i else { return 0.85 }
        var factor = 0.9
        if let a = i.correspondent?.lowercased(), let b = f.correspondent?.lowercased(),
           a.contains(b) || b.contains(a) { factor += 0.08 }
        if i.docType != nil, i.docType == f.docType { factor += 0.05 }
        return min(1.0, factor)
    }

    /// What a pattern will do, for the editor to spell out.
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

    /// Where `template` would file a document with these attributes. Public so
    /// the rule editor can show a destination before any document takes it.
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
    /// True when `needle` occurs at the start of a word in the receiver.
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
