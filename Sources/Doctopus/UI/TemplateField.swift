import SwiftUI
import AppKit

struct TemplateToken: Identifiable {
    var symbol: String
    var help: String
    var id: String { symbol }
}

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

@MainActor
enum FolderPicker {
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

    static func relativePath(for url: URL, in library: Library) -> String? {
        let path = Store.canonical(url.standardizedFileURL.path)
        guard library.owns(path: path), !FileScanner.isInsideLibraryContainer(url) else { return nil }
        return path == library.root.path ? "" : String(path.dropFirst(library.root.path.count + 1))
    }
}

enum TemplateFieldKind: Equatable {
    case filename
    case path

    var separator: Character {
        switch self {
        case .filename: return "_"
        case .path: return "/"
        }
    }

    var forbidsSlash: Bool { self == .filename }

    private static func sample(ext: String, originalStem: String) -> Naming.Context {
        Naming.Context(
            date: DayDate.calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)),
            correspondent: "Acme Corp", title: "Invoice", docType: "Invoice",
            language: "en", counter: 2, originalStem: originalStem, ext: ext)
    }

    func preview(_ template: String, naming: Naming.Options = Naming.Options()) -> String {
        guard template.nilIfBlank != nil else { return "—" }
        switch self {
        case .filename:
            var ctx = Self.sample(ext: "pdf", originalStem: "scan0001")
            ctx.options = naming
            return Naming.render(template, ctx)
        case .path:
            let components = Naming.renderPath(template, Self.sample(ext: "", originalStem: "Unfiled"))
            return components.isEmpty ? "/" : components.joined(separator: "/") + "/"
        }
    }
}

struct TemplateField: View {
    var title: String
    @Binding var template: String
    var kind: TemplateFieldKind
    var tokens: [TemplateToken] = TemplateTokens.all
    var library: Library? = nil
    /// Filename clean-ups to show in the example; folders ignore them.
    var naming = Naming.Options()

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
                Text(kind.preview(template, naming: naming))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

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
