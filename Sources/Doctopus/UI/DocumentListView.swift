import SwiftUI
import AppKit

/// Center pane. Owns everything shared between the list and gallery
/// presentations: selection, context menus, Quick Look, drag-and-drop.
struct DocumentListView: View {
    @Environment(AppModel.self) private var model
    @State private var renameSheet = false
    @State private var tagSheet = false
    @State private var filingRow: DocumentRow?
    @State private var dropTargeted = false

    var body: some View {
        // The approval view splits: the list on top, the selected document's
        // review below, where what was worked out can be corrected and the
        // folders it goes in chosen.
        Group {
            if model.selection.isQueueMode {
                VSplitView {
                    browser
                        .frame(minHeight: 140, idealHeight: 300, maxHeight: .infinity)
                    ReviewPanel()
                        .frame(minHeight: 220, idealHeight: 300, maxHeight: .infinity)
                }
            } else {
                browser
            }
        }
        .sheet(isPresented: $renameSheet) { RenameSheet(isPresented: $renameSheet) }
        .sheet(isPresented: $tagSheet) { AddTagSheet(isPresented: $tagSheet) }
        .sheet(item: $filingRow) { row in FilingSheet(row: row) }
    }

    private var browser: some View {
        Group {
            switch model.viewMode {
            case .list: DocumentTableView(renameSheet: $renameSheet, tagSheet: $tagSheet, filingRow: $filingRow)
            case .gallery: DocumentGalleryView(renameSheet: $renameSheet, tagSheet: $tagSheet, filingRow: $filingRow)
            }
        }
        .overlay(alignment: .center) { emptyState }
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            let supported = urls.filter { FileScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
            guard !supported.isEmpty else { return false }
            // No explicit destination: a drop lands in the selected folder and
            // stays there, or in the Inbox and gets routed from it.
            model.importFiles(supported, into: nil)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.selection.isQueueMode { QueueBar() }
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
                Text(emptyMessage)
            }
            .allowsHitTesting(false)
        }
    }

    private var emptyMessage: String {
        if !model.searchText.isEmpty {
            return "Try fewer words, or a token filter like tag:invoice or type:Receipt."
        }
        switch model.selection {
        case .needsReview: return "Everything the pipeline filed has been reviewed."
        case .queue: return "Imports, scans, moves and optimizations show up here as they happen."
        default: return "Documents added to this folder appear here as they are indexed. Right-click to scan one in from your iPhone."
        }
    }
}

/// Review header, shown for both queue selections.
private struct QueueBar: View {
    @Environment(AppModel.self) private var model

    private var pending: Int { model.documents.filter { $0.queue?.approved == false }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if pending > 0 {
                    Label("\(pending) awaiting review", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("All caught up", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Approve Selected") {
                    model.setApproved(model.selectedRows, true)
                }
                .disabled(model.selectedIDs.isEmpty)
                Button("Approve All") { model.approveAll() }
                    .disabled(pending == 0)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
        }
        .background(.bar)
    }
}

// MARK: - List

private struct DocumentTableView: View {
    @Environment(AppModel.self) private var model
    @Binding var renameSheet: Bool
    @Binding var tagSheet: Bool
    @Binding var filingRow: DocumentRow?

    /// Reflects the model's sort onto the headers, so the arrow is in the same
    /// place whether the order was chosen from a header or from the toolbar.
    private var sortOrder: Binding<[DocumentSort]> {
        Binding(
            get: { [DocumentSort(field: model.sort, order: model.sortAscending ? .forward : .reverse)] },
            set: { new in
                guard let sort = new.first else { return }
                model.setSort(sort.field, ascending: sort.order == .forward)
            })
    }

    /// Queue mode swaps in review-specific columns.
    private var queueColumns: [QueueColumn] {
        model.selection.isQueueMode ? QueueColumn.allCases : []
    }

