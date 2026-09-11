import SwiftUI
import AppKit

/// The lower half of the approval view: the document selected above, what the
/// pipeline worked out about it, and where it should live.
///
/// Everything generated is editable in place, or can be thrown away in one go.
/// Filing is two decisions, laid out side by side for every candidate folder:
/// the one folder the file itself lives in (moved there on apply), and any
/// others it should also appear in as a Finder alias.
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

// MARK: - One document

private struct DocumentReview: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    private var row: DocumentRow { detail.row }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                GeneratedInfoEditor(detail: detail)
                    .frame(minWidth: 250, idealWidth: 330, maxWidth: 400)
                Divider()
                FilingEditor(detail: detail, mode: .review)
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

// MARK: - Generated information

/// What the pipeline worked out, every value editable where it stands, and
/// one button to throw the lot away.
private struct GeneratedInfoEditor: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
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
                        }
                    }
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
        }
        .confirmationDialog("Discard what was generated for “\(row.displayTitle)”?",
                            isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { model.discardGeneratedInfo([row]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The title, correspondent, type, language, summary and date that were worked out are cleared, with the tags rules assigned and every pending suggestion. Your own edits, the extracted text and the file itself are kept — Analyze with Model can fill it in again.")
        }
    }

    private var hasGenerated: Bool {
        detail.metadataSource != nil || !detail.tagSuggestions.isEmpty || !detail.pathSuggestions.isEmpty
            || row.title != nil || row.correspondent != nil || row.docType != nil
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 5) {
            FlowLayout(spacing: 4) {
                ForEach(detail.tags) { tag in
                    let color = TagColor.color(tag.color)
                    HStack(spacing: 3) {
                        Image(systemName: "tag").font(.system(size: 8)).foregroundStyle(color)
                        Text(tag.name).font(.caption)
                        Button { model.removeTag(tag, from: [row]) } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Remove “\(tag.name)”")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(color.opacity(0.45)))
                }
                // Suggestions sit alongside, dashed, so accepting one is a
                // click away rather than a trip to the inspector.
                ForEach(detail.tagSuggestions) { suggestion in
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").font(.system(size: 8)).foregroundStyle(.secondary)
                        Text(suggestion.name).font(.caption)
                        Button { model.discardTagSuggestion(suggestion, for: row) } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss “\(suggestion.name)”")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5),
                                                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Capsule())
                    .onTapGesture { model.acceptTagSuggestion(suggestion, for: row) }
                    .help("Click to accept “\(suggestion.name)”")
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
        switch s {
        case "llm": return "on-device model"
        case "remote": return "API model"
        default: return "heuristics"
        }
    }
}

// MARK: - Filing

/// One folder a document could be filed in, and why it is on the list.
struct FilingOption: Identifiable, Hashable {
    enum Kind { case current, suggested, alias, similar, chosen }
    var id: String { path }
    var path: String
    var kind: Kind
    var reason: String?
    var confidence: Double?
}

/// Picks where a document lives. Each candidate folder is one row with two
/// controls: a radio button for the single folder the file itself is in, and
/// a checkbox for each other folder it should also appear in as an alias.
/// Nothing happens on disk until the button at the bottom is pressed.
struct FilingEditor: View {
    enum Mode {
        /// In the approval view: applying also approves and moves on.
        case review
        /// In a sheet from the context menu: apply, or cancel.
        case sheet(dismiss: () -> Void)
    }

    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    let mode: Mode

    @State private var primary: String
    @State private var secondaries: Set<String>
    @State private var chosen: [FilingOption] = []

    init(detail: DocumentDetail, mode: Mode) {
        self.detail = detail
        self.mode = mode
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

    /// The current folder first, then what the router suggested, where the
    /// document already has aliases, where documents like it live, and
    /// anything picked by hand — each folder once.
    private var options: [FilingOption] {
        // A document the router filed is usually sitting in its own best
        // suggestion, so the current folder carries that suggestion's reason.
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

    // MARK: Adding a folder

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

    /// A folder picked by hand becomes the primary: picking a folder from a
    /// menu is almost always "put it here". The checkbox is still there for
    /// "also here".
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

    // MARK: Footer

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
                    .disabled(!changed && row.approved)
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
        case (false, false, _): return "Approve"
        case (true, _, false): return "Move & Approve"
        case (false, true, false): return "File & Approve"
        default: return "Apply"
        }
    }

    private func apply(approve: Bool, advance: Bool) {
        model.file(row, in: URL(fileURLWithPath: primary, isDirectory: true), alsoIn: secondaries,
                   approve: approve, advance: advance && model.selection.isQueueMode)
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
            // A similar folder's number is a share of documents, not a
            // confidence, so it is not dressed up as one.
            if let c = option.confidence, option.kind != .similar {
                ConfidenceBadge(value: c)
            }
            // The radio: the folder the file itself is in.
            Image(systemName: isPrimary ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isPrimary ? Color.accentColor : .secondary)
                .frame(width: 66)
                .accessibilityLabel(isPrimary ? "Lives here" : "Make this where it lives")
            // The checkbox: an alias here as well.
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

/// The library's folder tree as nested menus, each folder offering itself
/// before its subfolders.
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

// MARK: - Several documents

private struct BulkReview: View {
    @Environment(AppModel.self) private var model
    let rows: [DocumentRow]
    @State private var confirmingDiscard = false

    /// Moving a mixed selection only makes sense within one library.
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

// MARK: - Filing from anywhere

/// The same folder picker, for a document outside the approval view: the
/// context menu's "File In…". Loads the document's detail itself, since the
/// row right-clicked need not be the one the inspector is showing.
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
