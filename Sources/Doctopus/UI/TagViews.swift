import SwiftUI

extension FinderTags {
    static let labelColors: [Color?] = [nil, .gray, .green, .purple, .blue, .yellow, .red, .orange]

    static func color(label: Int) -> Color? {
        labelColors.indices.contains(label) ? labelColors[label] : nil
    }

    static func color(for name: String) -> Color? { color(label: label(for: name)) }
}

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

struct TagChips: View {
    let tags: [Tag]

    var body: some View {
        let visible = Tag.visible(in: tags)
        if visible.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 3) {
                ForEach(visible, id: \.tag.id) { entry in
                    let color = TagColor.color(entry.tag.color)
                    HStack(spacing: 3) {
                        Image(systemName: entry.tag.icon ?? Tag.defaultIcon)
                            .font(.system(size: 8))
                            .foregroundStyle(color)
                        Text(entry.path).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(color.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.4)))
                }
            }
        }
    }
}

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

struct TagChip: View {
    let tag: Tag
    var displayName: String?
    var compact = false
    let onRemove: () -> Void

    var body: some View {
        let color = TagColor.color(tag.color)
        let shown = displayName ?? tag.name
        ChipBody(compact: compact) {
            Image(systemName: tag.icon ?? Tag.defaultIcon)
                .font(.system(size: compact ? 8 : 9))
                .foregroundStyle(color)
            Text(shown).font(.caption)
            RemoveButton(help: "Remove “\(shown)”", action: onRemove)
        }
        .background(color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.45)))
    }
}

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
