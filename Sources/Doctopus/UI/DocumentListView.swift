import SwiftUI
import AppKit

/// Center pane. Owns everything shared between the list and gallery
/// presentations: selection, context menus, Quick Look, drag-and-drop.
struct DocumentListView: View {
    @Environment(AppModel.self) private var model
    @State private var renameSheet = false
    @State private var tagSheet = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.viewMode {
            case .list: DocumentTableView(renameSheet: $renameSheet, tagSheet: $tagSheet)
            case .gallery: DocumentGalleryView(renameSheet: $renameSheet, tagSheet: $tagSheet)
            }
        }
        .overlay(alignment: .center) { emptyState }
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
        .sheet(isPresented: $renameSheet) { RenameSheet(isPresented: $renameSheet) }
        .sheet(isPresented: $tagSheet) { AddTagSheet(isPresented: $tagSheet) }
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter { FileScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
            guard !supported.isEmpty else { return false }
            model.importFiles(supported, into: model.contextImportDirectory)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ResultsBar() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.documents.isEmpty {
            ContentUnavailableView {
                Label(model.searchText.isEmpty ? "Nothing here yet" : "No matches",
                      systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                Text(model.searchText.isEmpty
                     ? "Documents added to this folder appear here as they are indexed. Right-click to scan one in from your iPhone."
                     : "Try fewer words, or a token filter like tag:invoice or type:Receipt.")
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - List

private struct DocumentTableView: View {
    @Environment(AppModel.self) private var model
    @Binding var renameSheet: Bool
    @Binding var tagSheet: Bool

    /// Columns beyond the fixed ones are whatever Settings says to show.
    private var listFields: [Field] { model.fields.filter(\.showInList) }

    var body: some View {
        @Bindable var model = model

        Table(model.documents, selection: $model.selectedIDs) {
            TableColumn("Document") { row in
                HStack(spacing: 8) {
                    Thumbnail(url: row.url, mtime: row.mtime, size: .row,
                              width: 20, height: 26, cornerRadius: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.displayTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let snippet = row.snippet {
                            Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if row.filename != row.displayTitle {
                            Text(row.filename)
                                .font(.caption).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .width(min: 240, ideal: 400)

            TableColumnForEach(listFields) { field in
                TableColumn(field.name) { (row: DocumentRow) in
                    if let value = row.values[field.key] {
                        Text(value).lineLimit(1)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 70, ideal: 130)
            }

            TableColumn("Date") { row in
                Text((row.docDate ?? row.createdAt), format: .dateTime.year().month(.abbreviated).day())
                    .monospacedDigit()
                    .foregroundStyle(row.docDate == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Size") { row in
                HStack(spacing: 4) {
                    Text(ByteFormat.string(row.size)).monospacedDigit()
                    if let savings = row.savings {
                        Text("−\(Int(savings * 100))%")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
            }
            .width(min: 70, ideal: 96)

            TableColumn("") { row in StatusDot(row: row) }
                .width(18)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int64.self) { ids in
            DocumentMenu(rows: model.documents.filter { ids.contains($0.id) },
                         renameSheet: $renameSheet, tagSheet: $tagSheet)
        } primaryAction: { ids in
            model.quickLook(startingAt: model.documents.first { ids.contains($0.id) })
        }
    }
}

// MARK: - Gallery

private struct DocumentGalleryView: View {
    @Environment(AppModel.self) private var model
    @Binding var renameSheet: Bool
    @Binding var tagSheet: Bool

    private var cell: CGFloat { CGFloat(model.settings.galleryThumbnailSize) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell * 1.4), spacing: 18)],
                      spacing: 20) {
                ForEach(model.documents) { row in
                    GalleryCell(row: row, width: cell)
                        .onTapGesture(count: 2) { model.quickLook(startingAt: row) }
                        .onTapGesture { select(row) }
                        .contextMenu {
                            DocumentMenu(rows: model.selectedIDs.contains(row.id) ? model.selectedRows : [row],
                                         renameSheet: $renameSheet, tagSheet: $tagSheet)
                        }
                }
            }
            .padding(18)
        }
        // Clicking the empty area behind the grid clears the selection and
        // still offers the import menu, the way a Finder window does.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.selectedIDs = [] }
                .contextMenu { BackgroundMenu() }
        }
    }

    private func select(_ row: DocumentRow) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selectedIDs.contains(row.id) { model.selectedIDs.remove(row.id) }
            else { model.selectedIDs.insert(row.id) }
        } else {
            model.selectedIDs = [row.id]
        }
    }
}

private struct GalleryCell: View {
    @Environment(AppModel.self) private var model
    let row: DocumentRow
    let width: CGFloat

    private var isSelected: Bool { model.selectedIDs.contains(row.id) }

    var body: some View {
        VStack(spacing: 7) {
            Thumbnail(url: row.url, mtime: row.mtime, size: .gallery,
                      width: width, height: width * 1.3, cornerRadius: 5, showsShadow: true)
                .padding(5)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                }
                .overlay(alignment: .topTrailing) {
                    StatusDot(row: row).padding(7)
                }

            Text(row.displayTitle)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: width)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : .clear)
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .help(row.filename)
    }
}

// MARK: - Menus

/// Shown when documents are right-clicked; falls back to the import menu when
/// the click landed on empty space.
private struct DocumentMenu: View {
    @Environment(AppModel.self) private var model
    let rows: [DocumentRow]
    @Binding var renameSheet: Bool
    @Binding var tagSheet: Bool

    var body: some View {
        if rows.isEmpty {
            BackgroundMenu()
        } else {
            Button("Quick Look") { model.quickLook(startingAt: rows.first) }
            Button("Open in Default App") { model.open(rows) }
            Button("Reveal in Finder") { model.reveal(rows) }
            Divider()
            Menu("Tags") {
                Button("Add Tag…") { tagSheet = true }
                if !model.tags.isEmpty {
                    Divider()
                    ForEach(model.tags) { tag in
                        Button(tag.name) { model.addTag(tag.name, to: rows) }
                    }
                }
            }
            Divider()
            Button(rows.count == 1 ? "Rename…" : "Rename \(rows.count) Files…") { renameSheet = true }
            Button("Move to Folder…") { model.moveToFolderPicker(rows) }
            Divider()
            Button("Reprocess") { model.reprocess(rows) }
            Button("Optimize") { model.optimize(rows) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rows.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { model.moveToTrash(rows) }
        }
    }
}

/// Right-clicking empty space imports into whatever folder the sidebar has
/// selected, so scan-in-place works from the browser as well as the tree.
private struct BackgroundMenu: View {
    @Environment(AppModel.self) private var model

    private var destination: URL? { model.contextImportDirectory }

    var body: some View {
        Button(scanTitle) {
            ScanCoordinator.shared.presentMenu(destination: destination)
        }
        Button("Import Files…") { importFiles() }
        Divider()
        if let destination {
            Button("Reveal Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
        Button("Rescan All Folders") { model.reindex() }
    }

    private var scanTitle: String {
        guard let name = destination?.lastPathComponent else { return "Scan from iPhone or iPad…" }
        return "Scan from iPhone or iPad into “\(name)”…"
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls, into: destination)
    }
}

// MARK: - Chrome

private struct StatusDot: View {
    let row: DocumentRow

    var body: some View {
        Group {
            if !row.approved {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .help("Needs review")
            } else if row.ocrState == .pending {
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                    .help("Waiting for OCR")
            } else if row.ocrState == .failed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    .help("Could not be read")
            }
        }
        .font(.caption)
    }
}

private struct ResultsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text("\(model.documents.count) document\(model.documents.count == 1 ? "" : "s")")
                if !model.selectedIDs.isEmpty {
                    Text("· \(model.selectedIDs.count) selected")
                }
                Spacer()
                if model.stats.pending > 0 {
                    Label("\(model.stats.pending) pending OCR", systemImage: "clock")
                }
                if model.stats.failed > 0 {
                    Label("\(model.stats.failed) failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}
