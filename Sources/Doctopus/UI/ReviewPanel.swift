import SwiftUI
import AppKit

/// Filing is two decisions per candidate folder: the one folder the file lives
/// in (moved there on apply), and any others it appears in as a Finder alias.
struct ReviewPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.selectedIDs.count == 1, let detail = model.detail,
               model.selectedIDs.contains(detail.row.id) {
                DocumentReview(detail: detail)
                    .id(detail.row.id)
            } else if model.selectedIDs.count > 1 {
                BulkReview(rows: model.selectedRows)
            } else {
                ContentUnavailableView {
                    Label("Nothing selected", systemImage: "checklist")
                } description: {
                    Text("Select a document above to check what was worked out and choose where it lives.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct DocumentReview: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    @State private var keepOriginal = false
    @State private var optimize = false
    private var row: DocumentRow { detail.row }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                GeneratedInfoEditor(detail: detail, keepOriginal: $keepOriginal, optimize: $optimize)
                    .frame(minWidth: 250, idealWidth: 330, maxWidth: 400)
                Divider()
                FilingEditor(detail: detail, mode: .review, keepOriginal: keepOriginal, optimize: optimize)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Thumbnail(url: row.url, mtime: row.mtime, size: .row,
                      width: 24, height: 31, cornerRadius: 2)
                .onTapGesture { model.quickLook(startingAt: row) }
                .help("Quick Look")
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayTitle)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                if let queue = row.queue ?? model.documents.first(where: { $0.id == row.id })?.queue,
                   let what = queue.detail {
                    Text(what)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if row.approved {
                Badge("Approved", tint: .green)
            } else {
                Badge("Needs review", tint: .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct GeneratedInfoEditor: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    @Binding var keepOriginal: Bool
    @Binding var optimize: Bool
    @State private var tagInput = ""
    @State private var confirmingDiscard = false
    private var row: DocumentRow { detail.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORKED OUT")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                if let source = detail.metadataSource {
                    Text(sourceLabel(source)).font(.caption2).foregroundStyle(.tertiary)
                    if let c = detail.metadataConfidence { ConfidenceBadge(value: c) }
                }
                Spacer()
                Button("Discard…", role: .destructive) { confirmingDiscard = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Throw away what was generated for this document")
                    .disabled(!hasGenerated)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    InfoGrid {
                        EditableRow("Title", value: row.title ?? "") {
                            model.editMetadata(row.id, column: "title", value: $0)
                        }
                        ForEach(model.fields) { field in
                            EditableRow(field.name, value: row.values[field.key] ?? "") {
                                model.setFieldValue(row.id, field: field, value: $0)
                            }
                        }
                        InfoRow("Date", alignment: .center) {
                            DatePicker("", selection: Binding(
                                get: { row.docDate ?? row.createdAt },
                                set: { model.setDocumentDate(row.id, $0) }),
                                displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .dayResolution()
                        }
                    }
                    if detail.dateCandidates.count > 1 { dateChoices }
                    if let summary = row.summary {
                        Text(summary)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    tags
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if let originalURL = detail.originalFileURL {
                Divider()
                originalSection(originalURL)
            } else if row.originalSize == nil {
                Divider()
                optimizeSection
            }
        }
        .confirmationDialog("Discard what was generated for “\(row.displayTitle)”?",
                            isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { model.discardGeneratedInfo([row]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The title, correspondent, type, language, summary and date that were worked out are cleared, with the tags rules assigned and every pending suggestion. Your own edits, the extracted text and the file itself are kept — Analyze with Model can fill it in again.")
        }
    }

    private func originalSection(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Thumbnail(url: url, mtime: row.mtime, size: .row,
                      width: 28, height: 36, cornerRadius: 2)
                .onTapGesture { QuickLookController.shared.toggle(urls: [url]) }
                .help("Quick Look the original, pre-optimization file")
            VStack(alignment: .leading, spacing: 3) {
                Text("Original available").font(.caption).foregroundStyle(.secondary)
                Toggle("Keep the original", isOn: $keepOriginal)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help("Approving deletes the pre-optimization original unless this is checked")
    }

    /// Never ticked by default: a file that was not optimized on the way in is
    /// only rewritten when someone asks for it here.
    private var optimizeSection: some View {
        Toggle("Optimize when approving", isOn: $optimize)
            .toggleStyle(.checkbox)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .help("Compress the file when this is applied. The original is kept, so it can be reverted.")
    }

    private var hasGenerated: Bool {
        detail.metadataSource != nil || !detail.tagSuggestions.isEmpty || !detail.pathSuggestions.isEmpty
            || row.title != nil || row.correspondent != nil || row.docType != nil
    }

    private var dateChoices: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALSO FOUND")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            FlowLayout(spacing: 5) {
                ForEach(detail.dateCandidates) { candidate in
                    let chosen = row.docDate == candidate.date
                    Button {
                        model.setDocumentDate(row.id, candidate.date)
                    } label: {
                        HStack(spacing: 4) {
                            Text(DayDate.display(candidate.date)).font(.caption)
                            Text(candidate.cue ?? candidate.sourceLabel)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(chosen ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(candidate.labelled
                          ? "Labelled “\(candidate.cue ?? "")” \(candidate.sourceLabel)"
                          : "Found \(candidate.sourceLabel)")
                }
            }
        }
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 5) {
            FlowLayout(spacing: 4) {
                ForEach(Tag.visible(in: detail.tags), id: \.tag.id) { entry in
                    TagChip(tag: entry.tag, displayName: entry.path, compact: true) {
                        model.removeTag(entry.tag, from: [row])
                    }
                }
                ForEach(detail.tagSuggestions) { suggestion in
                    TagSuggestionChip(
                        suggestion: suggestion, compact: true,
                        onAccept: { model.acceptTagSuggestion(suggestion, for: row) },
                        onDiscard: { model.discardTagSuggestion(suggestion, for: row) })
                }
            }
            TextField("Add tag", text: $tagInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    guard let name = tagInput.nilIfBlank else { return }
                    model.addTag(name, to: [row])
                    tagInput = ""
                }
        }
    }

    private func sourceLabel(_ s: String) -> String {
        MetadataSource(s).inlineLabel
    }
}

struct FilingOption: Identifiable, Hashable {
    enum Kind { case current, suggested, alias, similar, chosen }
    var id: String { path }
    var path: String
    var kind: Kind
    var reason: String?
    var confidence: Double?
}

struct FilingEditor: View {
    enum Mode {
        case review
        case sheet(dismiss: () -> Void)
    }

    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    let mode: Mode
    var keepOriginal: Bool
    var optimize: Bool

    @State private var primary: String
    @State private var secondaries: Set<String>
    @State private var chosen: [FilingOption] = []

    /// Starts on the folder the file is in now, whatever was suggested: filing
    /// it anywhere else is always a choice made here.
    init(detail: DocumentDetail, mode: Mode, keepOriginal: Bool = true, optimize: Bool = false) {
        self.detail = detail
        self.mode = mode
        self.keepOriginal = keepOriginal
        self.optimize = optimize
        _primary = State(initialValue: detail.row.directory)
        _secondaries = State(initialValue: Set(detail.folderAliases.map {
            ($0 as NSString).deletingLastPathComponent }))
    }

    private var row: DocumentRow { detail.row }
    private var library: Library? { model.library(row.library) }
    private var existingSecondaries: Set<String> {
        Set(detail.folderAliases.map { ($0 as NSString).deletingLastPathComponent })
    }
    private var changed: Bool { primary != row.directory || secondaries != existingSecondaries }

    private var options: [FilingOption] {
        let here = detail.pathSuggestions.first { $0.path == row.directory }
        var out: [FilingOption] = [FilingOption(
            path: row.directory, kind: .current,
            reason: here.map { "Where it is now — \($0.explanation ?? $0.source)" } ?? "Where it is now",
            confidence: here?.confidence)]
        out += detail.pathSuggestions.map {
            FilingOption(path: $0.path, kind: .suggested, reason: $0.explanation, confidence: $0.confidence)
        }
        out += existingSecondaries.sorted().map {
            FilingOption(path: $0, kind: .alias, reason: "Already filed here as an alias")
        }
        out += detail.similarFolders.map { FilingOption(path: $0.path, kind: .similar, reason: $0.explanation) }
        out += chosen
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("FILE IN")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                Spacer()
                Text("Lives here").frame(width: 66)
                Text("Also here").frame(width: 66)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(options) { option in
                        FilingRow(option: option,
                                  label: displayPath(option.path),
                                  isPrimary: primary == option.path,
                                  isSecondary: Binding(
                                    get: { secondaries.contains(option.path) && primary != option.path },
                                    set: { on in
                                        if on { secondaries.insert(option.path) } else { secondaries.remove(option.path) }
                                    }),
                                  choosePrimary: {
                                      primary = option.path
                                      secondaries.remove(option.path)
                                  })
                    }
                    otherFolderMenu
                        .padding(.horizontal, 8).padding(.top, 4)
                }
                .padding(.horizontal, 4)
            }

            Divider()
            footer
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var otherFolderMenu: some View {
        if let library {
            Menu {
                if let rootNode = library.folders.first {
                    Button("\(library.displayName) (top level)") { choose(rootNode.path) }
                    FolderMenuItems(nodes: rootNode.children) { choose($0) }
                }
                Divider()
                Button("New Folder…") { newFolder(in: library) }
                Button("Choose in Finder…") { pick(in: library) }
            } label: {
                Label("Other Folder…", systemImage: "folder.badge.plus")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func choose(_ path: String) {
        if !options.contains(where: { $0.path == path }) {
            chosen.append(FilingOption(path: path, kind: .chosen, reason: "Chosen by you"))
        }
        primary = path
        secondaries.remove(path)
    }

    private func newFolder(in library: Library) {
        guard let typed = TextPrompt.ask(
            title: "New Folder",
            message: "A folder inside \(library.displayName). Use / for folders within folders, like Finances/Utilities. It is created when you apply.",
            initial: "", confirm: "Add") else { return }
        // Only plain names: no way out of the library, and not into its index.
        let parts = typed.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".doctopus") }
        guard !parts.isEmpty else { return }
        let url = parts.reduce(library.root) { $0.appendingPathComponent($1, isDirectory: true) }
        choose(url.path)
    }

    private func pick(in library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: primary)
        panel.prompt = "File Here"
        panel.message = "Choose a folder inside \(library.displayName)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = Store.canonical(url.standardizedFileURL.path)
        guard library.owns(path: path), !FileScanner.isInsideLibraryContainer(url) else {
            model.errorMessage = "“\(url.lastPathComponent)” is outside \(library.displayName). A document can only be filed within its own library."
            return
        }
        choose(path)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("The file lives in one folder. Tick others to file it there too, as a Finder alias — nothing is copied.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch mode {
            case .review:
                if changed {
                    Button("Revert") {
                        primary = row.directory
                        secondaries = existingSecondaries
                    }
                }
                Button(reviewTitle) { apply(approve: true, advance: true) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(!changed && !optimize && row.approved)
                    .help("⌘↩")
            case .sheet(let dismiss):
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("File") {
                    apply(approve: false, advance: false)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!changed)
            }
        }
    }

    private var reviewTitle: String {
        let moves = primary != row.directory
        let aliases = secondaries != existingSecondaries
        switch (moves, aliases, row.approved) {
        case (false, false, true) where optimize: return "Optimize"
        case (false, false, _): return "Approve"
        case (true, _, false): return "Move & Approve"
        case (false, true, false): return "File & Approve"
        default: return "Apply"
        }
    }

    private func apply(approve: Bool, advance: Bool) {
        model.file(row, in: URL(fileURLWithPath: primary, isDirectory: true), alsoIn: secondaries,
                   approve: approve, keepOriginal: keepOriginal, optimize: optimize,
                   advance: advance && model.selection.isQueueMode)
    }

    private func displayPath(_ path: String) -> String {
        guard let library else { return path }
        let root = library.root.path
        if path == root { return "\(library.displayName) (top level)" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }
}

private struct FilingRow: View {
    let option: FilingOption
    let label: String
    let isPrimary: Bool
    @Binding var isSecondary: Bool
    let choosePrimary: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isPrimary ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label)
                        .lineLimit(1).truncationMode(.head)
                        .fontWeight(isPrimary ? .semibold : .regular)
                    if option.kind == .current {
                        Text("current").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let reason = option.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let c = option.confidence, option.kind != .similar {
                ConfidenceBadge(value: c)
            }
            Image(systemName: isPrimary ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isPrimary ? Color.accentColor : .secondary)
                .frame(width: 66)
                .accessibilityLabel(isPrimary ? "Lives here" : "Make this where it lives")
            Toggle("", isOn: $isSecondary)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isPrimary)
                .frame(width: 66)
                .help(isPrimary ? "The file itself lives here" : "Also file it here, as a Finder alias")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isPrimary ? Color.accentColor.opacity(0.14)
                      : hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: choosePrimary)
        .help(option.reason ?? label)
    }

    private var icon: String {
        switch option.kind {
        case .current: return "folder"
        case .suggested: return "sparkles"
        case .alias: return "arrow.up.forward.square"
        case .similar: return "square.stack"
        case .chosen: return "folder.badge.plus"
        }
    }
}

struct FolderMenuItems: View {
    let nodes: [FolderNode]
    let action: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                Button(node.name) { action(node.path) }
            } else {
                Menu(node.name) {
                    Button("File in “\(node.name)”") { action(node.path) }
                    Divider()
                    AnyView(FolderMenuItems(nodes: node.children, action: action))
                }
            }
        }
    }
}

private struct BulkReview: View {
    @Environment(AppModel.self) private var model
    let rows: [DocumentRow]
    @State private var confirmingDiscard = false

    private var library: Library? {
        let ids = Set(rows.map(\.library))
        return ids.count == 1 ? ids.first.flatMap(model.library) : nil
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("\(rows.count) documents selected").font(.headline)
            HStack(spacing: 10) {
                Button("Approve \(rows.count)") { model.setApproved(rows, true) }
                    .buttonStyle(.borderedProminent)
                if let library, let rootNode = library.folders.first {
                    Menu("Move All To") {
                        Button("\(library.displayName) (top level)") { moveAll(to: rootNode.path) }
                        FolderMenuItems(nodes: rootNode.children) { moveAll(to: $0) }
                    }
                    .fixedSize()
                }
                Button("Discard Generated Info…", role: .destructive) { confirmingDiscard = true }
            }
            Text("Choose a single document to see its suggested folders.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Discard what was generated for \(rows.count) documents?",
                            isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { model.discardGeneratedInfo(rows) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Titles, correspondents, types, languages, summaries and dates that were worked out are cleared, with rule tags and pending suggestions. Your own edits and the files themselves are kept.")
        }
    }

    private func moveAll(to path: String) {
        model.move(rows, to: URL(fileURLWithPath: path, isDirectory: true))
    }
}

struct FilingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: DocumentRow
    @State private var detail: DocumentDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Thumbnail(url: row.url, mtime: row.mtime, size: .row,
                          width: 24, height: 31, cornerRadius: 2)
                Text("File “\(row.displayTitle)”").font(.headline).lineLimit(1)
                Spacer()
            }
            .padding(12)
            Divider()
            if let detail {
                FilingEditor(detail: detail, mode: .sheet(dismiss: { dismiss() }))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 400)
        .task { detail = await model.loadDetail(row.id) }
    }
}
