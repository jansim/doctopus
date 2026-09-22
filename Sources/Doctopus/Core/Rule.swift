import Foundation

/// A filing rule: one or more conditions, and one or more things to do to a
/// document that satisfies them. Deliberately no more than that — no branching,
/// no rule calling another — the way a mail filter is.
struct Rule: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var enabled: Bool = true
    /// Higher runs first.
    var priority: Int64 = 0
    var requiresAll: Bool = false
    var conditions: [RuleCondition] = []
    var actions: [RuleAction] = []

    /// Everything a condition can look at. The router, the editor's preview and
    /// Apply to Existing all build one, so they cannot disagree about a match.
    struct Subject: Sendable {
        var text: String = ""
        var filename: String = ""
        var correspondent: String?
        var docType: String?

        func value(for field: RuleField) -> String {
            switch field {
            case .text: return text + "\n" + filename
            case .filename: return filename
            case .correspondent: return correspondent ?? ""
            case .type: return docType ?? ""
            }
        }
    }

    /// Conditions with nothing to match are skipped rather than treated as
    /// matching everything, so a half-typed one can never widen a rule.
    var liveConditions: [RuleCondition] {
        conditions.filter { $0.pattern.nilIfBlank != nil }
    }

    func matches(_ subject: Subject) -> Bool {
        let live = liveConditions
        guard !live.isEmpty else { return false }
        return requiresAll
            ? live.allSatisfy { $0.matches(subject) }
            : live.contains { $0.matches(subject) }
    }

    // MARK: - Actions

    func action(_ kind: RuleActionKind) -> String? {
        actions.first { $0.kind == kind }?.value.nilIfBlank
    }

    /// Where the rule moves a document, as a path template.
    var destination: String? { action(.moveFile) }
    /// A naming template.
    var rename: String? { action(.renameFile) }
    var setCorrespondent: String? { action(.setCorrespondent) }
    var setDocType: String? { action(.setDocType) }

    var tagNames: [String] {
        (action(.addTags) ?? "").split(separator: ",")
            .compactMap { $0.trimmingCharacters(in: .whitespaces).nilIfBlank }
    }

    /// A rule with no action is a rule that does nothing, which the editor
    /// refuses to save and the router skips.
    var hasEffect: Bool { actions.contains { $0.value.nilIfBlank != nil } }

    // MARK: - How it reads in a list

    /// The first condition, and how many more there are and how they join.
    var conditionSummary: String {
        let live = liveConditions
        guard let first = live.first else { return "—" }
        let lead = (first.negated ? "not " : "") + first.pattern
        guard live.count > 1 else { return lead }
        return "\(lead) + \(live.count - 1) more (\(requiresAll ? "all" : "any"))"
    }

    var actionSummary: String {
        actions.compactMap { action in
            action.value.nilIfBlank.map { action.kind.summaryPrefix + $0 }
        }.joined(separator: " · ")
    }
}

/// What a condition looks at. Stored by raw value, so these strings are the
/// on-disk vocabulary.
enum RuleField: String, CaseIterable, Sendable {
    case text
    case filename
    case correspondent
    case type

    var label: String {
        switch self {
        case .text: return "Text and filename"
        case .filename: return "Filename"
        case .correspondent: return "Correspondent"
        case .type: return "Document type"
        }
    }

    /// The same thing, as it reads inside a sentence.
    var phrase: String {
        switch self {
        case .text: return "the text"
        case .filename: return "the filename"
        case .correspondent: return "the correspondent"
        case .type: return "the document type"
        }
    }
}

struct RuleCondition: Identifiable, Hashable, Sendable {
    /// Identity for the editor's list only. Conditions are rewritten as a
    /// block whenever their rule is saved, so a database row id would be zero
    /// for exactly the rows a list needs to tell apart.
    let id = UUID()
    var field: RuleField = .text
    var pattern: String = ""
    var mode: MatchMode = .anyWord
    var caseInsensitive: Bool = true
    var negated: Bool = false

    func matches(_ subject: Rule.Subject) -> Bool {
        let hit = PatternMatcher.matches(pattern, mode: mode, insensitive: caseInsensitive,
                                         in: subject.value(for: field))
        return negated ? !hit : hit
    }
}

/// What a rule does to a document that matched. A rule has at most one action
/// of each kind: two folders, or two correspondents, would need a tiebreak.
enum RuleActionKind: String, CaseIterable, Sendable {
    case moveFile = "move_file"
    case renameFile = "rename_file"
    case addTags = "add_tags"
    case setCorrespondent = "set_correspondent"
    case setDocType = "set_doc_type"

    var label: String {
        switch self {
        case .moveFile: return "Move file"
        case .renameFile: return "Rename file"
        case .addTags: return "Add tags"
        case .setCorrespondent: return "Set correspondent"
        case .setDocType: return "Set document type"
        }
    }

    var summaryPrefix: String {
        switch self {
        case .moveFile: return "→ "
        case .renameFile: return "name: "
        case .addTags: return "tags: "
        case .setCorrespondent: return "from: "
        case .setDocType: return "type: "
        }
    }

    var placeholder: String {
        switch self {
        case .moveFile: return "Finances/Invoices/{year}"
        case .renameFile: return "{date}_{correspondent}_{title}"
        case .addTags: return "invoice, finances"
        case .setCorrespondent: return "Stadtwerke München"
        case .setDocType: return "Invoice"
        }
    }
}

struct RuleAction: Identifiable, Hashable, Sendable {
    let id = UUID()
    var kind: RuleActionKind
    var value: String = ""
}

extension Rule {
    /// The rules a new library starts with. The German terms are open at the
    /// end, because German runs them into compounds: "Rechnungsnummer",
    /// "Kontoauszugsnummer".
    static let starters: [Rule] = [
        starter("Invoices", "invoice, rechnung*, facture",
                folder: "Finances/Invoices/{year}", tags: "invoice", priority: 100),
        starter("Bank Statements", "kontoauszug*, account statement, closing balance",
                folder: "Finances/Statements/{year}", tags: "bank", priority: 90),
        starter("Tax", "steuerbescheid*, finanzamt, tax return, hmrc, irs",
                folder: "Finances/Tax-{year}", tags: "tax", priority: 95),
        starter("Insurance", "versicherungsschein*, insurance policy, policy number",
                folder: "Insurance/{correspondent}", tags: "insurance", priority: 80),
        starter("Payslips", "gehaltsabrechnung*, payslip, net pay",
                folder: "Work/Payslips/{year}", tags: "payslip", priority: 85),
    ]

    private static func starter(_ name: String, _ pattern: String, folder: String,
                                tags: String, priority: Int64) -> Rule {
        Rule(id: 0, name: name, priority: priority,
             conditions: [RuleCondition(field: .text, pattern: pattern)],
             actions: [RuleAction(kind: .moveFile, value: folder),
                       RuleAction(kind: .addTags, value: tags)])
    }
}
