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
                row(.needsReview, "Needs Review", "exclamationmark.triangle", model.needsReviewCount)
                row(.untagged, "Untagged", "tag.slash", nil)
                row(.reviewed, "Recently Reviewed", "checkmark.circle", nil)
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

            if model.library != nil {
                if !model.folders.isEmpty {
                    Section("Folders") {
                        ForEach(model.folders) { node in
                            FolderRow(node: node, depth: 0)
                        }
                    }
                }
                Section("Tags") {
                    tagRows
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
    private var tagRows: some View {
        ForEach(model.tags) { tag in
            TagRow(tag: tag, siblings: model.tags)
        }
        Button {
            guard let name = TextPrompt.ask(title: "New Tag",
                                            message: "Tags can be dragged onto from the document list.",
                                            initial: "", confirm: "Create") else { return }
            model.createTag(named: name)
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
            TagColorItems(tag: tag)
        }
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
    /// Lit while ⌥ is held and a selected document is in this folder. A
    /// collapsed folder stands in for whatever it is hiding.
    private var isRevealed: Bool {
        let revealed = model.revealedFolders
        guard !revealed.isEmpty else { return false }
        if revealed.contains(node.path) { return true }
        return !isExpanded && revealed.contains { $0.hasPrefix(node.path + "/") }
    }

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
        .revealHighlight(isRevealed)
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
        Button("Rescan This Folder") { model.reindex() }
        if node.isRoot {
            Divider()
            Button("Close Library", role: .destructive) { model.closeLibrary() }
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
        model.createFolder(named: name, in: URL(fileURLWithPath: node.path))
    }

    private func renameFolder() {
        guard let name = TextPrompt.ask(title: "Rename Folder",
                                        message: "Renames the folder on disk; documents inside keep their tags and metadata.",
                                        initial: node.name) else { return }
        model.renameFolder(node.path, to: name) { rules in
            let alert = NSAlert()
            alert.messageText = rules.count == 1
                ? "Update the rule that files into “\(node.name)”?"
                : "Update the \(rules.count) rules that file into “\(node.name)”?"
            alert.informativeText = rules.map { "“\($0.name)” → \($0.destination ?? "")" }
                .joined(separator: "\n")
            alert.addButton(withTitle: rules.count == 1 ? "Update Rule" : "Update Rules")
            alert.addButton(withTitle: "Leave As They Are")
            return alert.runModal() == .alertFirstButtonReturn
        }
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

    /// Marks a folder ⌥ is pointing out. Quieter than a drop target's, which
    /// has to win when both apply.
    func revealHighlight(_ active: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor.opacity(active ? 0.8 : 0), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(active ? 0.12 : 0)))
                .padding(.horizontal, -4)
        }
    }
}

/// Holding ⌥ on its own points out, in the sidebar, the folders the selected
/// documents are in. Only on its own: ⌥ is also half of several shortcuts,
/// and those should not flash the sidebar on the way past.
@MainActor
enum OptionReveal {
    private static var held: @MainActor (Bool) -> Void = { _ in }

    static func install(_ held: @escaping @MainActor (Bool) -> Void) {
        self.held = held
        _ = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            MainActor.assumeIsolated { Self.held(flags == .option) }
            return event
        }
        // A key let go while another app is in front never reaches the monitor.
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                   object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.held(false) }
        }
    }
}

enum TagColor {
    static let palette: [Color] = [.gray, .blue, .green, .orange, .pink, .purple, .red, .teal, .yellow, .mint]
    static let names = ["Graphite", "Blue", "Green", "Orange", "Pink", "Purple", "Red", "Teal", "Yellow", "Mint"]

    static let nsPalette: [NSColor] = [.systemGray, .systemBlue, .systemGreen, .systemOrange, .systemPink,
                                       .systemPurple, .systemRed, .systemTeal, .systemYellow, .systemMint]

    static func color(_ index: Int64) -> Color {
        palette[Int(abs(index)) % palette.count]
    }

    /// A filled dot in the tag's colour. Menus draw SF Symbols as templates,
    /// in the text colour, so the swatch is its own non-template image.
    static func swatch(_ index: Int64) -> NSImage {
        let fill = nsPalette[Int(abs(index)) % nsPalette.count]
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The colour choices for a tag's menu, each shown in its own colour, with a
/// checkmark on the current one.
struct TagColorItems: View {
    @Environment(AppModel.self) private var model
    let tag: Tag

    var body: some View {
        ForEach(Array(TagColor.names.enumerated()), id: \.offset) { index, name in
            Toggle(isOn: Binding(get: { Int64(index) == tag.color },
                                 set: { _ in model.setTagColor(tag, Int64(index)) })) {
                Label {
                    Text(name)
                } icon: {
                    Image(nsImage: TagColor.swatch(Int64(index)))
                }
            }
        }
    }
}

struct IconTarget: Identifiable {
    var field: Field
    var facet: Facet
    var id: String { "\(field.key)/\(facet.value)" }
}
