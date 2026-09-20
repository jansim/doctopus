import Foundation

/// A filing rule: one or more conditions, and one or more things to do to a
/// document that satisfies them.
///
/// A rule used to be a single pattern pointed at a single field, with its
/// effects spread over four columns that were each either set or not. That
/// covered "invoices go to Finances/Invoices" and nothing else: "an invoice
/// from Acme, but not the credit notes" needed two rules that could not say
/// they belonged together, and a rule that only tagged still had to carry an
/// empty destination.
///
/// Conditions and actions are both lists now, which is the whole of the added
/// power — deliberately. A rule still cannot call another rule, branch, or run
/// anything: it is a test and a list of consequences, the way a mail filter is.
struct Rule: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var enabled: Bool = true
    /// Higher runs first. Rewritten as a block when the list is reordered.
    var priority: Int64 = 0
    /// How sure a match makes Doctopus, before the routing threshold and the
    /// quality of what was extracted are weighed against it.
    var weight: Double = 0.9
    /// Whether every condition has to hold, or just one of them.
    var requiresAll: Bool = false
    var conditions: [RuleCondition] = []
    var actions: [RuleAction] = []

    /// Everything a condition can be pointed at, gathered once per document so
    /// that a rule with several conditions reads it rather than rebuilding it,
    /// and so the router, the editor's preview and Apply to Existing can never
    /// disagree about what a rule sees.
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
    /// matching everything: a half-typed condition must not widen a rule, least
    /// of all in "all of" mode, where an empty one that matched would be
    /// invisible.
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

    /// Each kind of action appears at most once in a rule, so every one of
    /// these is a single answer rather than a list to resolve.
    func action(_ kind: RuleActionKind) -> String? {
        actions.first { $0.kind == kind }?.value.nilIfBlank
    }

    /// Where the rule files a document, as a path template, or nil when it
    /// does not move anything.
    var destination: String? { action(.fileInto) }
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

    /// The conditions in one line. A rule with several of them shows the first
    /// and says how many more there are, along with the join — which is the
    /// part that changes what the rule means.
    var conditionSummary: String {
        let live = liveConditions
        guard let first = live.first else { return "—" }
        let lead = (first.negated ? "not " : "") + first.pattern
        guard live.count > 1 else { return lead }
        return "\(lead) + \(live.count - 1) more (\(requiresAll ? "all" : "any"))"
    }

    /// What it does, in one line.
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

/// One test a document has to pass.
struct RuleCondition: Identifiable, Hashable, Sendable {
    /// Identity for the editor's list only. Conditions are rewritten as a
    /// block whenever their rule is saved, so a database row id would be zero
    /// for exactly the rows a list needs to tell apart.
    let id = UUID()
    var field: RuleField = .text
    var pattern: String = ""
    var mode: MatchMode = .anyWord
    var caseInsensitive: Bool = true
    /// Inverts the test: the condition holds when the pattern is *not* found.
    var negated: Bool = false

    func matches(_ subject: Rule.Subject) -> Bool {
        let hit = PatternMatcher.matches(pattern, mode: mode, insensitive: caseInsensitive,
                                         in: subject.value(for: field))
        return negated ? !hit : hit
    }
}

/// What a rule does to a document that matched. One value per kind: a rule
/// that filed into two folders, or set two correspondents, would have to pick
/// one anyway, so the editor never offers a second of the same kind.
enum RuleActionKind: String, CaseIterable, Sendable {
    case fileInto = "file_into"
    case addTags = "add_tags"
    case setCorrespondent = "set_correspondent"
    case setDocType = "set_doc_type"

    var label: String {
        switch self {
        case .fileInto: return "File into"
        case .addTags: return "Add tags"
        case .setCorrespondent: return "Set correspondent"
        case .setDocType: return "Set document type"
        }
    }

    /// How the action reads in the rule list, where the column is too narrow
    /// for its name.
    var summaryPrefix: String {
        switch self {
        case .fileInto: return "→ "
        case .addTags: return "tags: "
        case .setCorrespondent: return "from: "
        case .setDocType: return "type: "
        }
    }

    var placeholder: String {
        switch self {
        case .fileInto: return "Finances/Invoices/{year}"
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
    /// The rules a new library starts with. Written the way the editor would
    /// write them: one condition, one or two actions.
    static let starters: [Rule] = [
        starter("Invoices", "invoice, rechnung, facture",
                folder: "Finances/Invoices/{year}", tags: "invoice", priority: 100, weight: 0.92),
        starter("Bank Statements", "kontoauszug, account statement, closing balance",
                folder: "Finances/Statements/{year}", tags: "bank", priority: 90, weight: 0.9),
        starter("Tax", "steuerbescheid, finanzamt, tax return, hmrc, irs",
                folder: "Finances/Tax-{year}", tags: "tax", priority: 95, weight: 0.93),
        starter("Insurance", "versicherungsschein, insurance policy, policy number",
                folder: "Insurance/{correspondent}", tags: "insurance", priority: 80, weight: 0.88),
        starter("Payslips", "gehaltsabrechnung, payslip, net pay",
                folder: "Work/Payslips/{year}", tags: "payslip", priority: 85, weight: 0.9),
    ]

    private static func starter(_ name: String, _ pattern: String, folder: String,
                                tags: String, priority: Int64, weight: Double) -> Rule {
        Rule(id: 0, name: name, priority: priority, weight: weight,
             conditions: [RuleCondition(field: .text, pattern: pattern)],
             actions: [RuleAction(kind: .fileInto, value: folder),
                       RuleAction(kind: .addTags, value: tags)])
    }
}