    var body: some View {
        @Bindable var model = model

        // Rows are built explicitly so the drag lives on the row rather than on
        // the cell: `.draggable` inside a cell swallows the mouse-down, which
        // left the document name — the largest target in the row — unable to
        // change the selection.
        Table(of: DocumentRow.self, selection: $model.selectedIDs,
              sortOrder: sortOrder, columnCustomization: $model.listColumns) {
            TableColumn("Document", sortUsing: DocumentSort(field: .name)) { row in
                HStack(spacing: 8) {
                    if model.selection.isQueueMode {
                        Toggle("", isOn: Binding(
                            get: { row.queue?.approved ?? true },
                            set: { model.setApproved([row], $0) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help(row.queue?.approved == true ? "Approved" : "Needs review")
                    }
                    AliasBadgedThumbnail(row: row, width: 20, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.displayTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let queue = row.queue {
                            Text(queue.detail ?? queue.action.capitalized)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if let snippet = row.snippet {
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
            .customizationID("document")
            // The name column is the list; hiding it would leave nothing to click.
            .disabledCustomizationBehavior(.visibility)

            TableColumnForEach(queueColumns) { kind in
                // Not sortable: queue mode is always ordered by when the event
                // happened, so an arrow here would promise something untrue.
                TableColumn(kind.title) { (row: DocumentRow) in
                    QueueCell(row: row, kind: kind)
                }
                .width(min: 70, ideal: kind == .action ? 130 : 90)
                .customizationID("queue.\(kind.rawValue)")
            }

            // Every configured field gets a column; Settings decides which are
            // on by default and the header menu takes it from there.
            TableColumnForEach(model.fields) { field in
                TableColumn(field.name, sortUsing: DocumentSort(field: .field(field.key))) { (row: DocumentRow) in
                    if let value = row.values[field.key] {
                        Text(value).lineLimit(1)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 70, ideal: 130)
                .customizationID("field.\(field.key)")
                .defaultVisibility(field.showInList ? .visible : .hidden)
            }

            // Only worth a column once the list can hold rows from more than
            // one place; two libraries can easily hold files of the same name.
            TableColumn("Library") { (row: DocumentRow) in
                Text(model.library(row.library)?.displayName ?? "—")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 120)
            .customizationID("library")
            .defaultVisibility(model.libraries.count > 1 ? .visible : .hidden)

            TableColumn("Date", sortUsing: DocumentSort(field: .docDate)) { row in
                Text((row.docDate ?? row.createdAt), format: .dateTime.year().month(.abbreviated).day())
                    .monospacedDigit()
                    .foregroundStyle(row.docDate == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("date")

            // Both tag systems can be shown, and are deliberately separate
            // columns: one is Doctopus's, the other is the Finder's.
            TableColumn("Tags") { (row: DocumentRow) in
                TagChips(tags: row.tags)
            }
            .width(min: 80, ideal: 160)
            .customizationID("tags")
            .defaultVisibility(.hidden)

            TableColumn("Finder Tags") { (row: DocumentRow) in
                FinderTagChips(names: row.finderTags)
            }
            .width(min: 80, ideal: 160)
            .customizationID("finderTags")
            .defaultVisibility(.hidden)

            // Off by default: the sort menu offers "Added" too, and a sort with
            // no column on screen would have nowhere to put its arrow.
            TableColumn("Added", sortUsing: DocumentSort(field: .added)) { row in
                Text(row.createdAt, format: .dateTime.year().month(.abbreviated).day())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("added")
            .defaultVisibility(.hidden)

            TableColumn("Size", sortUsing: DocumentSort(field: .size)) { row in
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
            .customizationID("size")

            TableColumn("") { row in StatusDot(row: row) }
                .width(18)
                .customizationID("status")
                .disabledCustomizationBehavior([.resize, .reorder])
        } rows: {
            ForEach(model.documents) { row in
                TableRow(row).draggable(DocumentDragItem(row))
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: DocumentRef.self) { ids in
            DocumentMenu(rows: model.documents.filter { ids.contains($0.id) },
                         renameSheet: $renameSheet, tagSheet: $tagSheet, filingRow: $filingRow)
        } primaryAction: { ids in
            model.quickLook(startingAt: model.documents.first { ids.contains($0.id) })
        }
    }
}

enum QueueColumn: String, CaseIterable, Identifiable {
    case action, confidence, when
    var id: String { rawValue }
    var title: String {
        switch self {
        case .action: return "Action"
        case .confidence: return "Confidence"
        case .when: return "When"
        }
    }
}

private struct QueueCell: View {
    let row: DocumentRow
    let kind: QueueColumn

    var body: some View {
        if let queue = row.queue {
            switch kind {
            case .action:
                HStack(spacing: 5) {
                    Image(systemName: queue.icon).font(.caption)
                    Text(queue.action.capitalized)
                    if let rule = queue.rule, rule != "none" {
                        Text(rule == "derived" ? "derived" : rule)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .foregroundStyle(queue.approved ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
            case .confidence:
                if let c = queue.confidence { ConfidenceBadge(value: c) } else { Text("—").foregroundStyle(.tertiary) }
            case .when:
                Text(queue.at, style: .relative).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// Thumbnail with Finder's alias convention: a small corner arrow when the
/// document is only present in this folder as a link to its master elsewhere.
struct AliasBadgedThumbnail: View {
    let row: DocumentRow
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 2
    var showsShadow = false

    private var isGallery: Bool { width > 60 }

    /// The badge is a corner mark, not a second subject: at row size it has to
    /// stay legible against a 20-point thumbnail, but at gallery size the same
    /// proportion turns it into a button stuck over the page.
    private var badge: CGFloat { max(6, width * (isGallery ? 0.14 : 0.28)) }

    var body: some View {
        Thumbnail(url: row.url, mtime: row.mtime,
                  size: isGallery ? .gallery : .row,
                  width: width, height: height,
                  cornerRadius: cornerRadius, showsShadow: showsShadow)
            .overlay(alignment: .bottomLeading) {
                if row.isAliasHere {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: badge, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(max(1, badge * 0.22))
                        .background(Circle().fill(Color.secondary.opacity(0.85)))
                        .padding(max(1, badge * 0.14))
                        .help("Alias — the original lives in \((row.directory as NSString).lastPathComponent)")
                }
            }
    }
}

// MARK: - Gallery

private struct DocumentGalleryView: View {
    @Environment(AppModel.self) private var model
    @Binding var renameSheet: Bool
    @Binding var tagSheet: Bool
    @Binding var filingRow: DocumentRow?

    private var cell: CGFloat { CGFloat(model.settings.galleryThumbnailSize) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell * 1.4), spacing: 18)],
                      spacing: 20) {
                ForEach(model.documents) { row in
                    GalleryCell(row: row, width: cell)
                        .draggable(DocumentDragItem(row))
                        .onTapGesture(count: 2) { model.quickLook(startingAt: row) }
                        .onTapGesture { select(row) }
                        .contextMenu {
                            DocumentMenu(rows: model.selectedIDs.contains(row.id) ? model.selectedRows : [row],
                                         renameSheet: $renameSheet, tagSheet: $tagSheet, filingRow: $filingRow)
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
            AliasBadgedThumbnail(row: row, width: width, height: width * 1.3,
                                 cornerRadius: 5, showsShadow: true)
                .padding(5)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                }
                .overlay(alignment: .topTrailing) {
                    StatusDot(row: row).padding(7)
                }
                .overlay(alignment: .topLeading) {
                    if let queue = row.queue {
                        Toggle("", isOn: Binding(
                            get: { queue.approved },
                            set: { model.setApproved([row], $0) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .padding(7)
                            .help(queue.approved ? "Approved" : "Needs review")
                    }
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
        // One target for the whole cell: the padding around the thumbnail and
        // the gap above the title are part of what the user is aiming at.
        .contentShape(.rect)
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
    @Binding var filingRow: DocumentRow?

    var body: some View {
        if rows.isEmpty {
            BackgroundMenu()
        } else {
            Button("Quick Look") { model.quickLook(startingAt: rows.first) }
            Button("Open in Default App") { model.open(rows) }
            Button("Reveal in Finder") { model.reveal(rows) }
            if rows.count == 1, rows[0].isAliasHere, case .folder(let folder) = model.selection {
                Button("Remove Alias from “\((folder as NSString).lastPathComponent)”") {
                    model.removeAlias(rows[0], inFolder: folder)
                }
            }
            if model.selection.isQueueMode {
                Divider()
                Button("Approve") { model.setApproved(rows, true) }
                Button("Mark as Needs Review") { model.setApproved(rows, false) }
            }
            Divider()
            Menu("Tags") {
                Button("Add Tag…") { tagSheet = true }
                if !model.tagNames.isEmpty {
                    Divider()
                    ForEach(model.tagNames, id: \.self) { name in
                        Button(name) { model.addTag(name, to: rows) }
                    }
                }
                Menu("Finder Tags") {
                    Button("Add Finder Tag…") {
                        guard let name = TextPrompt.ask(
                            title: "Add Finder Tag",
                            message: "Finder tags are written to the files themselves and are visible everywhere in macOS.",
                            initial: "", confirm: "Add") else { return }
                        model.addFinderTag(name, to: rows)
                    }
                    if !model.finderTags.isEmpty {
                        Divider()
                        ForEach(model.finderTags) { tag in
                            Button(tag.value) { model.addFinderTag(tag.value, to: rows) }
                        }
                    }
                    let present = Set(rows.flatMap(\.finderTags))
                    if !present.isEmpty {
                        Divider()
                        ForEach(present.sorted(), id: \.self) { name in
                            Button("Remove “\(name)”") { model.removeFinderTag(name, from: rows) }
                        }
                    }
                }
            }
            Divider()
            Button(rows.count == 1 ? "Rename…" : "Rename \(rows.count) Files…") { renameSheet = true }
            if rows.count == 1 {
                Button("File In…") { filingRow = rows[0] }
            }
            Button("Move to Folder…") { model.moveToFolderPicker(rows) }
            Divider()
            Button("Reprocess") { model.reprocess(rows) }
            Button(rows.count == 1 ? "Analyze with Model" : "Analyze \(rows.count) with Model") {
                model.analyze(rows)
            }
            .disabled(!model.modelStatus.isReady)
            Button("Optimize") { model.optimize(rows) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rows.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Menu("Import") { BackgroundMenu() }
            Divider()
            Button("Move to Trash", role: .destructive) { model.moveToTrash(rows) }
        }
    }
}

/// Right-clicking empty space imports into whatever folder the sidebar has
/// selected, so scan-in-place works from the browser as well as the tree.
private struct BackgroundMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // `nil` rather than the Inbox, so an import from here is routed
        // unless a folder is selected — the same as from the toolbar.
        ScanMenu(destination: model.explicitImportDirectory)
        Button("Import Files…") { importFiles() }
        Divider()
        if let folder = model.contextImportDirectory {
            Button("Reveal Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
        Button("Rescan All Folders") { model.reindex() }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls, into: nil)
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

/// What a column header sorts by. The ordering itself is done by SQLite over
/// the whole result set — the table only ever shows a window of it — so this
/// exists to carry the choice into the model and to put the arrow on the right
/// header. `compare` is implemented anyway so the comparator is not a lie.
struct DocumentSort: SortComparator, Hashable {
    var field: SortField
    var order: SortOrder = .forward

    func compare(_ lhs: DocumentRow, _ rhs: DocumentRow) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .name:
            result = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
        case .size:
            result = compare(lhs.size, rhs.size)
        case .added, .relevance:
            result = compare(lhs.createdAt, rhs.createdAt)
        case .docDate:
            result = compare(lhs.docDate ?? lhs.createdAt, rhs.docDate ?? rhs.createdAt)
        case .field(let key):
            result = (lhs.values[key] ?? "").localizedStandardCompare(rhs.values[key] ?? "")
        }
        return order == .forward ? result : result.reversed
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
