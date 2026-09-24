import SwiftUI
import AppKit

/// Center pane. Owns everything shared between the list and gallery
/// presentations: selection, context menus, Quick Look, drag-and-drop.
struct DocumentListView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
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
    }

    private var browser: some View {
        Group {
            switch model.viewMode {
            case .list: DocumentTableView()
            case .gallery: DocumentGalleryView()
            }
        }
        .overlay(alignment: .center) { emptyState }
        .onCopyCommand { model.selectedRows.map { NSItemProvider(object: $0.url as NSURL) } }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDroppedFiles(urls)
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
        case .needsReview: return "Everything the pipeline filed has been reviewed, and no rule has anything left to change."
        case .queue: return "Imports, scans, moves and optimizations show up here as they happen."
        case .deleted: return "Documents you move to the Trash wait here, so putting one back brings its tags and history with it."
        case .outliers: return "No document is marked as an outlier for this rule."
        default: return "Documents added to this folder appear here as they are indexed. Right-click to scan one in from your iPhone."
        }
    }
}

private struct QueueBar: View {
    @Environment(AppModel.self) private var model

    private var pending: Int { model.documents.filter { $0.queue?.approved == false }.count }
    private var ruleMatched: Int {
        model.documents.filter { !model.pendingRuleMatches(for: $0).isEmpty }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if pending > 0 {
                    Label("\(pending) awaiting review", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if model.selection == .needsReview, ruleMatched > 0 {
                    Label("\(ruleMatched) with new rule matches", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.purple)
                }
                if pending == 0 && (model.selection != .needsReview || ruleMatched == 0) {
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

private struct DocumentTableView: View {
    @Environment(AppModel.self) private var model

    private var sortOrder: Binding<[DocumentSort]> {
        Binding(
            get: { [DocumentSort(field: model.sort, order: model.sortAscending ? .forward : .reverse)] },
            set: { new in
                guard let sort = new.first else { return }
                model.setSort(sort.field, ascending: sort.order == .forward)
            })
    }

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
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Arrival(row).tint)
                            .frame(width: 3, height: 22)
                            .help(Arrival(row).label)
                    }
                    AliasBadgedThumbnail(row: row, width: 20, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.displayTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let queue = row.queue {
                            Text(queue.detail ?? queue.action.label)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if let snippet = row.snippet {
                            Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if row.filename != row.displayTitle {
                            Text(row.filename)
                                .font(.caption).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    let pending = model.pendingRuleMatches(for: row)
                    if !pending.isEmpty {
                        Spacer(minLength: 4)
                        RuleMatchBadge(size: 16)
                            .help(RuleMatchBadge.help(pending))
                    }
                }
            }
            .width(min: 240, ideal: 400)
            .customizationID("document")
            .disabledCustomizationBehavior(.visibility)

            TableColumnForEach(queueColumns) { kind in
                TableColumn(kind.title) { (row: DocumentRow) in
                    QueueCell(row: row, kind: kind)
                }
                .width(min: 70, ideal: kind == .action ? 130 : 90)
                .customizationID("queue.\(kind.rawValue)")
            }

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

            TableColumn("Date", sortUsing: DocumentSort(field: .docDate)) { row in
                // A document date is a stored day; showing it through the local
                // calendar is how it slips to the day before.
                Text(row.docDate.map(DayDate.display)
                     ?? row.createdAt.formatted(.dateTime.year().month(.abbreviated).day()))
                    .monospacedDigit()
                    .foregroundStyle(row.docDate == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("date")

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
        .contextMenu(forSelectionType: Int64.self) { ids in
            DocumentMenu(rows: model.documents.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            model.open(model.documents.filter { ids.contains($0.id) })
        }
    }
}

enum QueueColumn: String, CaseIterable, Identifiable {
    case action, when
    var id: String { rawValue }
    var title: String {
        switch self {
        case .action: return "Action"
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
                    Image(systemName: queue.action.icon).font(.caption)
                    Text(queue.action.label)
                    if let rule = queue.rule, rule != "none" {
                        Text(rule == "derived" ? "derived" : rule)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .foregroundStyle(queue.approved ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
            case .when:
                Text(queue.at, style: .relative).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

struct AliasBadgedThumbnail: View {
    let row: DocumentRow
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 2
    var showsShadow = false

    private var isGallery: Bool { width > 60 }

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

private struct DocumentGalleryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectionAnchor: Int64?

    private var cell: CGFloat { CGFloat(model.settings.galleryThumbnailSize) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell * 1.4), spacing: 18)],
                      spacing: 20) {
                ForEach(model.documents) { row in
                    GalleryCell(row: row, width: cell)
                        .draggable(DocumentDragItem(row)) {
                            DocumentDragPreview(row: row, count: model.dragCount(from: row))
                        }
                        // One tap handler reading the click count: a stacked double-tap gesture
                        // makes SwiftUI hold every single click back.
                        .onTapGesture { click(row) }
                        .contextMenu {
                            DocumentMenu(rows: model.selectedIDs.contains(row.id) ? model.selectedRows : [row])
                        }
                }
            }
            .padding(18)
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.selectedIDs = [] }
                .contextMenu { BackgroundMenu() }
        }
    }

    private func click(_ row: DocumentRow) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            model.open(model.selectedIDs.contains(row.id) ? model.selectedRows : [row])
        } else {
            select(row)
        }
    }

    private func select(_ row: DocumentRow) {
        let outcome = GallerySelection.click(row.id, in: model.documents.map(\.id),
                                             modifiers: NSEvent.modifierFlags,
                                             selection: model.selectedIDs, anchor: selectionAnchor)
        model.selectedIDs = outcome.selection
        selectionAnchor = outcome.anchor
    }
}

/// What a click makes of the gallery's selection. Apart from the view because
/// the modifiers it branches on come from `NSEvent.modifierFlags`, which reads
/// the keyboard rather than the event: a synthetic click cannot hold ⇧ down,
/// so this is the only place a check can reach the rule.
enum GallerySelection {
    struct Outcome: Equatable {
        var selection: Set<Int64>
        var anchor: Int64?
    }

    static func click(_ id: Int64, in order: [Int64],
                      modifiers: NSEvent.ModifierFlags,
                      selection: Set<Int64>, anchor: Int64?) -> Outcome {
        if modifiers.contains(.shift), let anchor,
           let anchorIndex = order.firstIndex(of: anchor),
           let clickedIndex = order.firstIndex(of: id) {
            let range = anchorIndex < clickedIndex ? anchorIndex...clickedIndex : clickedIndex...anchorIndex
            let ids = Set(order[range])
            return Outcome(selection: modifiers.contains(.command) ? selection.union(ids) : ids,
                           anchor: anchor)
        }
        if modifiers.contains(.command) {
            var selection = selection
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            return Outcome(selection: selection, anchor: id)
        }
        return Outcome(selection: [id], anchor: id)
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
                .overlay(alignment: .bottomTrailing) {
                    let pending = model.pendingRuleMatches(for: row)
                    if !pending.isEmpty {
                        RuleMatchBadge(size: 20)
                            .help(RuleMatchBadge.help(pending))
                            .padding(9)
                    }
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
        .contentShape(.rect)
        .help(row.filename)
    }
}

private struct DocumentMenu: View {
    @Environment(AppModel.self) private var model
    let rows: [DocumentRow]

    var body: some View {
        if rows.isEmpty {
            BackgroundMenu()
        } else {
            Button("Quick Look") { model.quickLook(startingAt: rows.first) }
            Button("Open in Default App") { model.open(rows) }
            Button("Reveal in Finder") { model.reveal(rows) }
            ShareLink(items: rows.map(\.url))
            if model.selection.isQueueMode {
                Divider()
                Button("Approve") { model.setApproved(rows, true) }
                Button("Mark as Needs Review") { model.setApproved(rows, false) }
            }
            Divider()
            Menu("Tags") {
                Button("Add Tag…") { model.sheet = .addTag }
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
            Button(rows.count == 1 ? "Rename…" : "Rename \(rows.count) Files…") { model.sheet = .rename }
            if rows.count == 1 {
                Button("File In…") { model.sheet = .file(rows[0]) }
            }
            Button("Move to Folder…") { model.moveToFolderPicker(rows) }
            Divider()
            Button("Reprocess") { model.reprocess(rows) }
            Button(rows.count == 1 ? "Analyze with Model" : "Analyze \(rows.count) with Model") {
                model.analyze(rows)
            }
            .disabled(!model.modelStatus.isReady)
            Button("Optimize") { model.optimize(rows) }
            if rows.contains(where: { $0.originalSize != nil }) {
                Button("Revert to Original") { model.revertOptimization(rows) }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rows.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Menu("Import") { BackgroundMenu() }
            Divider()
            if model.selection == .deleted {
                Button("Put Back") { model.restore(rows) }
                Button("Remove from Library", role: .destructive) { model.forget(rows) }
            } else if case .folder(let folder) = model.selection, rows.allSatisfy(\.isAliasHere) {
                Button(rows.count == 1
                       ? "Remove Alias from “\((folder as NSString).lastPathComponent)”"
                       : "Remove \(rows.count) Aliases from “\((folder as NSString).lastPathComponent)”",
                       role: .destructive) { model.moveToTrash(rows) }
            } else {
                Button("Move to Trash", role: .destructive) { model.moveToTrash(rows) }
            }
        }
    }
}

private struct BackgroundMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
        guard let urls = ImportPanel.choose() else { return }
        model.importFiles(urls, into: nil)
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
                if model.hasMoreDocuments {
                    Button("Load More…") { model.loadMore() }
                        .buttonStyle(.borderless)
                        .font(.caption)
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
