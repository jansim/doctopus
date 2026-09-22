import Foundation

/// Decides where a new document belongs: user rules first, then the derived
/// path. It only moves when the best candidate is a clear call — above the
/// threshold and not within `ambiguityMargin` of another. Destinations outside
/// the library are never candidates.
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

        var shouldMove: Bool { destination != nil }
    }

    static let ambiguityMargin = 0.05

    var rules: [Rule]
    var threshold: Double
    var derivedTemplate: String
    var root: URL
    var deriveWhenNoRule: Bool

    func evaluate(text: String, filename: String, findings: DocumentAnalyzer.Findings,
                  insight: DocumentInsight?, currentDirectory: URL) -> Decision {
        let correspondent = insight?.correspondent ?? findings.correspondent
        let docType = insight?.docType ?? findings.docType
        let quality = qualityFactor(findings, insight)

        var matched: [(rule: Rule, candidate: Candidate)] = []
        var outside: [String] = []
        for rule in rules where rule.enabled {
            let subject = Self.subject(for: rule.field, text: text, filename: filename,
                                       correspondent: correspondent, docType: docType)
            guard Self.matches(rule, in: subject) else { continue }
            let dest = expand(rule.destination, correspondent: correspondent,
                              docType: docType, date: findings.date)
            guard isInsideLibrary(dest) else { outside.append(rule.name); continue }
            let confidence = min(0.99, rule.weight * quality)
            matched.append((rule, Candidate(destination: dest, confidence: confidence, rule: rule.name,
                                            explanation: "Rule “\(rule.name)” matched \(Self.fieldLabel(rule.field))")))
        }

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

        var candidates = Self.deduplicated(matched.map(\.candidate) + (derived.map { [$0] } ?? []))

        guard let first = matched.first else {
            guard let derived else {
                let why = outside.isEmpty
                    ? "No rule matched and no correspondent was identified"
                    : "“\(outside[0])” matched but points outside the library, so nothing was moved"
                return Decision(destination: nil, confidence: findings.confidence, rule: "none",
                                tags: insight?.tags ?? [], explanation: why, candidates: candidates)
            }
            return decide(best: derived, runnerUp: nil, tags: insight?.tags ?? [], tagsFromRule: false,
                          candidates: candidates, currentDirectory: currentDirectory)
        }

        // Destination is winner-takes-all; tags are a union of all matching rules.
        var unionTags: [String] = []
        var seenTags = Set<String>()
        for m in matched {
            for tag in ruleTags(m.rule) {
                if seenTags.insert(tag.lowercased()).inserted {
                    unionTags.append(tag)
                }
            }
        }
        let setCorr = matched.compactMap(\.rule.setCorrespondent).first { !$0.isEmpty }
        let setType = matched.compactMap(\.rule.setDocType).first { !$0.isEmpty }

        let rival = matched.dropFirst()
            .map(\.candidate)
            .filter { $0.destination.standardizedFileURL != first.candidate.destination.standardizedFileURL }
            .max { $0.confidence < $1.confidence }
        let ambiguous = rival.map { $0.confidence >= first.candidate.confidence - Self.ambiguityMargin } ?? false
        if ambiguous, let rival, rival.confidence > first.candidate.confidence {
            candidates = Self.deduplicated([rival] + candidates)
        }
        return decide(best: first.candidate, runnerUp: ambiguous ? rival : nil,
                      tags: unionTags, tagsFromRule: true,
                      setCorrespondent: setCorr, setDocType: setType,
                      candidates: candidates, currentDirectory: currentDirectory)
    }

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

    private static func fieldLabel(_ field: String) -> String {
        switch field {
        case "filename": return "the filename"
        case "correspondent": return "the correspondent"
        case "type": return "the document type"
        default: return "the text"
        }
    }

    private func qualityFactor(_ f: DocumentAnalyzer.Findings, _ i: DocumentInsight?) -> Double {
        guard let i else { return 0.85 }
        var factor = 0.9
        if let a = i.correspondent?.lowercased(), let b = f.correspondent?.lowercased(),
           a.contains(b) || b.contains(a) { factor += 0.08 }
        if i.docType != nil, i.docType == f.docType { factor += 0.05 }
        return min(1.0, factor)
    }

    private func ruleTags(_ r: Rule) -> [String] {
        (r.tagNames ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func subject(for field: String, text: String, filename: String,
                        correspondent: String?, docType: String?) -> String {
        switch field {
        case "filename": return filename
        case "correspondent": return correspondent ?? ""
        case "type": return docType ?? ""
        default: return text + "\n" + filename
        }
    }

    /// Shared by the router and the editor's preview so the two never disagree.
    /// "Any word" matches at the start of a word: `\b…\b` misses German compounds.
    static func matches(_ rule: Rule, in subject: String) -> Bool {
        PatternMatcher.matches(rule.pattern, mode: rule.mode,
                               insensitive: rule.caseInsensitive, in: subject)
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

    static let starterRules: [Rule] = [
        Rule(id: 0, name: "Invoices", pattern: "invoice, rechnung, facture", field: "text",
             destination: "Finances/Invoices/{year}", tagNames: "invoice", weight: 0.92, enabled: true, priority: 100),
        Rule(id: 0, name: "Bank Statements", pattern: "kontoauszug, account statement, closing balance", field: "text",
             destination: "Finances/Statements/{year}", tagNames: "bank", weight: 0.9, enabled: true, priority: 90),
        Rule(id: 0, name: "Tax", pattern: "steuerbescheid, finanzamt, tax return, hmrc, irs", field: "text",
             destination: "Finances/Tax-{year}", tagNames: "tax", weight: 0.93, enabled: true, priority: 95),
        Rule(id: 0, name: "Insurance", pattern: "versicherungsschein, insurance policy, policy number", field: "text",
             destination: "Insurance/{correspondent}", tagNames: "insurance", weight: 0.88, enabled: true, priority: 80),
        Rule(id: 0, name: "Payslips", pattern: "gehaltsabrechnung, payslip, net pay", field: "text",
             destination: "Work/Payslips/{year}", tagNames: "payslip", weight: 0.9, enabled: true, priority: 85),
    ]
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
