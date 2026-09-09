import SwiftUI

/// Batch rename with a live preview. Renaming is always explicit — nothing here
/// runs automatically.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var template = Naming.defaultTemplate

    private var rows: [DocumentRow] { model.selectedRows }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rows.count == 1 ? "Rename Document" : "Rename \(rows.count) Documents")
                .font(.headline)

            TextField("Template", text: $template)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(spacing: 5) {
                ForEach(["{date}", "{correspondent}", "{title}", "{type}", "{year}", "{n}"], id: \.self) { token in
                    Button(token) { template += token }
                        .buttonStyle(.borderless)
                        .font(.caption.monospaced())
                }
                Spacer()
            }

            Text("Missing values collapse cleanly — no stray separators. The extension is preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Preview") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(rows.prefix(12).enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 6) {
                                Text(row.filename)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(preview(row, counter: index + 1))
                                    .fontWeight(.medium)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .font(.caption.monospaced())
                        }
                        if rows.count > 12 {
                            Text("+ \(rows.count - 12) more").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
            }

            HStack {
                Button("Save as Default") {
                    model.settings.namingTemplate = template
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.rename(rows, template: template)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.isEmpty || template.nilIfBlank == nil)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { template = model.settings.namingTemplate }
    }

    private func preview(_ row: DocumentRow, counter: Int) -> String {
        let url = row.url
        let ctx = Naming.Context(date: row.docDate ?? row.createdAt,
                                 correspondent: row.correspondent, title: row.title,
                                 docType: row.docType, language: row.language, counter: counter,
                                 originalStem: url.deletingPathExtension().lastPathComponent,
                                 ext: url.pathExtension)
        return Naming.render(template, ctx)
    }
}

struct AddTagSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Tag").font(.headline)
            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if !model.distinctTags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(model.distinctTags.prefix(24)) { tag in
                        Button(tag.name) { name = tag.name }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(TagColor.color(tag.color).opacity(0.16), in: Capsule())
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Add", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.nilIfBlank == nil)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func commit() {
        guard let clean = name.nilIfBlank else { return }
        model.addTag(clean, to: model.selectedRows)
        isPresented = false
    }
}
