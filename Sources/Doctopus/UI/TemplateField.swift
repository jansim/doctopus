import SwiftUI
import AppKit

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

/// Turns a folder chosen from an open panel into a path template can use:
/// relative to a library's root, since that is what every path template is
/// rendered against. Shared by the derived path template here and by a
/// routing rule's own destination field, which is not a `TemplateField`.
@MainActor
enum FolderPicker {
    /// Prompts for a folder inside `library` and hands back its path relative
    /// to the library root — empty for the root itself. `nil` when the panel
    /// was cancelled, or the folder picked is not inside the library at all
    /// (its own `.doctopus` container included), which a path template could
    /// never route into anyway.
    static func chooseRelativePath(in library: Library, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = library.root
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return relativePath(for: url, in: library)
    }

    /// What a chosen folder amounts to: its path relative to the library root,
    /// empty for the root itself, and `nil` for a folder the library does not
    /// own. Apart from the panel so a check can put a URL through it without
    /// a modal to answer.
    static func relativePath(for url: URL, in library: Library) -> String? {
        let path = Store.canonical(url.standardizedFileURL.path)
        guard library.owns(path: path), !FileScanner.isInsideLibraryContainer(url) else { return nil }
        return path == library.root.path ? "" : String(path.dropFirst(library.root.path.count + 1))
    }
}

/// What a `TemplateField` is for: a filename or a folder path. The two differ
/// in the separator a tapped token is joined with, in whether a `/` may be
/// typed at all, and in how the live example below the field is built —
/// everything else about editing one is the same.
enum TemplateFieldKind: Equatable {
    case filename
    case path

    var separator: Character {
        switch self {
        case .filename: return "_"
        case .path: return "/"
        }
    }

    /// A filename can't contain a path separator; a folder path is made of
    /// them, so it's the one character never forbidden there.
    var forbidsSlash: Bool { self == .filename }

    /// Sample values standing in for a real document's own, so every token in
    /// a template shows something in the live example.
    private static func sample(ext: String, originalStem: String) -> Naming.Context {
        Naming.Context(
            date: DayDate.calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)),
            correspondent: "Acme Corp", title: "Invoice", docType: "Invoice",
            language: "en", counter: 2, originalStem: originalStem, ext: ext)
    }

    /// What this kind of template renders to. A path always ends in `/`, so
    /// the preview reads as a directory rather than a file at a glance.
    func preview(_ template: String) -> String {
        guard template.nilIfBlank != nil else { return "—" }
        switch self {
        case .filename:
            return Naming.render(template, Self.sample(ext: "pdf", originalStem: "scan0001"))
        case .path:
            let components = Naming.renderPath(template, Self.sample(ext: "", originalStem: "Unfiled"))
            return components.isEmpty ? "/" : components.joined(separator: "/") + "/"
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
    /// Where a folder path's picker button is rooted. `nil` leaves the button
    /// off — there is no library to choose inside for a bare filename template.
    var library: Library? = nil

    /// The field's own caret/selection, so a tapped token lands where the
    /// user was typing instead of always at the end.
    @State private var selection: TextSelection?

    var body: some View {
        Group {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tokens) { token in
                        Button(token.symbol) { insert(token) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.caption.monospaced())
                            .help(token.help)
                    }
                }
            }
            .frame(height: 26)
            HStack(spacing: 6) {
                TextField(title, text: $template, selection: $selection)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: template) { _, newValue in
                        guard kind.forbidsSlash, newValue.contains("/") else { return }
                        template = newValue.filter { $0 != "/" }
                    }
                if kind == .path, let library {
                    Button {
                        guard let chosen = FolderPicker.chooseRelativePath(
                            in: library, message: "Choose a folder inside \(library.displayName).")
                        else { return }
                        template = chosen
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose a folder")
                }
            }
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

    /// Inserts at the caret, or replaces the current selection, joined by the
    /// kind's separator on whichever side already has adjoining text — so a
    /// token dropped between two others doesn't run into them. Falls back to
    /// appending at the end when the field has never been focused.
    private func insert(_ token: TemplateToken) {
        let sep = kind.separator
        guard let selection, case .selection(let range) = selection.indices,
              range.lowerBound <= template.endIndex, range.upperBound <= template.endIndex else {
            appendAtEnd(token, separator: sep)
            return
        }
        var piece = token.symbol
        if range.lowerBound > template.startIndex, template[template.index(before: range.lowerBound)] != sep {
            piece = String(sep) + piece
        }
        if range.upperBound < template.endIndex, template[range.upperBound] != sep {
            piece += String(sep)
        }
        template.replaceSubrange(range, with: piece)
        self.selection = TextSelection(insertionPoint: template.index(range.lowerBound, offsetBy: piece.count))
    }

    private func appendAtEnd(_ token: TemplateToken, separator sep: Character) {
        if template.isEmpty || template.last == sep {
            template += token.symbol
        } else {
            template.append(sep)
            template += token.symbol
        }
        selection = TextSelection(insertionPoint: template.endIndex)
    }
}
