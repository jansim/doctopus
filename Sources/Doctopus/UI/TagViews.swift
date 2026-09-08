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
