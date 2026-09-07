import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Section("Library") {
                row(.all, "All Documents", "tray.full", model.stats.total)
                row(.needsReview, "Needs Review", "exclamationmark.triangle", model.stats.needsReview)
                row(.untagged, "Untagged", "tag.slash", nil)
                row(.queue, "Recent Processing", "clock.arrow.circlepath", model.queue.count)
            }

            if !model.folders.isEmpty {
                Section("Folders") {
                    ForEach(model.folders) { node in
                        FolderRow(node: node, depth: 0, expanded: $expanded)
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
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
                        .tag(Selection.tag(tag.id))
                        .contextMenu { tagMenu(tag) }
                    }
                }
            }

            facetSection("Correspondents", "building.2", model.correspondents, Selection.correspondent)
            facetSection("Document Types", "doc.on.doc", model.docTypes, Selection.docType)
            facetSection("Languages", "character.bubble", model.languages) { Selection.language($0) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter() }
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

    @ViewBuilder
    private func facetSection(_ title: String, _ icon: String, _ facets: [Facet],
                              _ make: @escaping (String) -> Selection) -> some View {
        if !facets.isEmpty {
            Section(title) {
                ForEach(facets.prefix(40)) { facet in
                    Label {
                        HStack {
                            Text(display(facet.value, in: title))
                                .lineLimit(1)
                            Spacer()
                            CountBadge(facet.count)
                        }
                    } icon: {
                        Image(systemName: icon)
                    }
                    .tag(make(facet.value))
                }
            }
        }
    }

    private func display(_ value: String, in section: String) -> String {
        guard section == "Languages" else { return value }
        return Locale.current.localizedString(forLanguageCode: value)?.capitalized ?? value.uppercased()
    }

    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
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
    @Binding var expanded: Set<String>

    private var isExpanded: Bool { expanded.contains(node.path) }

    var body: some View {
        Label {
            HStack(spacing: 4) {
                if !node.children.isEmpty {
                    Button {
                        if isExpanded { expanded.remove(node.path) } else { expanded.insert(node.path) }
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
                Text(node.isRoot ? shortRootName : node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                CountBadge(node.deepCount)
            }
        } icon: {
            Image(systemName: node.isRoot ? "externaldrive" : (isExpanded ? "folder.fill" : "folder"))
        }
        .padding(.leading, CGFloat(depth) * 11)
        .tag(Selection.folder(node.path))
        .contextMenu { menu }

        if isExpanded {
            ForEach(node.children) { child in
                FolderRow(node: child, depth: depth + 1, expanded: $expanded)
            }
        }
    }

    private var shortRootName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return node.path.hasPrefix(home) ? "~" + node.path.dropFirst(home.count) : node.path
    }

    @ViewBuilder
    private var menu: some View {
        // Scan-in-place: the destination is pinned to this folder, so the
        // auto-routing engine is bypassed entirely.
        Menu("Import from iPhone or iPad") {
            Button("Scan Documents Here…") { presentScanner() }
        }
        Button("Import Files Here…") { importHere() }
        Divider()
        Button("New Subfolder…") { newSubfolder() }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
        }
        Divider()
        Button("Rescan This Folder") { model.reindex() }
        if node.isRoot, let root = model.roots.first(where: { $0.path == node.path }) {
            Divider()
            Button("Stop Indexing This Folder", role: .destructive) { model.removeRoot(root) }
        }
    }

    private func presentScanner() {
        ScanCoordinator.shared.presentMenu(destination: URL(fileURLWithPath: node.path))
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
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Create a folder inside \(node.name)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Untitled Folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let name = field.stringValue.nilIfBlank else { return }
        let url = URL(fileURLWithPath: node.path).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

enum TagColor {
    static let palette: [Color] = [.accentColor, .blue, .green, .orange, .pink, .purple, .red, .teal, .yellow, .mint]
    static func color(_ index: Int64) -> Color {
        palette[Int(abs(index)) % palette.count]
    }
    /// Stable colour derived from the name, so tags look consistent without state.
    static func color(for name: String) -> Color {
        palette[abs(name.hashValue) % palette.count]
    }
}
