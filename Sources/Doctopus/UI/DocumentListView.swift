import SwiftUI
import QuickLook
import QuickLookUI
import AppKit

struct DocumentListView: View {
    @Environment(AppModel.self) private var model
    @State private var quickLookURL: URL?
    @State private var renameSheet = false
    @State private var tagSheet = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model

        Table(model.documents, selection: $model.selectedIDs) {
            TableColumn("Document") { row in
                TitleCell(row: row)
            }
            .width(min: 240, ideal: 380)

            TableColumn("Correspondent") { row in
                Text(row.correspondent ?? "—")
                    .foregroundStyle(row.correspondent == nil ? .tertiary : .primary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150)

            TableColumn("Type") { row in
                if let type = row.docType {
                    Text(type).font(.callout)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 70, ideal: 110)

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

            TableColumn("") { row in
                StatusDot(row: row)
            }
            .width(18)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int64.self) { ids in
            menu(for: rows(ids))
        } primaryAction: { ids in
            model.open(rows(ids))
        }
        .quickLookPreview($quickLookURL)
        .onChange(of: model.isQuickLookOpen) { _, open in
            quickLookURL = open ? model.lastSelected?.url : nil
            if !open { model.isQuickLookOpen = false }
        }
        .onChange(of: quickLookURL) { _, url in
            if url == nil { model.isQuickLookOpen = false }
        }
        .sheet(isPresented: $renameSheet) { RenameSheet(isPresented: $renameSheet) }
        .sheet(isPresented: $tagSheet) { AddTagSheet(isPresented: $tagSheet) }
        .overlay(alignment: .center) { emptyState }
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter { FileScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
            guard !supported.isEmpty else { return false }
            model.importFiles(supported, into: destinationForDrop)
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
        .safeAreaInset(edge: .bottom, spacing: 0) { resultsBar }
    }

    private var destinationForDrop: URL? {
        if case .folder(let path) = model.selection { return URL(fileURLWithPath: path) }
        return nil
    }

    private func rows(_ ids: Set<Int64>) -> [DocumentRow] {
        model.documents.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.documents.isEmpty {
            ContentUnavailableView {
                Label(model.searchText.isEmpty ? "Nothing here yet" : "No matches",
                      systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                Text(model.searchText.isEmpty
                     ? "Documents added to this folder appear here as they are indexed."
                     : "Try fewer words, or a token filter like tag:invoice or from:Acme.")
            }
        }
    }

    private var resultsBar: some View {
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

    // MARK: - Context menu

    @ViewBuilder
    private func menu(for rows: [DocumentRow]) -> some View {
        if rows.isEmpty {
            Button("Import Files…") { }
                .disabled(true)
        } else {
            Button("Quick Look") { quickLookURL = rows.first?.url }
            Button("Open in Default App") { model.open(rows) }
            Button("Reveal in Finder") { model.reveal(rows) }
            Divider()
            Menu("Tags") {
                Button("Add Tag…") { tagSheet = true }
                if rows.count == 1, let detail = model.detail, detail.row.id == rows[0].id, !detail.tags.isEmpty {
                    Divider()
                    ForEach(detail.tags) { tag in
                        Button("Remove “\(tag.name)”") { model.removeTag(tag, from: rows) }
                    }
                }
                if !model.tags.isEmpty {
                    Divider()
                    ForEach(model.tags.prefix(12)) { tag in
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

private struct TitleCell: View {
    let row: DocumentRow

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcon.icon(for: row.url))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let snippet = row.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if row.filename != row.displayTitle {
                    Text(row.filename)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

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

/// Finder icons, cached — `NSWorkspace.icon(forFile:)` is surprisingly costly
/// when a table is scrolling.
enum FileIcon {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for url: URL) -> NSImage {
        let key = url.pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        cache[key] = icon
        return icon
    }
}
