import SwiftUI

/// Something about a document that the library's own settings would have
/// otherwise: a rule that would still change it, in purple, or a filename the
/// naming template would not give it, in orange. Both are pointed out the same
/// way — a badge in the list, a card in the inspector that can apply or
/// suppress it — and told apart by colour and symbol.
enum Mismatch {
    case rule
    case naming

    var tint: Color {
        switch self {
        case .rule: return .purple
        case .naming: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .rule: return "line.3.horizontal.decrease"
        case .naming: return "character.cursor.ibeam"
        }
    }
}

/// A filled circle in the mismatch's colour; grey once suppressed. `symbol`
/// replaces the usual one, as a rule conflict's X does.
struct MismatchBadge: View {
    let kind: Mismatch
    var size: CGFloat = 14
    var muted = false
    var symbol: String?

    var body: some View {
        Image(systemName: symbol ?? kind.symbol)
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(muted ? Color.secondary.opacity(0.55) : kind.tint))
    }
}

extension View {
    /// The inspector card one mismatch is shown on, faded once suppressed.
    func mismatchCard(_ kind: Mismatch, suppressed: Bool) -> some View {
        padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(kind.tint.opacity(suppressed ? 0.03 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(suppressed ? Color.secondary.opacity(0.2) : kind.tint.opacity(0.3)))
    }
}

/// The top line of a mismatch card: badge, what it is about, and whether it
/// has been suppressed.
struct MismatchCardHeader: View {
    let kind: Mismatch
    let title: String
    let suppressed: Bool

    var body: some View {
        HStack(spacing: 6) {
            MismatchBadge(kind: kind, size: 16, muted: suppressed)
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if suppressed { Badge("Suppressed") }
        }
    }
}

/// What a list row or thumbnail carries for a document's open mismatches:
/// the naming badge, then the rule badge, each explaining itself on hover.
struct MismatchBadges: View {
    let rules: [RuleMatch]
    let naming: NamingMismatch?
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 3) {
            if let naming {
                MismatchBadge(kind: .naming, size: size)
                    .help(NamingMismatchCard.help(naming))
            }
            if !rules.isEmpty {
                RuleMatchBadge(size: size, conflicting: !RuleMatch.conflicts(among: rules).isEmpty)
                    .help(RuleMatchBadge.help(rules))
            }
        }
    }
}
