import SwiftUI

/// How the two tag systems are drawn, everywhere they appear.
///
/// Doctopus's own tags carry the outline tag symbol in the tag's colour. The
/// Finder's carry the Finder's own coloured dot, because that is what they look
/// like everywhere else in macOS. Keeping the two shapes apart is what makes it
/// obvious at a glance which system a tag belongs to.

/// A Finder tag's colour, drawn the way the Finder draws it: a filled dot, or
/// an empty ring for a tag macOS gave no colour label.
struct FinderTagDot: View {
    let name: String
    var size: CGFloat = 9

    var body: some View {
        Group {
            if let color = FinderTags.color(for: name) {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.2)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Doctopus's own tags, small enough to sit in a table cell. Tags are a set, so
/// the column is not sortable — there is no sensible order to put them in.
struct TagChips: View {
    let tags: [Tag]

    var body: some View {
        if tags.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 3) {
                ForEach(tags) { tag in
                    let color = TagColor.color(tag.color)
                    HStack(spacing: 3) {
                        Image(systemName: "tag")
                            .font(.system(size: 8))
                            .foregroundStyle(color)
                        Text(tag.name).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.4)))
                }
            }
        }
    }
}

/// The Finder's tags in the same space: a dot and a name, no capsule, since the
/// dot already carries the colour.
struct FinderTagChips: View {
    let names: [String]

    var body: some View {
        if names.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 7) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 4) {
                        FinderTagDot(name: name, size: 8)
                        Text(name).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }
}

/// One of Doctopus's tags as an editable token.
struct TagChip: View {
    let tag: Tag
    var compact = false
    let onRemove: () -> Void

    var body: some View {
        let color = TagColor.color(tag.color)
        ChipBody(compact: compact) {
            Image(systemName: "tag")
                .font(.system(size: compact ? 8 : 9))
                .foregroundStyle(color)
            Text(tag.name).font(.caption)
            RemoveButton(help: "Remove “\(tag.name)”", action: onRemove)
        }
        .background(color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.45)))
    }
}

/// A tag the model proposed, displayed with a dashed border until accepted.
struct TagSuggestionChip: View {
    let suggestion: TagSuggestion
    var color: Color = .secondary
    var compact = false
    let onAccept: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        ChipBody(compact: compact) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 8 : 9))
                .foregroundStyle(color)
            Text(suggestion.name).font(.caption)
            RemoveButton(help: "Dismiss “\(suggestion.name)”", action: onDiscard)
        }
        .background(color.opacity(compact ? 0.08 : 0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.5),
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .contentShape(Capsule())
        .onTapGesture(perform: onAccept)
        .help("Click to accept “\(suggestion.name)”, or dismiss it with ×")
    }
}

private struct ChipBody<Content: View>: View {
    let compact: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: compact ? 3 : 4) { content }
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 2 : 3)
    }
}

private struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
