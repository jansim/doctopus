import SwiftUI

/// Filter lines for one rule; an X when several rules want the same document,
/// which is worth a look even when they agree.
struct RuleMatchBadge: View {
    var size: CGFloat = 14
    var muted = false
    var multiple = false

    var body: some View {
        Image(systemName: multiple ? "xmark" : "line.3.horizontal.decrease")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(muted ? Color.secondary.opacity(0.55) : Color.purple))
    }

    static func help(_ matches: [RuleMatch]) -> String {
        let lines = matches.map(\.summary)
        guard matches.count > 1 else { return lines.joined(separator: "\n") }
        let conflicts = RuleMatch.conflicts(among: matches).map { "⚠︎ " + $0.summary }
        return (["Matches \(matches.count) rules"] + lines + conflicts).joined(separator: "\n")
    }
}

/// Which of a document's pending changes the user has turned down. A conflict
/// counts as settled once no more than one of its options is still accepted.
struct RuleMatchChoices {
    var declined: [Int64: Set<RuleMatch.Change>] = [:]

    func accepted(_ match: RuleMatch) -> Set<RuleMatch.Change> {
        Set(match.changes).subtracting(declined[match.ruleID] ?? [])
    }

    func isAccepted(_ change: RuleMatch.Change, of ruleID: Int64) -> Bool {
        !(declined[ruleID] ?? []).contains(change)
    }

    func chosen(in conflict: RuleMatch.Conflict) -> Int64? {
        let open = conflict.options.filter { isAccepted($0.change, of: $0.ruleID) }
        return open.count == 1 ? open[0].ruleID : nil
    }

    func isSettled(_ conflict: RuleMatch.Conflict) -> Bool {
        conflict.options.filter { isAccepted($0.change, of: $0.ruleID) }.count <= 1
    }

    /// A rule caught in a conflict nobody has settled can't be applied yet.
    func isBlocked(_ ruleID: Int64, by conflicts: [RuleMatch.Conflict]) -> Bool {
        conflicts.contains { conflict in
            !isSettled(conflict) && conflict.options.contains { $0.ruleID == ruleID }
        }
    }

    mutating func choose(_ ruleID: Int64, in conflict: RuleMatch.Conflict) {
        for option in conflict.options {
            if option.ruleID == ruleID { declined[option.ruleID, default: []].remove(option.change) }
            else { declined[option.ruleID, default: []].insert(option.change) }
        }
    }

    /// Ticking a conflicting change back on picks its rule over the others.
    mutating func set(_ on: Bool, _ change: RuleMatch.Change, of ruleID: Int64,
                      conflicts: [RuleMatch.Conflict]) {
        if on, let conflict = conflicts.first(where: {
            $0.options.contains { $0.ruleID == ruleID && $0.change == change }
        }) {
            choose(ruleID, in: conflict)
        } else if on {
            declined[ruleID, default: []].remove(change)
        } else {
            declined[ruleID, default: []].insert(change)
        }
    }
}

/// The box above a document's rule matches when more than one rule wants it:
/// says which, and makes the user pick wherever they disagree before anything
/// can be applied.
struct RuleMatchesNotice: View {
    @Environment(AppModel.self) private var model
    let row: DocumentRow
    let matches: [RuleMatch]
    @Binding var choices: RuleMatchChoices

    var body: some View {
        let conflicts = RuleMatch.conflicts(among: matches)
        let settled = conflicts.allSatisfy(choices.isSettled)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RuleMatchBadge(size: 16, multiple: true)
                Text("Matches \(matches.count) rules")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if !conflicts.isEmpty {
                    Badge(conflicts.count == 1 ? "Conflict" : "\(conflicts.count) Conflicts", tint: .purple)
                }
            }
            if conflicts.isEmpty {
                Text("\(ListFormatter.localizedString(byJoining: matches.map { "“\($0.ruleName)”" })) all apply here. Their changes don’t overlap, so they can be applied together.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(conflicts) { conflict in
                    choice(conflict)
                }
                Text("A rule you don’t pick is suppressed for this document, so it stops pointing this out.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Apply All") {
                    model.applyRules(matches.map { ($0, choices.accepted($0)) }, to: row)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!settled)
                .help(settled
                      ? "Apply every matching rule, as chosen, to this document"
                      : "Choose between the conflicting rules first")
            }
            .controlSize(.small)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.purple.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.purple.opacity(0.55)))
    }

    private func choice(_ conflict: RuleMatch.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(conflict.summary + (choices.isSettled(conflict) ? "." : " — choose one:"))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: choices.isSettled(conflict)
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.purple)
            Picker(conflict.kind.label, selection: Binding(
                get: { choices.chosen(in: conflict) },
                set: { if let id = $0 { choices.choose(id, in: conflict) } })) {
                ForEach(conflict.options, id: \.ruleID) { option in
                    Text("\(option.change.label) — “\(option.ruleName)”")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(Int64?.some(option.ruleID))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(.caption)
        }
    }
}

