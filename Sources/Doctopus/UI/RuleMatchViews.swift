import SwiftUI

struct RuleMatchBadge: View {
    var size: CGFloat = 14
    var muted = false

    var body: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(muted ? Color.secondary.opacity(0.55) : Color.purple))
    }

    static func help(_ matches: [RuleMatch]) -> String {
        matches.map(\.summary).joined(separator: "\n")
    }
}

struct RuleMatchSection: View {
    @Environment(AppModel.self) private var model
    let row: DocumentRow

    var body: some View {
        let matches = model.ruleMatches(for: row)
        if !matches.isEmpty {
            Section2(matches.count == 1 ? "Rule Match" : "Rule Matches") {
                ForEach(matches) { match in
                    RuleMatchCard(match: match, row: row)
                }
            }
        }
    }
}

private struct RuleMatchCard: View {
    @Environment(AppModel.self) private var model
    let match: RuleMatch
    let row: DocumentRow

    var body: some View {
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
                    Button("Apply") { model.applyRule(match, to: row) }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .help("Apply “\(match.ruleName)” to this document now")
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
    @State private var declined: [Int64: Set<RuleMatch.Change>] = [:]

    var body: some View {
        let matches = model.pendingRuleMatches(for: row)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(matches.count == 1 ? "NEW RULE MATCH" : "NEW RULE MATCHES")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                ForEach(matches) { match in
                    card(match)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.05))
        }
    }

    private func card(_ match: RuleMatch) -> some View {
        let skipped = declined[match.ruleID] ?? []
        let accepted = Set(match.changes).subtracting(skipped)
        let partial = accepted.count < match.changes.count
        return HStack(alignment: .top, spacing: 8) {
            RuleMatchBadge(size: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(match.ruleName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                ForEach(match.changes, id: \.self) { change in
                    Toggle(isOn: Binding(
                        get: { !skipped.contains(change) },
                        set: { on in
                            if on { declined[match.ruleID, default: []].remove(change) }
                            else { declined[match.ruleID, default: []].insert(change) }
                        })) {
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
                .disabled(accepted.isEmpty)
                .help(partial
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
