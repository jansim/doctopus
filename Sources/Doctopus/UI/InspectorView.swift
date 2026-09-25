import SwiftUI
import AppKit
import QuickLookThumbnailing

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let detail = model.detail {
                DetailInspector(detail: detail)
            } else if model.selectedIDs.count > 1 {
                MultiSelectionInspector(count: model.selectedIDs.count)
            } else {
                ContentUnavailableView("No Selection", systemImage: "doc.text",
                                       description: Text("Select a document to inspect its metadata, tags and extracted text."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DetailInspector: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    @State private var showRawText = false
    @State private var showAllHistory = false
    @State private var tagInput = ""
    @State private var finderTagInput = ""
    @State private var confirmingDeleteOriginal = false

    private var row: DocumentRow { detail.row }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                // In review the panel below the list decides on rule matches.
                if !model.selection.isQueueMode { RuleMatchSection(row: row) }
                summarySection
                metadataSection
                tagsSection
                if !detail.tagSuggestions.isEmpty { tagSuggestionsSection }
                finderTagsSection
                notesSection
                fileSection
                if !detail.similarDocuments.isEmpty { similarDocumentsSection }
                if !detail.aliases.isEmpty { aliasSection }
                if !detail.history.isEmpty { historySection }
                textSection
            }
            .padding(14)
        }
        .id(row.id)
    }

    @ViewBuilder
    private var summarySection: some View {
        let analyzing = model.progress.phase == "Analyzing"
        Section2("Summary") {
            if let summary = row.summary {
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.modelStatus.isReady
                     ? "Not analyzed yet."
                     : "No model configured — \(model.modelStatus.label).")
                    .font(.callout).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.analyze([row])
                } label: {
                    Label("Analyze with Model", systemImage: "sparkles")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .disabled(!model.modelStatus.isReady || analyzing)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(url: row.url, mtime: row.mtime, size: .large,
                      width: 54, height: 70, cornerRadius: 4, showsShadow: true)
                .onTapGesture { model.quickLook(startingAt: row) }
                .help("Quick Look")
            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayTitle)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let pages = row.pageCount {
                        Badge("\(pages) page\(pages == 1 ? "" : "s")")
                    }
                    Badge(row.ext.uppercased())
                    if !row.approved { Badge("Needs review", tint: .orange) }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var metadataSection: some View {
        Section2("Metadata") {
            InfoGrid {
                EditableRow("Title", value: row.title ?? "") {
                    model.editMetadata(row.id, column: "title", value: $0)
                }
                ForEach(model.fields) { field in
                    FieldValueRow(field: field, value: row.values[field.key] ?? "",
                                  document: row.id)
                }
                InfoRow("Date", alignment: .center) {
                    HStack(spacing: 5) {
                        DatePicker("", selection: Binding(
                            get: { row.docDate ?? row.createdAt },
                            set: { model.setDocumentDate(row.id, $0) }),
                            displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .dayResolution()
                        if let source = detail.dateSource {
                            Text(dateSourceLabel(source))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .help("Where this date came from")
                        }
                    }
                }
                if let source = detail.metadataSource {
                    InfoRow("Extracted by") {
                        Text(Self.sourceLabel(source)).help("How this document's metadata was worked out")
                    }
                }
            }
        }
    }

    private static func sourceLabel(_ s: String) -> String {
        MetadataSource(s).detailedLabel
    }

    private func dateSourceLabel(_ s: String) -> String {
        switch s {
        case "ocr": return "from text"
        case "pdf": return "from PDF"
        case "exif": return "from EXIF"
        case "filename": return "from name"
        case "manual": return "edited"
        default: return "from file"
        }
    }

    private var tagsSection: some View {
        Section2("Tags") {
            let visible = Tag.visible(in: detail.tags)
            if visible.isEmpty {
                Text("No tags").font(.callout).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(visible, id: \.tag.id) { entry in
                        TagChip(tag: entry.tag, displayName: entry.path) {
                            model.removeTag(entry.tag, from: [row])
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Add tag", text: $tagInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit(commitTag)
                Button("Add", action: commitTag)
                    .disabled(tagInput.nilIfBlank == nil)
            }
        }
    }

    private var tagSuggestionsSection: some View {
        Section2("Suggested Tags") {
            FlowLayout(spacing: 5) {
                ForEach(detail.tagSuggestions) { suggestion in
                    TagSuggestionChip(
                        suggestion: suggestion, color: suggestionColor(suggestion.name),
                        onAccept: { model.acceptTagSuggestion(suggestion, for: row) },
                        onDiscard: { model.discardTagSuggestion(suggestion, for: row) })
                }
            }
        }
    }

    private func suggestionColor(_ name: String) -> Color {
        if let existing = model.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return TagColor.color(existing.color)
        }
        return .secondary
    }

    private var finderTagsSection: some View {
        Section2("Finder Tags") {
            if row.finderTags.isEmpty {
                Text("No Finder tags").font(.callout).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(row.finderTags, id: \.self) { name in
                        HStack(spacing: 4) {
                            FinderTagDot(name: name, size: 8)
                            Text(name).font(.caption)
                            Button {
                                model.removeFinderTag(name, from: [row])
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Add Finder tag", text: $finderTagInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit(commitFinderTag)
                Button("Add", action: commitFinderTag)
                    .disabled(finderTagInput.nilIfBlank == nil)
            }
        }
    }

    private func commitFinderTag() {
        guard let name = finderTagInput.nilIfBlank else { return }
        model.addFinderTag(name, to: [row])
        finderTagInput = ""
    }

    private func commitTag() {
        guard let name = tagInput.nilIfBlank else { return }
        model.addTag(name, to: [row])
        tagInput = ""
    }

    private var fileSection: some View {
        Section2("File") {
            InfoGrid {
                InfoRow("Where") {
                    Button { model.reveal([row]) } label: {
                        Text(shortPath).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.link)
                    .help(row.directory)
                }
                InfoRow("Size", ByteFormat.string(row.size))
                if let original = row.originalSize, let savings = row.savings {
                    InfoRow("Optimized") {
                        HStack(spacing: 6) {
                            Text("\(ByteFormat.string(original)) → \(ByteFormat.string(row.size)) (−\(Int(savings * 100))%)")
                            if let originalURL = detail.originalFileURL {
                                Button {
                                    QuickLookController.shared.toggle(urls: [originalURL])
                                } label: {
                                    Image(systemName: "eye")
                                }
                                .buttonStyle(.borderless)
                                .help("View the original, pre-optimization file")
                                Button(role: .destructive) {
                                    confirmingDeleteOriginal = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete the saved original — this cannot be undone")
                            }
                        }
                    }
                }
                InfoRow("Added", row.createdAt.formatted(date: .abbreviated, time: .shortened))
                InfoRow("Modified", row.mtime.formatted(date: .abbreviated, time: .shortened))
                if let words = detail.ocrWords, let src = detail.ocrSource {
                    InfoRow("Text") {
                        Text("\(words) words · \(ocrSourceLabel(src))")
                    }
                }
                if let hash = detail.hash {
                    InfoRow("SHA-256") {
                        Text(hash.prefix(16) + "…")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .help(hash)
                    }
                }
            }
        }
        .confirmationDialog("Delete the saved original of “\(row.displayTitle)”?",
                            isPresented: $confirmingDeleteOriginal) {
            Button("Delete", role: .destructive) { model.deleteOriginal(row) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pre-optimization file kept for Revert to Original is removed for good. The optimized file already in place is not touched.")
        }
    }

    private func ocrSourceLabel(_ s: String) -> String {
        switch s {
        case "pdf-layer": return "embedded text"
        case "vision": return "Vision OCR"
        case "mixed": return "text + OCR"
        case TextSource.locked: return "password-protected"
        default: return s
        }
    }

    private var shortPath: String {
        row.directory.abbreviatingHome
    }

    @ViewBuilder
    private var similarDocumentsSection: some View {
        Section2("Similar Documents") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(detail.similarDocuments.prefix(3)) { doc in
                    Button {
                        model.selectedIDs = [doc.id]
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(doc.displayTitle)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var aliasSection: some View {
        Section2("Finder Aliases") {
            ForEach(detail.aliases, id: \.self) { path in
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label((path as NSString).deletingLastPathComponent.components(separatedBy: "/").suffix(2).joined(separator: "/"),
                          systemImage: "arrow.triangle.branch")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var notesSection: some View {
        Section2("Notes") {
            NoteEditor(saved: detail.note, document: row.id)
        }
    }

    private var historySection: some View {
        Section2("History") {
            ForEach(detail.history.prefix(showAllHistory ? detail.history.count : 6)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: event.action.icon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(event.action.label).font(.caption).fontWeight(.medium)
                            Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let move = event.move(relativeTo: model.library?.root.path ?? "") {
                            Text(move).font(.caption2).foregroundStyle(.secondary)
                        } else if let note = event.detail?.nilIfBlank {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(event.action == .edited ? 8 : 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if detail.history.count > 6 {
                Button(showAllHistory ? "Show less"
                                      : "Show all \(detail.history.count) events") {
                    showAllHistory.toggle()
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    private var textSection: some View {
        Section2("Extracted Text") {
            if detail.text.isEmpty {
                Text(row.ocrState == .pending ? "Not indexed yet."
                     : detail.ocrSource == TextSource.locked ? "Password-protected: the text cannot be read without it."
                     : "No text found.")
                    .font(.callout).foregroundStyle(.tertiary)
            } else {
                DisclosureGroup(isExpanded: $showRawText) {
                    ScrollView {
                        Text(detail.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                } label: {
                    Text(showRawText ? "Hide raw text" : "Show raw text")
                        .font(.callout)
                }
            }
        }
    }
}

/// A text box for the document's one note, saved when it loses focus or the
/// inspector moves on to another document.
private struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    let saved: String
    let document: Int64

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
            .frame(minHeight: 80, maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Anything worth remembering about this document…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor),
                                  lineWidth: focused ? 2 : 1)
            }
            .onAppear { draft = saved }
            .onChange(of: saved) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, now in if !now { save() } }
            .onDisappear(perform: save)
    }

    private func save() {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) != saved else { return }
        model.setNote(draft, for: document)
    }
}

private struct MultiSelectionInspector: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(count) documents selected").font(.headline)
            let total = model.selectedRows.reduce(Int64(0)) { $0 + $1.size }
            InfoGrid { InfoRow("Total size", ByteFormat.string(total)) }
            Divider()
            Button("Optimize All") { model.optimize(model.selectedRows) }
            Button("Reprocess All") { model.reprocess(model.selectedRows) }
            Button("Analyze All with Model") { model.analyze(model.selectedRows) }
                .disabled(!model.modelStatus.isReady)
            Button("Reveal in Finder") { model.reveal(model.selectedRows) }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Section2<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }
}

struct InfoGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            content
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow<Value: View>: View {
    let label: String
    var alignment: VerticalAlignment = .firstTextBaseline
    @ViewBuilder let value: Value

    init(_ label: String, alignment: VerticalAlignment = .firstTextBaseline,
         @ViewBuilder value: () -> Value) {
        self.label = label
        self.alignment = alignment
        self.value = value()
    }

    var body: some View {
        GridRow(alignment: alignment) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension InfoRow where Value == Text {
    init(_ label: String, _ text: String) {
        self.init(label) { Text(text) }
    }
}

private struct FieldValueRow: View {
    @Environment(AppModel.self) private var model
    let field: Field
    let value: String
    let document: Int64

    var body: some View {
        switch field.type {
        case .boolean:
            InfoRow(field.name, alignment: .center) {
                Toggle("", isOn: Binding(
                    get: { FieldType.boolean(from: value) ?? false },
                    set: { model.setFieldValue(document, field: field, value: $0 ? "Yes" : "No") }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
        case .date:
            InfoRow(field.name, alignment: .center) {
                HStack(spacing: 5) {
                    DatePicker("", selection: Binding(
                        get: { FieldType.day(from: value) ?? Date() },
                        set: { model.setFieldValue(document, field: field,
                                                   value: FieldType.dayFormatter.string(from: $0)) }),
                        displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .dayResolution()
                    if !value.isEmpty {
                        Button {
                            model.setFieldValue(document, field: field, value: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Clear this date")
                    }
                }
            }
        case .select where !field.options.isEmpty:
            InfoRow(field.name, alignment: .center) {
                Picker("", selection: Binding(
                    get: { value },
                    set: { model.setFieldValue(document, field: field, value: $0.nilIfBlank) })) {
                    Text("—").tag("")
                    ForEach(field.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .labelsHidden()
            }
        case .url where !value.isEmpty:
            InfoRow(field.name, alignment: .center) {
                HStack(spacing: 5) {
                    if let url = URL(string: value), url.scheme != nil {
                        Link(value, destination: url).lineLimit(1)
                    } else {
                        Text(value).lineLimit(1)
                    }
                    Button {
                        model.setFieldValue(document, field: field, value: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
        default:
            EditableRow(field.name, value: value) {
                model.setFieldValue(document, field: field, value: $0)
            }
        }
    }
}

struct EditableRow: View {
    let label: String
    let value: String
    let onCommit: (String?) -> Void
    @State private var draft: String

    init(_ label: String, value: String, onCommit: @escaping (String?) -> Void) {
        self.label = label
        self.value = value
        self.onCommit = onCommit
        self._draft = State(initialValue: value)
    }

    var body: some View {
        InfoRow(label, alignment: .center) {
            TextField("", text: $draft, prompt: Text("—"))
                .textFieldStyle(.plain)
                .onSubmit { if draft != value { onCommit(draft) } }
                .onChange(of: value) { old, new in if draft == old { draft = new } }
        }
    }
}

extension View {
    /// Puts a date control on the same clock the days are stored on. Without
    /// it, picking 4 March east of Greenwich hands back an instant that is
    /// still 3 March in UTC, and the day is saved one off.
    func dayResolution() -> some View {
        environment(\.timeZone, TimeZone(secondsFromGMT: 0) ?? .gmt)
            .environment(\.calendar, DayDate.calendar)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