struct RuleMatchSection: View {
    @Environment(AppModel.self) private var model
    let row: DocumentRow
    @State private var choices = RuleMatchChoices()

    var body: some View {
        let matches = model.ruleMatches(for: row)
        let pending = matches.filter(\.isPending)
        let conflicts = RuleMatch.conflicts(among: pending)
        if !matches.isEmpty {
            Section2(matches.count == 1 ? "Rule Match" : "Rule Matches") {
                if pending.count > 1 {
                    RuleMatchesNotice(row: row, matches: pending, choices: $choices)
                }
                ForEach(matches) { match in
                    RuleMatchCard(match: match, row: row, choices: choices,
                                  blocked: choices.isBlocked(match.ruleID, by: conflicts))
                }
            }
            .onChange(of: row.id) { choices = RuleMatchChoices() }
        }
    }
}

private struct RuleMatchCard: View {
    @Environment(AppModel.self) private var model
    let match: RuleMatch
    let row: DocumentRow
    let choices: RuleMatchChoices
    let blocked: Bool

    var body: some View {
        let accepted = choices.accepted(match)
        let partial = accepted.count < match.changes.count
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    RuleMatchBadge(size: 16, muted: match.suppressed)
                    Text(match.ruleName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if match.suppressed { Badge("Suppressed") }
                }
                if match.changes.isEmpty {
                    Text("Nothing left for this rule to change.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(match.changes, id: \.self) { change in
                            Label {
                                Text(change.label)
                                    .strikethrough(!accepted.contains(change))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: change.icon)
                            }
                            .font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .opacity(match.suppressed ? 0.6 : 1)

            HStack(spacing: 8) {
                if match.suppressed {
                    Button("Stop Suppressing") { model.setRuleSuppressed(false, match, for: row) }
                        .help("Point this rule out on this document again")
                } else {
                    Button(partial ? "Apply Chosen" : "Apply") {
                        model.applyRule(match, to: row, accepting: accepted)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(blocked || accepted.isEmpty)
                    .help(blocked
                          ? "Another rule wants something different here — choose between them above"
                          : "Apply “\(match.ruleName)” to this document now")
                    Button("Suppress") { model.setRuleSuppressed(true, match, for: row) }
                        .help("Mark this document as an outlier: the rule leaves it alone and stops pointing it out")
                }
            }
            .controlSize(.small)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.purple.opacity(match.suppressed ? 0.03 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(match.suppressed ? Color.secondary.opacity(0.2) : Color.purple.opacity(0.3)))
    }
}

/// A rule's pending changes in Needs Review, each one ticked on by default.
/// Applying with some unticked applies the rest and suppresses the rule for
/// this document, so it stops pointing out what was left.
struct RuleMatchReview: View {
    @Environment(AppModel.self) private var model
    let row: DocumentRow
    @State private var choices = RuleMatchChoices()

    var body: some View {
        let matches = model.pendingRuleMatches(for: row)
        let conflicts = RuleMatch.conflicts(among: matches)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(matches.count == 1 ? "NEW RULE MATCH" : "NEW RULE MATCHES")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                if matches.count > 1 {
                    RuleMatchesNotice(row: row, matches: matches, choices: $choices)
                }
                ForEach(matches) { match in
                    card(match, conflicts: conflicts)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.05))
            .onChange(of: row.id) { choices = RuleMatchChoices() }
        }
    }

    private func card(_ match: RuleMatch, conflicts: [RuleMatch.Conflict]) -> some View {
        let accepted = choices.accepted(match)
        let partial = accepted.count < match.changes.count
        let blocked = choices.isBlocked(match.ruleID, by: conflicts)
        return HStack(alignment: .top, spacing: 8) {
            RuleMatchBadge(size: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(match.ruleName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                ForEach(match.changes, id: \.self) { change in
                    Toggle(isOn: Binding(
                        get: { accepted.contains(change) },
                        set: { choices.set($0, change, of: match.ruleID, conflicts: conflicts) })) {
                        Label {
                            Text(change.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: change.icon)
                        }
                        .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(partial ? "Apply Selected" : "Apply") {
                    model.applyRule(match, to: row, accepting: accepted)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(blocked || accepted.isEmpty)
                .help(blocked
                      ? "Another rule wants something different here — choose between them above"
                      : partial
                      ? "Apply the ticked changes and suppress “\(match.ruleName)” for this document, so the rest are left alone"
                      : "Apply “\(match.ruleName)” to this document now")
                Button("Suppress") { model.setRuleSuppressed(true, match, for: row) }
                    .help("Mark this document as an outlier: the rule leaves it alone and stops pointing it out")
            }
            .controlSize(.small)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.purple.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.purple.opacity(0.3)))
    }
}
