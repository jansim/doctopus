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

    private var row: DocumentRow { detail.row }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                if let summary = row.summary {
                    Section2("Summary") {
                        Text(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                metadataSection
                tagsSection
                fileSection
                if !detail.aliases.isEmpty { aliasSection }
                textSection
            }
            .padding(14)
        }
        .id(row.id)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ThumbnailView(url: row.url)
                .frame(width: 54, height: 70)
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
            EditableField("Title", value: row.title ?? "") {
                model.editMetadata(row.id, column: "title", value: $0)
            }
            EditableField("Correspondent", value: row.correspondent ?? "") {
                model.editMetadata(row.id, column: "correspondent", value: $0)
            }
            EditableField("Type", value: row.docType ?? "") {
                model.editMetadata(row.id, column: "doc_type", value: $0)
            }
            LabeledContent("Document Date") {
                HStack(spacing: 4) {
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
            if let lang = row.language {
                LabeledContent("Language",
                               value: Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang)
            }
            if let intent = detail.intent {
                LabeledContent("Intent", value: intent.capitalized)
            }
            if let amount = detail.amount {
                LabeledContent("Amount", value: amount)
            }
            if let source = detail.metadataSource {
                LabeledContent("Extracted by") {
                    HStack(spacing: 5) {
                        Text(source == "llm" ? "On-device model" : "Heuristics")
                        if let c = detail.metadataConfidence {
                            ConfidenceBadge(value: c)
                        }
                    }
                }
            }
        }
        .font(.callout)
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
                        HStack(spacing: 3) {
                            Text(tag.name).font(.caption)
                            Button {
                                model.removeTag(tag, from: [row])
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(TagColor.color(for: tag.name).opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(TagColor.color(for: tag.name).opacity(0.35)))
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

    private func commitTag() {
        guard let name = tagInput.nilIfBlank else { return }
        model.addTag(name, to: [row])
        tagInput = ""
    }

    // MARK: - File

    private var fileSection: some View {
        Section2("File") {
            LabeledContent("Location") {
                Button {
                    model.reveal([row])
                } label: {
                    Text(shortPath).lineLimit(2).multilineTextAlignment(.trailing)
                }
                .buttonStyle(.link)
                .help(row.directory)
            }
            LabeledContent("Size", value: ByteFormat.string(row.size))
            if let original = row.originalSize, let savings = row.savings {
                LabeledContent("Optimized") {
                    Text("\(ByteFormat.string(original)) → \(ByteFormat.string(row.size)) (−\(Int(savings * 100))%)")
                        .foregroundStyle(.green)
                }
            }
            LabeledContent("Added", value: row.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Modified", value: row.mtime.formatted(date: .abbreviated, time: .shortened))
            if let words = detail.ocrWords, let src = detail.ocrSource {
                LabeledContent("Text") {
                    HStack(spacing: 5) {
                        Text("\(words) words · \(ocrSourceLabel(src))")
                        if let c = detail.ocrConfidence, src != "pdf-layer" {
                            ConfidenceBadge(value: c)
                        }
                    }
                }
            }
            if let hash = detail.hash {
                LabeledContent("SHA-256") {
                    Text(hash.prefix(16) + "…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .help(hash)
                }
            }
        }
        .font(.callout)
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
            LabeledContent("Total size", value: ByteFormat.string(total))
            Divider()
            Button("Optimize All") { model.optimize(model.selectedRows) }
            Button("Reprocess All") { model.reprocess(model.selectedRows) }
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

/// Click-to-edit text field that only writes back on commit.
struct EditableField: View {
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
        LabeledContent(label) {
            TextField("", text: $draft, prompt: Text("—"))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .onSubmit { if draft != committed { onCommit(draft) } }
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc").foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 108, height: 140),
            scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return }
        image = rep.nsImage
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
