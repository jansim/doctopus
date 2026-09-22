import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var iconTarget: IconTarget?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Section(model.libraries.count > 1 ? "All Libraries" : "Library") {
                row(.all, "All Documents", "tray.full", model.stats.total)
                row(.needsReview, "Needs Review", "exclamationmark.triangle",
                    model.queue.filter { !$0.approved }.count)
                row(.untagged, "Untagged", "tag.slash", nil)
                row(.queue, "Recent Processing", "clock.arrow.circlepath", model.queue.count)
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
                Button("Close Library", role: .destructive) { model.closeLibrary(library) }
            }
    }
}

private struct TagRow: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    var siblings: [Tag] = []
    @State private var targeted = false

    var body: some View {
        Label {
            HStack {
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

    private var candidateParents: [Tag] {
        var banned: Set<Int64> = [tag.tagID]
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

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    let depth: Int

    @State private var hovering: FolderDropIntent?
    @State private var dropState = FolderDropState()
    private var isExpanded: Bool { !model.collapsedFolders.contains(node.path) }
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
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
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
        ScanMenu(destination: URL(fileURLWithPath: node.path))
        Button("Import Files Here…") { importHere() }
        Divider()
        Button("New Subfolder…") { newSubfolder() }
        // Renaming the library root would desync it from the `Library` that
        // was opened at that path; subfolders have no such identity to break.
        if !node.isRoot {
            Button("Rename…") { renameFolder() }
        }
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
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            model.refreshAll()
            model.selection = .folder(url.path)
        } catch {
            model.errorMessage = "Could not create “\(name)”: \(error.localizedDescription)"
        }
    }

    private func renameFolder() {
        guard let name = TextPrompt.ask(title: "Rename Folder",
                                        message: "Renames the folder on disk; documents inside keep their tags and metadata.",
                                        initial: node.name) else { return }
        let source = URL(fileURLWithPath: node.path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.moveItem(at: source, to: destination)
    }
}

enum TextPrompt {
    @MainActor
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
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text("\(model.stats.total.formatted()) doc\(model.stats.total == 1 ? "" : "s")")
                Spacer(minLength: 6)
                Text(ByteFormat.string(model.stats.bytes))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

extension View {
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

struct IconTarget: Identifiable {
    var field: Field
    var facet: Facet
    var id: String { "\(field.key)/\(facet.value)" }
}
