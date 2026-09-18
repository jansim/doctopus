import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var iconTarget: IconTarget?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            // Everything in this first section spans every open library.
            Section(model.libraries.count > 1 ? "All Libraries" : "Library") {
                row(.all, "All Documents", "tray.full", model.stats.total)
                // Needs Review is the queue filtered to undecided entries, so
                // its count comes from the same place the queue's does.
                row(.needsReview, "Needs Review", "exclamationmark.triangle",
                    model.queue.filter { !$0.approved }.count)
                row(.untagged, "Untagged", "tag.slash", nil)
                row(.queue, "Recent Processing", "clock.arrow.circlepath", model.queue.count)
                // Only worth a row when there is something in it: an empty
                // Trash is not a place anyone needs to visit.
                if model.stats.deleted > 0 {
                    row(.deleted, "Recently Deleted", "trash", model.stats.deleted)
                }
            }

            if !model.savedViews.isEmpty {
                Section("Smart Folders") {
                    ForEach(model.savedViews) { sv in
                        Label {
                            HStack {
                                Text(sv.name).lineLimit(1)
                                Spacer()
                            }
                        } icon: {
                            Image(systemName: sv.icon)
                        }
                        .tag(Selection.savedView(id: sv.id, query: sv.query))
                        .contextMenu {
                            Button("Delete Smart Folder", role: .destructive) {
                                model.deleteSavedView(sv)
                            }
                        }
                    }
                }
            }

            // Folders and tags belong to one library each, so with more than
            // one open they are grouped under it. A single library needs no
            // such header — its name is the window's, and the plain Folders /
            // Tags sections read better.
            if model.libraries.count == 1, let library = model.libraries.first {
                if !library.folders.isEmpty {
                    Section("Folders") {
                        ForEach(library.folders) { node in
                            FolderRow(node: node, depth: 0)
                        }
                    }
                }
                Section("Tags") {
                    tagRows(library)
                }
            } else {
                ForEach(model.libraries) { library in
                    Section {
                        ForEach(library.folders) { node in
                            FolderRow(node: node, depth: 0)
                        }
                        tagRows(library)
                    } header: {
                        LibraryHeader(library: library)
                    }
                }
            }

            // The Finder's tags, kept clearly apart from Doctopus's own: these
            // live on the files themselves and are shared with every other app.
            if !model.finderTags.isEmpty {
                Section("Finder Tags") {
                    ForEach(model.finderTags) { tag in
                        Label {
                            HStack {
                                Text(tag.value).lineLimit(1)
                                Spacer()
                                CountBadge(tag.count)
                            }
                        } icon: {
                            FinderTagDot(name: tag.value)
                        }
                        .tag(Selection.finderTag(tag.value))
                        .dropDestination(for: DocumentDragItem.self) { items, _ in
                            model.addFinderTag(tag.value, to: model.rows(forDropped: items))
                            return true
                        }
                    }
                }
            }

            // Facet sections are entirely configuration-driven: which fields
            // appear here, in what order, and under what name comes from
            // Settings rather than being wired into the view.
            ForEach(model.fields.filter(\.showInSidebar)) { field in
                let values = model.facets[field.key] ?? []
                if !values.isEmpty {
                    Section(field.name) {
                        ForEach(values.prefix(50)) { facet in
                            Label {
                                HStack {
                                    Text(display(facet.value, field: field)).lineLimit(1)
                                    Spacer()
                                    CountBadge(facet.count)
                                }
                            } icon: {
                                Image(systemName: facet.icon ?? field.icon)
                            }
                            .tag(Selection.field(field.key, facet.value))
                            .contextMenu { facetMenu(field, facet) }
                            .dropDestination(for: DocumentDragItem.self) { items, _ in
                                model.handleDrop(items, action: .field(field, value: facet.value))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter() }
        .sheet(item: $iconTarget) { target in
            IconPicker(title: target.facet.value,
                       current: target.facet.icon ?? target.field.icon,
                       fallback: target.field.icon) { icon in
                model.setValueIcon(target.field, value: target.facet.value, icon: icon)
            }
        }
    }

    // MARK: - Rows

    /// A library's tags, and the button that adds one to that same library.
    @ViewBuilder
    private func tagRows(_ library: Library) -> some View {
        ForEach(library.tags) { tag in
            TagRow(tag: tag, siblings: library.tags)
        }
        Button {
            guard let name = TextPrompt.ask(title: "New Tag",
                                            message: "Tags can be dragged onto from the document list.",
                                            initial: "", confirm: "Create") else { return }
            model.createTag(named: name, in: library)
        } label: {
            Label("New Tag…", systemImage: "plus")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .buttonStyle(.plain)
    }

    private func row(_ selection: Selection, _ title: String, _ icon: String, _ count: Int?) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if let count, count > 0 { CountBadge(count) }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(selection)
    }

    private func display(_ value: String, field: Field) -> String {
        guard field.builtinColumn == "language" else { return value }
        return Locale.current.localizedString(forLanguageCode: value)?.capitalized ?? value.uppercased()
    }

    // MARK: - Context menus

    @ViewBuilder
    private func facetMenu(_ field: Field, _ facet: Facet) -> some View {
        Button("Change Icon…") { iconTarget = IconTarget(field: field, facet: facet) }
        Button("Rename “\(facet.value)”…") {
            guard let new = TextPrompt.ask(
                title: "Rename \(field.name)",
                message: "Renaming to a name already in use merges the two — every document keeps its other metadata.",
                initial: facet.value) else { return }
            model.renameFieldValue(field, from: facet.value, to: new)
        }
        // A taxonomy value can identify itself. This is how most
        // classification gets done with no model involved at all.
        if Store.entityColumn(for: field.builtinColumn) != nil {
            Button("Identify by…") {
                guard let pattern = TextPrompt.ask(
                    title: "Identify “\(facet.value)”",
                    message: "Any document whose text contains one of these comma-separated words is filed as “\(facet.value)”. Leave it empty to stop.",
                    initial: facet.match ?? "",
                    confirm: "Save", allowEmpty: true) else { return }
                model.setEntityMatch(field, value: facet.value, pattern: pattern)
            }
        }
        Button("Clear from \(facet.count) Document\(facet.count == 1 ? "" : "s")", role: .destructive) {
            model.deleteFieldValue(field, value: facet.value)
        }
        Divider()
        Button("Hide “\(field.name)” from Sidebar") {
            var updated = field
            updated.showInSidebar = false
            model.updateField(updated)
        }
    }

}

/// The header of one library's group of sections, and where that library as a
/// whole is acted on.
private struct LibraryHeader: View {
    @Environment(AppModel.self) private var model
    let library: Library

    var body: some View {
        Text(library.displayName)
            .help(library.root.path)
            .contextMenu {
                Button("Rescan Library") { model.reindex(library) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([library.root])
                }
                Divider()
                // Closing forgets the library; the `.doctopus` folder it is
                // named after stays on disk, so it can be reopened as it was.
                Button("Close Library", role: .destructive) { model.closeLibrary(library) }
            }
    }
}

/// A tag row: selectable, renameable, colourable, and a drop target that
/// assigns the tag to whatever was dragged.
private struct TagRow: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    /// Every tag in the same library, for the "Move Under" menu.
    var siblings: [Tag] = []
    @State private var targeted = false

    var body: some View {
        Label {
            HStack {
                // Nesting is drawn by indentation rather than by disclosure
                // triangles: a tag tree is shallow, and hiding a child behind a
                // twisty makes it harder to drop onto, which is what these rows
                // are mostly for.
                if tag.depth > 0 {
                    Spacer().frame(width: CGFloat(tag.depth) * 11)
                }
                Text(tag.name)
                Spacer()
                if tag.mirrors {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Mirrored to disk as Finder aliases")
                }
                CountBadge(tag.count)
            }
        } icon: {
            Image(systemName: "tag")
                .foregroundStyle(TagColor.color(tag.color))
        }
        .dropHighlight(targeted)
        .tag(Selection.tag(tag.id))
        .contextMenu { menu }
        .dropDestination(for: DocumentDragItem.self) { items, _ in
            model.handleDrop(items, action: .tag(tag))
        } isTargeted: { targeted = $0 }
    }

    /// Every tag this one could sit under: not itself, and not anything already
    /// below it, which would make a loop out of the tree.
    private var candidateParents: [Tag] {
        var banned: Set<Int64> = [tag.tagID]
        // `siblings` is in drawing order, parents before children, so one pass
        // is enough to find the whole subtree.
        for other in siblings where other.parentID.map({ banned.contains($0) }) == true {
            banned.insert(other.tagID)
        }
        return siblings.filter { !banned.contains($0.tagID) }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…") {
            guard let new = TextPrompt.ask(title: "Rename Tag",
                                           message: "Renaming to an existing tag merges them.",
                                           initial: tag.name) else { return }
            model.renameTag(tag, to: new)
        }
        Menu("Color") {
            ForEach(Array(TagColor.names.enumerated()), id: \.offset) { index, name in
                Button {
                    model.setTagColor(tag, Int64(index))
                } label: {
                    Label(name, systemImage: Int64(index) == tag.color ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Toggle("Mirror to Disk as Aliases", isOn: Binding(
            get: { tag.mirrors },
            set: { model.setTagMirroring(tag, enabled: $0) }))
        // Nesting: assigning a child assigns its parents too, so filtering by
        // the parent finds everything underneath it.
        Menu("Move Under") {
            Button("Nothing — Top Level") { model.setTagParent(tag, to: nil) }
                .disabled(tag.parentID == nil)
            Divider()
            ForEach(candidateParents) { other in
                Button(String(repeating: "    ", count: other.depth) + other.name) {
                    model.setTagParent(tag, to: other)
                }
                .disabled(other.tagID == tag.parentID)
            }
        }
        .disabled(candidateParents.isEmpty && tag.parentID == nil)
        Divider()
        Button("Delete Tag", role: .destructive) { model.deleteTag(tag) }
    }
}

/// One folder in the physical tree, with its own disclosure state. Not private:
/// the drop checks host a row of their own.
struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    let depth: Int

    /// What a drag currently over the row would do, and nil when there is none.
    @State private var hovering: FolderDropIntent?
    /// Carries what the keys said while the drag was over the row into the drop.
    @State private var dropState = FolderDropState()
    /// Expanded unless the user has said otherwise, and the exceptions are
    /// remembered across launches.
    private var isExpanded: Bool { !model.collapsedFolders.contains(node.path) }
    /// Which library this folder is in — a rescan started here should not run
    /// over the others.
    private var owningLibrary: Library? { model.libraries.first { $0.owns(path: node.path) } }

    var body: some View {
        Label {
            HStack(spacing: 4) {
                if !node.children.isEmpty {
                    Button {
                        if isExpanded {
                            model.collapsedFolders.insert(node.path)
                        } else {
                            model.collapsedFolders.remove(node.path)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Spacer().frame(width: 10)
                }
                // Roots show their folder name, not their full path — the path
                // is still one hover away.
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                // While a drag is over the row the count gives way to what
                // letting go would do, which is the only place ⌘ announces
                // itself: the drag cursor cannot say it.
                if let hovering {
                    Text(hovering.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    CountBadge(node.deepCount)
                }
            }
        } icon: {
            Image(systemName: node.isRoot ? "externaldrive" : "folder")
        }
        .help(node.path)
        .dropHighlight(hovering != nil)
        .padding(.leading, CGFloat(depth) * 11)
        .tag(Selection.folder(node.path))
        .contextMenu { menu }
        .onDrop(of: [.doctopusDocument],
                delegate: FolderDropDelegate(folder: node.path, model: model,
                                             state: dropState, hovering: $hovering))

        if isExpanded {
            ForEach(node.children) { child in
                FolderRow(node: child, depth: depth + 1)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        // Scan-in-place: the destination is pinned to this folder, so the
        // auto-routing engine is bypassed entirely.
        ScanMenu(destination: URL(fileURLWithPath: node.path))
        Button("Import Files Here…") { importHere() }
        Divider()
        Button("New Subfolder…") { newSubfolder() }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
        }
        Divider()
        Button("Rescan This Folder") { model.reindex(owningLibrary) }
        if node.isRoot, let owningLibrary {
            Divider()
            Button("Close Library", role: .destructive) { model.closeLibrary(owningLibrary) }
        }
    }

    private func importHere() {
        guard let urls = ImportPanel.choose() else { return }
        model.importFiles(urls, into: URL(fileURLWithPath: node.path))
    }

    private func newSubfolder() {
        guard let name = TextPrompt.ask(title: "New Folder",
                                        message: "Create a folder inside \(node.name).",
                                        initial: "Untitled Folder") else { return }
        let url = URL(fileURLWithPath: node.path).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Small modal text prompt. A sheet would need state plumbed through every
/// context menu; for a one-field question this is the honest amount of code.
enum TextPrompt {
    @MainActor
    /// `allowEmpty` is for the prompts where clearing the field is a real
    /// answer rather than a cancel — a pattern you want to stop using.
    static func ask(title: String, message: String, initial: String,
                    confirm: String = "Rename", allowEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return allowEmpty ? field.stringValue : field.stringValue.nilIfBlank
    }
}

/// The panel behind every "Import Files…". Folders can be chosen as well, and
/// bring in the documents inside them.
enum ImportPanel {
    @MainActor
    static func choose() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }
}

struct CountBadge: View {
    let value: Int
    init(_ value: Int) { self.value = value }

    var body: some View {
        if value > 0 {
            Text(value, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.modelStatus.isReady ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(model.modelStatus.isReady ? model.settings.llmBackend.label : "Heuristics only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .help(model.modelStatus.label)
            HStack {
                Text("\(model.stats.total) docs · \(ByteFormat.string(model.stats.bytes))")
                if model.stats.saved > 0 {
                    Text("· saved \(ByteFormat.string(model.stats.saved))")
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 2)
    }
}

extension View {
    /// Consistent highlight for every sidebar drop target.
    func dropHighlight(_ active: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(active ? 0.3 : 0))
                .padding(.horizontal, -4)
        }
    }
}

enum TagColor {
    static let palette: [Color] = [.gray, .blue, .green, .orange, .pink, .purple, .red, .teal, .yellow, .mint]
    static let names = ["Graphite", "Blue", "Green", "Orange", "Pink", "Purple", "Red", "Teal", "Yellow", "Mint"]

    static func color(_ index: Int64) -> Color {
        palette[Int(abs(index)) % palette.count]
    }
}

/// The facet whose icon is being chosen. Wrapped because `sheet(item:)` needs
/// something identifiable.
struct IconTarget: Identifiable {
    var field: Field
    var facet: Facet
    var id: String { "\(field.key)/\(facet.value)" }
}
