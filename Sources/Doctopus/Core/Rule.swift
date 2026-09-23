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

    func action(_ kind: RuleActionKind) -> String? {
        actions.first { $0.kind == kind }?.value.nilIfBlank
    }

    var destination: String? { action(.moveFile) }
    var rename: String? { action(.renameFile) }
    var setCorrespondent: String? { action(.setCorrespondent) }
    var setDocType: String? { action(.setDocType) }

    var tagNames: [String] {
        (action(.addTags) ?? "").split(separator: ",")
            .compactMap { $0.trimmingCharacters(in: .whitespaces).nilIfBlank }
    }

    var hasEffect: Bool { actions.contains { $0.value.nilIfBlank != nil } }

    /// The same rule doing only some of what it does, for accepting part of a
    /// match. Conditions are kept, so it still only touches what the rule would.
    func limited(to kinds: Set<RuleActionKind>) -> Rule {
        var copy = self
        copy.actions = actions.filter { kinds.contains($0.kind) }
        return copy
    }

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
    /// For the editor's list: conditions are rewritten on every save, so they
    /// have no stable row id.
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

    /// Completes “Rule A and Rule B …” when two rules disagree.
    var conflictPhrase: String {
        switch self {
        case .moveFile: return "would move this to different folders"
        case .renameFile: return "would give this different names"
        case .addTags: return "would add different tags"
        case .setCorrespondent: return "would set different correspondents"
        case .setDocType: return "would set different document types"
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

/// A rule that would still change a document, or one it is an outlier for.
struct RuleMatch: Identifiable, Hashable, Sendable {
    var ruleID: Int64
    var ruleName: String
    var changes: [Change]
    var suppressed: Bool

    var id: Int64 { ruleID }

    var isPending: Bool { !suppressed && !changes.isEmpty }

    enum Change: Hashable, Sendable {
        case move(to: String)
        case rename(to: String)
        case addTags([String])
        case setCorrespondent(String)
        case setDocType(String)

        var kind: RuleActionKind {
            switch self {
            case .move: return .moveFile
            case .rename: return .renameFile
            case .addTags: return .addTags
            case .setCorrespondent: return .setCorrespondent
            case .setDocType: return .setDocType
            }
        }

        var icon: String {
            switch self {
            case .move: return "folder"
            case .rename: return "character.cursor.ibeam"
            case .addTags: return "tag"
            case .setCorrespondent: return "building.2"
            case .setDocType: return "doc.on.doc"
            }
        }

        var label: String {
            switch self {
            case .move(let folder): return "Move to \(folder)"
            case .rename(let name): return "Rename to \(name)"
            case .addTags(let tags): return "Add tag\(tags.count == 1 ? "" : "s") \(tags.joined(separator: ", "))"
            case .setCorrespondent(let value): return "Set correspondent to \(value)"
            case .setDocType(let value): return "Set type to \(value)"
            }
        }
    }

    var summary: String {
        "Rule “\(ruleName)”: " + changes.map(\.label).joined(separator: "; ")
    }

    /// Pending rules that want different values for the same single-valued
    /// action — two folders, two names. Tags add up, so they never conflict.
    struct Conflict: Identifiable, Hashable, Sendable {
        var kind: RuleActionKind
        var options: [Option]

        var id: RuleActionKind { kind }

        struct Option: Hashable, Sendable {
            var ruleID: Int64
            var ruleName: String
            var change: Change
        }

        var summary: String {
            ListFormatter.localizedString(byJoining: options.map { "“\($0.ruleName)”" })
                + " " + kind.conflictPhrase
        }
    }

    static func conflicts(among matches: [RuleMatch]) -> [Conflict] {
        let pending = matches.filter(\.isPending)
        guard pending.count > 1 else { return [] }
        return RuleActionKind.allCases.compactMap { kind in
            guard kind != .addTags else { return nil }
            let options = pending.compactMap { match in
                match.changes.first { $0.kind == kind }.map {
                    Conflict.Option(ruleID: match.ruleID, ruleName: match.ruleName, change: $0)
                }
            }
            guard Set(options.map(\.change)).count > 1 else { return nil }
            return Conflict(kind: kind, options: options)
        }
    }
}
