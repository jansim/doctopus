import SwiftUI

/// The mark on a document a rule would still change: the Rules icon in a
/// purple circle, grey once the document is an outlier for it.
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

/// The inspector's account of the rules that match a document but have not
/// been applied to it, with the two ways to settle each: apply it, or mark the
/// document as an outlier the rule should leave alone.
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
