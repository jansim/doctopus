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

        // Every enabled rule that matches, in the order the user put them.
        var matched: [(rule: Rule, candidate: Candidate)] = []
        var outside: [String] = []
        for rule in rules where rule.enabled {
            let subject = Self.subject(for: rule.field, text: text, filename: filename,
                                       correspondent: correspondent, docType: docType)
            guard Self.matches(rule.pattern, in: subject) else { continue }
            let dest = expand(rule.destination, correspondent: correspondent,
                              docType: docType, date: findings.date)
            guard isInsideLibrary(dest) else { outside.append(rule.name); continue }
            let confidence = min(0.99, rule.weight * quality)
            matched.append((rule, Candidate(destination: dest, confidence: confidence, rule: rule.name,
                                            explanation: "Rule “\(rule.name)” matched \(Self.fieldLabel(rule.field))")))
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

        var candidates = Self.deduplicated(matched.map(\.candidate) + (derived.map { [$0] } ?? []))

        // No rule: the derived path, if there is one, decides on its own.
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

        // The first matching rule is the user's own choice of winner, unless a
        // later one — pointing somewhere else — fits about as well.
        let rival = matched.dropFirst()
            .map(\.candidate)
            .filter { $0.destination.standardizedFileURL != first.candidate.destination.standardizedFileURL }
            .max { $0.confidence < $1.confidence }
        let ambiguous = rival.map { $0.confidence >= first.candidate.confidence - Self.ambiguityMargin } ?? false
        if ambiguous, let rival, rival.confidence > first.candidate.confidence {
            // Offer the stronger of the two first.
            candidates = Self.deduplicated([rival] + candidates)
        }
        return decide(best: first.candidate, runnerUp: ambiguous ? rival : nil,
                      tags: ruleTags(first.rule), tagsFromRule: true,
                      candidates: candidates, currentDirectory: currentDirectory)
    }

    /// Turns the best candidate into a move — or, when it is not a clear
    /// enough call, into a document that stays put with its candidates.
    private func decide(best: Candidate, runnerUp: Candidate?, tags: [String], tagsFromRule: Bool,
                        candidates: [Candidate], currentDirectory: URL) -> Decision {
        var decision = Decision(destination: nil, confidence: best.confidence, rule: best.rule,
                                tags: tags, tagsFromRule: tagsFromRule, explanation: best.explanation,
                                candidates: candidates)
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

    private static func fieldLabel(_ field: String) -> String {
        switch field {
        case "filename": return "the filename"
        case "correspondent": return "the correspondent"
        case "type": return "the document type"
        default: return "the text"
        }
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

    private func ruleTags(_ r: Rule) -> [String] {
        (r.tagNames ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What a rule's `field` points it at. Lowercased, since word matching is
    /// case-insensitive; the rule editor's preview goes through here too, so
    /// it can never disagree with the router about what a rule sees.
    static func subject(for field: String, text: String, filename: String,
                        correspondent: String?, docType: String?) -> String {
        switch field {
        case "filename": return filename.lowercased()
        case "correspondent": return (correspondent ?? "").lowercased()
        case "type": return (docType ?? "").lowercased()
        default: return text.lowercased() + "\n" + filename.lowercased()
        }
    }

    /// How a pattern will be read. The router decides this silently, so the
    /// rule editor spells it out — a regex that does not compile falls back to
    /// plain words, which is rarely what whoever typed it meant.
    enum PatternKind: Equatable {
        case empty
        case words([String])
        case regex
        case invalidRegex(String)
    }

    static func kind(of pattern: String) -> PatternKind {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return .empty }
        if p.rangeOfCharacter(from: CharacterSet(charactersIn: "^$*+?[]()|\\")) != nil {
            do {
                _ = try NSRegularExpression(pattern: p, options: [.caseInsensitive])
                return .regex
            } catch {
                return .invalidRegex((error as NSError).localizedDescription)
            }
        }
        return .words(words(in: p))
    }

    private static func words(in pattern: String) -> [String] {
        pattern.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Substring match, or a real regex when the pattern looks like one.
    static func matches(_ pattern: String, in subject: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        if p.rangeOfCharacter(from: CharacterSet(charactersIn: "^$*+?[]()|\\")) != nil,
           let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
            return re.firstMatch(in: subject, range: NSRange(location: 0, length: (subject as NSString).length)) != nil
        }
        // Bare words are OR-ed, so "acme, globex" behaves the way people expect.
        // Matching is anchored to a word *start* rather than a plain substring:
        // that still catches "Rechnungsnummer" for the term "rechnung", but no
        // longer fires on "Gehaltsabrechnung", where the term is buried inside
        // an unrelated compound.
        return words(in: p).contains { subject.startsWithWord($0) }
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
        // Render each path component separately so empty tokens collapse cleanly.
        let components = path.split(separator: "/").map { Naming.render(String($0), ctx) }
            .filter { !$0.isEmpty && $0 != "Unfiled" }
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
