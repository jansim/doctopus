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
    @State private var tagInput = ""
    @State private var finderTagInput = ""

    private var row: DocumentRow { detail.row }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                summarySection
                metadataSection
                tagsSection
                if !detail.tagSuggestions.isEmpty { tagSuggestionsSection }
                finderTagsSection
                fileSection
                if !detail.aliases.isEmpty { aliasSection }
                textSection
            }
            .padding(14)
        }
        .id(row.id)
    }

    /// The model's own output, with the button that produced it. Documents
    /// indexed before a model was configured land here with nothing to show,
    /// which is exactly when someone wants to run it by hand.
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
            }
            Button {
                model.analyze([row])
            } label: {
                Label(row.summary == nil ? "Analyze with Model" : "Analyze Again",
                      systemImage: "sparkles")
                    .font(.callout)
            }
            .buttonStyle(.link)
            .disabled(!model.modelStatus.isReady || analyzing)
        }
    }

    // MARK: - Header

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

    // MARK: - Metadata

    private var metadataSection: some View {
        Section2("Metadata") {
            InfoGrid {
                EditableRow("Title", value: row.title ?? "") {
                    model.editMetadata(row.id, column: "title", value: $0)
                }
                // Every configured field, in the order Settings puts them.
                ForEach(model.fields) { field in
                    EditableRow(field.name, value: row.values[field.key] ?? "") {
                        model.setFieldValue(row.id, field: field, value: $0)
                    }
                }
                InfoRow("Date", alignment: .center) {
                    HStack(spacing: 5) {
                        DatePicker("", selection: Binding(
                            get: { row.docDate ?? row.createdAt },
                            set: { model.setDocumentDate(row.id, $0) }),
                            displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
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
                        HStack(spacing: 5) {
                            Text(Self.sourceLabel(source))
                            if let c = detail.metadataConfidence {
                                ConfidenceBadge(value: c)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func sourceLabel(_ s: String) -> String {
        switch s {
        case "llm": return "On-device model"
        case "remote": return "API model"
        default: return "Heuristics"
        }
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

    // MARK: - Tags

    private var tagsSection: some View {
        Section2("Tags") {
            if detail.tags.isEmpty {
                Text("No tags").font(.callout).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(detail.tags) { tag in
                        let color = TagColor.color(tag.color)
                        HStack(spacing: 4) {
                            Image(systemName: "tag")
                                .font(.system(size: 9))
                                .foregroundStyle(color)
                            Text(tag.name).font(.caption)
                            Button {
                                model.removeTag(tag, from: [row])
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(color.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(color.opacity(0.45)))
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

    /// Tags the model proposed. These are not real tags yet — they carry no
    /// count and never appear in the sidebar — until someone clicks them to
    /// accept, or dismisses them with the ×.
    private var tagSuggestionsSection: some View {
        Section2("Suggested Tags") {
            FlowLayout(spacing: 5) {
                ForEach(detail.tagSuggestions) { suggestion in
                    let color = suggestionColor(suggestion.name)
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(color)
                        Text(suggestion.name).font(.caption)
                        Button {
                            model.discardTagSuggestion(suggestion, for: row)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(color.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Capsule())
                    .onTapGesture { model.acceptTagSuggestion(suggestion, for: row) }
                    .help("Click to accept “\(suggestion.name)”, or dismiss it with ×")
                }
            }
        }
    }

    /// A suggestion already in use elsewhere borrows that tag's colour, so it
    /// previews exactly how it will look once accepted.
    private func suggestionColor(_ name: String) -> Color {
        if let existing = model.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return TagColor.color(existing.color)
        }
        return .secondary
    }

    /// The Finder's tags live on the file and are shared with every other app,
    /// so they get their own section rather than being mixed in above.
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
                        // The dot carries the colour, so the token stays
                        // neutral — the way a Finder tag token does.
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

    // MARK: - File

    private var fileSection: some View {
        Section2("File") {
            InfoGrid {
                // Only worth naming when there is more than one to be in.
                if model.libraries.count > 1,
                   let library = model.library(row.library) {
                    InfoRow("Library", library.displayName)
                }
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
                        Text("\(ByteFormat.string(original)) → \(ByteFormat.string(row.size)) (−\(Int(savings * 100))%)")
                            .foregroundStyle(.green)
                    }
                }
                InfoRow("Added", row.createdAt.formatted(date: .abbreviated, time: .shortened))
                InfoRow("Modified", row.mtime.formatted(date: .abbreviated, time: .shortened))
                if let words = detail.ocrWords, let src = detail.ocrSource {
                    InfoRow("Text") {
                        HStack(spacing: 5) {
                            Text("\(words) words · \(ocrSourceLabel(src))")
                            if let c = detail.ocrConfidence, src != "pdf-layer" {
                                ConfidenceBadge(value: c)
                            }
                        }
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
    }

    private func ocrSourceLabel(_ s: String) -> String {
        switch s {
        case "pdf-layer": return "embedded text"
        case "vision": return "Vision OCR"
        case "mixed": return "text + OCR"
        default: return s
        }
    }

    private var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return row.directory.hasPrefix(home) ? "~" + row.directory.dropFirst(home.count) : row.directory
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

    // MARK: - Raw text

    private var textSection: some View {
        Section2("Extracted Text") {
            if detail.text.isEmpty {
                Text(row.ocrState == .pending ? "Not indexed yet." : "No text found.")
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

// MARK: - Small pieces

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

struct ConfidenceBadge: View {
    let value: Double
    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .help("Confidence")
    }
    private var color: Color { value >= 0.85 ? .green : (value >= 0.6 ? .orange : .red) }
}

/// Finder-style property list: right-aligned labels in their own gutter, all
/// values starting at one shared edge. `LabeledContent` pushed the two apart to
/// opposite sides of the inspector, which made a row hard to read as a pair.
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

/// Click-to-edit value that only writes back on commit. Empty reads as an
/// em dash so a blank row still looks like a row.
struct EditableRow: View {
    let label: String
    @State private var draft: String
    private let committed: String
    let onCommit: (String?) -> Void

    init(_ label: String, value: String, onCommit: @escaping (String?) -> Void) {
        self.label = label
        self.committed = value
        self._draft = State(initialValue: value)
        self.onCommit = onCommit
    }

    var body: some View {
        InfoRow(label, alignment: .center) {
            TextField("", text: $draft, prompt: Text("—"))
                .textFieldStyle(.plain)
                .onSubmit { if draft != committed { onCommit(draft) } }
        }
    }
}

/// Minimal wrapping layout for tag chips.
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
