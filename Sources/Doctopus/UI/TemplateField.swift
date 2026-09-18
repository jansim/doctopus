import SwiftUI

/// One token `Naming.render` understands, described for the UI: what to type,
/// and what it means.
struct TemplateToken: Identifiable {
    var symbol: String
    var help: String
    var id: String { symbol }
}

/// The token vocabulary every `Naming` template shares — a rename filename, a
/// derived folder path, or whatever comes next. Described once here, so a
/// token means the same thing everywhere it can be typed.
enum TemplateTokens {
    static let all: [TemplateToken] = [
        TemplateToken(symbol: "{date}", help: "Document date, yyyy-MM-dd. Add a format like {date:yyyy-MM} for a custom one."),
        TemplateToken(symbol: "{year}", help: "Document year, e.g. 2026."),
        TemplateToken(symbol: "{month}", help: "Document month, 01–12."),
        TemplateToken(symbol: "{day}", help: "Document day, 01–31."),
        TemplateToken(symbol: "{correspondent}", help: "Who the document is from or to."),
        TemplateToken(symbol: "{title}", help: "The document's title, or its original filename if it has none."),
        TemplateToken(symbol: "{type}", help: "Document type, e.g. Invoice or Statement."),
        TemplateToken(symbol: "{lang}", help: "Document language code, e.g. en or de."),
        TemplateToken(symbol: "{n}", help: "A counter (001, 002, …) so filenames never collide."),
        TemplateToken(symbol: "{original}", help: "The original filename, without its extension."),
    ]
}

/// What a `TemplateField` is for: a filename or a folder path. The two differ
/// in the separator a tapped token is joined with and in how the live example
/// below the field is built — everything else about editing one is the same.
enum TemplateFieldKind {
    case filename
    case path

    var separator: Character {
        switch self {
        case .filename: return "_"
        case .path: return "/"
        }
    }

    /// Sample values standing in for a real document's own, so every token in
    /// a template shows something in the live example.
    private static func sample(ext: String, originalStem: String) -> Naming.Context {
        Naming.Context(
            date: DayDate.calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)),
            correspondent: "Acme Corp", title: "Invoice", docType: "Invoice",
            language: "en", counter: 2, originalStem: originalStem, ext: ext)
    }

    func preview(_ template: String) -> String {
        guard template.nilIfBlank != nil else { return "—" }
        switch self {
        case .filename:
            return Naming.render(template, Self.sample(ext: "pdf", originalStem: "scan0001"))
        case .path:
            let components = Naming.renderPath(template, Self.sample(ext: "", originalStem: "Unfiled"))
            return components.isEmpty ? "(the library folder itself)" : components.joined(separator: "/")
        }
    }
}

/// A text field for a `Naming` template: a row of insertable tokens above it,
/// each explained on hover, and a live example of what the template renders
/// to below it. Used for the rename template and the derived path template
/// alike — and for whatever template field comes next.
struct TemplateField: View {
    var title: String
    @Binding var template: String
    var kind: TemplateFieldKind
    var tokens: [TemplateToken] = TemplateTokens.all

    var body: some View {
        Group {
            HStack(spacing: 4) {
                ForEach(tokens) { token in
                    Button(token.symbol) { insert(token) }
                        .buttonStyle(.borderless)
                        .font(.caption.monospaced())
                        .help(token.help)
                }
                Spacer()
            }
            TextField(title, text: $template)
                .font(.system(.body, design: .monospaced))
            LabeledContent("For example") {
                Text(kind.preview(template))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    /// Appends the token to whatever is already there, joined by the kind's
    /// separator unless the text is empty or already ends in one.
    private func insert(_ token: TemplateToken) {
        let sep = kind.separator
        if template.isEmpty || template.last == sep {
            template += token.symbol
        } else {
            template.append(sep)
            template += token.symbol
        }
    }
}
