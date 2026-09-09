import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var iconTarget: IconTarget?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Section("Library") {
                row(.all, "All Documents", "tray.full", model.stats.total)
                // Needs Review is the queue filtered to undecided entries, so
                // its count comes from the same place the queue's does.
                row(.needsReview, "Needs Review", "exclamationmark.triangle",
                    model.queue.filter { !$0.approved }.count)
                row(.untagged, "Untagged", "tag.slash", nil)
                row(.queue, "Recent Processing", "clock.arrow.circlepath", model.queue.count)
            }

            if !model.folders.isEmpty {
                Section("Folders") {
                    ForEach(model.folders) { node in
                        FolderRow(node: node, depth: 0)
                    }
                }
            }

            Section {
                ForEach(model.tags) { tag in
                    TagRow(tag: tag)
                }
                Button {
                    guard let name = TextPrompt.ask(title: "New Tag", message: "Tags can be dragged onto from the document list.", initial: "", confirm: "Create") else { return }
                    model.createTag(named: name)
                } label: {
                    Label("New Tag…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Tags")
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

/// A tag row: selectable, renameable, colourable, and a drop target that
/// assigns the tag to whatever was dragged.
private struct TagRow: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    @State private var targeted = false

    var body: some View {
        Label {
            HStack {
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
        Divider()
        Button("Delete Tag", role: .destructive) { model.deleteTag(tag) }
    }
}

/// One folder in the physical tree, with its own disclosure state.
private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let node: FolderNode
    let depth: Int

    @State private var targeted = false
    /// Expanded unless the user has said otherwise, and the exceptions are
    /// remembered across launches.
    private var isExpanded: Bool { !model.collapsedFolders.contains(node.path) }

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
                CountBadge(node.deepCount)
            }
        } icon: {
            Image(systemName: node.isRoot ? "externaldrive" : "folder")
        }
        .help(node.path)
        .dropHighlight(targeted)
        .padding(.leading, CGFloat(depth) * 11)
        .tag(Selection.folder(node.path))
        .contextMenu { menu }
        .dropDestination(for: DocumentDragItem.self) { items, _ in
            model.handleDrop(items, action: .alias(folder: node.path))
        } isTargeted: { targeted = $0 }

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
        Button("Rescan This Folder") { model.reindex() }
        if node.isRoot, let library = model.libraries.first(where: { $0.root.path == node.path }) {
            Divider()
            Button("Close Library", role: .destructive) { model.closeLibrary(library) }
        }
    }

    private func importHere() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls, into: URL(fileURLWithPath: node.path))
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
    static func ask(title: String, message: String, initial: String,
                    confirm: String = "Rename") -> String? {
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
        return field.stringValue.nilIfBlank
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
                Text(model.modelStatus.isReady ? "On-device model" : "Heuristics only")
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
