import Foundation

/// Decides where an unrouted import belongs on disk.
///
/// Two sources of truth, in order: explicit user rules, then a derived
/// correspondent/year path built from what was understood. Anything below the
/// confidence threshold stays put and lands in the queue as "Needs Review" —
/// the engine never silently moves a file it is unsure about.
struct Router: Sendable {

    struct Decision: Sendable {
        var destination: URL?
        var confidence: Double
        var rule: String
        var tags: [String]
        /// True when `tags` came from an explicit user rule; false when there
        /// was no matching rule and they fell back to the model's own
        /// suggestions, which still deserve a human's sign-off.
        var tagsFromRule: Bool = false
        var explanation: String

        var shouldMove: Bool { destination != nil }
    }

    var rules: [Rule]
    var threshold: Double
    var derivedTemplate: String   // e.g. "{correspondent}/{year}"
    var root: URL
    var deriveWhenNoRule: Bool

    func evaluate(text: String, filename: String, findings: DocumentAnalyzer.Findings,
                  insight: DocumentInsight?, currentDirectory: URL) -> Decision {
        let correspondent = insight?.correspondent ?? findings.correspondent
        let docType = insight?.docType ?? findings.docType

        for rule in rules where rule.enabled {
            let subject = Self.subject(for: rule.field, text: text, filename: filename,
                                       correspondent: correspondent, docType: docType)
            guard Self.matches(rule.pattern, in: subject) else { continue }

            let confidence = min(0.99, rule.weight * qualityFactor(findings, insight))
            guard confidence >= threshold else {
                return Decision(destination: nil, confidence: confidence, rule: rule.name,
                                tags: ruleTags(rule), tagsFromRule: true,
                                explanation: "Matched “\(rule.name)” but confidence \(pct(confidence)) is below the \(pct(threshold)) threshold")
            }
            let dest = expand(rule.destination, correspondent: correspondent,
                              docType: docType, date: findings.date)
            return Decision(destination: dest, confidence: confidence, rule: rule.name,
                            tags: ruleTags(rule), tagsFromRule: true,
                            explanation: "Rule “\(rule.name)” matched \(rule.field)")
        }

        guard deriveWhenNoRule, let correspondent, !correspondent.isEmpty else {
            return Decision(destination: nil, confidence: findings.confidence, rule: "none",
                            tags: insight?.tags ?? [],
                            explanation: "No rule matched and no correspondent was identified")
        }

        let confidence = findings.confidence * qualityFactor(findings, insight)
        let dest = expand(derivedTemplate, correspondent: correspondent,
                          docType: docType, date: findings.date)
        guard confidence >= threshold else {
            return Decision(destination: nil, confidence: confidence, rule: "derived",
                            tags: insight?.tags ?? [],
                            explanation: "Would file under \(dest.lastPathComponent), but confidence \(pct(confidence)) is below \(pct(threshold))")
        }
        if dest.path == currentDirectory.path {
            return Decision(destination: nil, confidence: confidence, rule: "derived",
                            tags: insight?.tags ?? [], explanation: "Already in the right place")
        }
        return Decision(destination: dest, confidence: confidence, rule: "derived",
                        tags: insight?.tags ?? [],
                        explanation: "Derived from correspondent “\(correspondent)”")
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
