import SwiftUI
import AppKit

/// Every tag, or every value of one field, in one table, where several
/// spellings of one correspondent are folded into one.
struct MetadataView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var filter = ""
    @State private var merging: MergeRequest?
    @State private var sortOrder = [KeyPathComparator(\MetadataItem.count, order: .reverse)]

    /// The fields whose values are names worth listing: a number, a date or a
    /// link is not something two documents spell differently.
    static func listedFields(_ fields: [Field]) -> [Field] {
        fields.filter { field in
            if let column = field.builtinColumn { return Store.facetColumns.contains(column) }
            return field.type == .string || field.type == .select
        }
    }

    private var kind: String { model.metadataKind }
    private var fields: [Field] { Self.listedFields(model.fields) }
    private var field: Field? { fields.first { $0.key == kind } }
    private var isTags: Bool { field == nil }
    private var noun: (one: String, many: String) {
        guard let field else { return ("Tag", "Tags") }
        return (field.name, field.name.hasSuffix("s") ? field.name : field.name + "s")
    }

    private var items: [MetadataItem] {
        let all: [MetadataItem]
        if let field {
            all = (model.facets[field.key] ?? []).map { facet in
                MetadataItem(id: facet.value, name: Self.display(facet.value, field: field),
                             value: facet.value, count: facet.count, icon: facet.icon ?? field.icon)
            }
        } else {
            all = model.tags.map { tag in
                MetadataItem(id: String(tag.tagID), name: tag.path(in: model.tags), value: tag.name,
                             count: tag.count, icon: tag.icon ?? Tag.defaultIcon, color: tag.color)
            }
        }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.isEmpty ? all : all.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return shown.sorted(using: sortOrder)
    }

    private var selectedItems: [MetadataItem] { items.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .onChange(of: kind) { selected = []; filter = "" }
        .onAppear {
            if kind != MetadataKind.tags, field == nil { model.metadataKind = MetadataKind.tags }
        }
        .sheet(item: $merging) { request in
            MergeSheet(noun: noun, items: request.items) { target in merge(request.items, into: target) }
        }
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Picker("Show", selection: $model.metadataKind) {
                Text("Tags").tag(MetadataKind.tags)
                ForEach(fields) { field in
                    Text(field.name).tag(field.key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            Button("Rename…") { if let item = selectedItems.first { rename(item) } }
                .disabled(selectedItems.count != 1)
            Button("Merge…") { merging = MergeRequest(items: selectedItems) }
                .disabled(selectedItems.count < 2)
                .help("Fold the selected \(noun.many.lowercased()) into one")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(items, selection: $selected, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Label {
                    Text(item.name).lineLimit(1)
                } icon: {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color.map(TagColor.color) ?? .secondary)
                }
            }
            TableColumn("Documents", value: \.count) { item in
                Text(item.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90, max: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let item = items.first(where: { ids.contains($0.id) }) { showDocuments(item) }
        }
        .overlay {
            if items.isEmpty {
                Text(filter.isEmpty ? "No \(noun.many.lowercased()) yet." : "Nothing matches “\(filter)”.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(_ chosen: [MetadataItem]) -> some View {
        if chosen.count == 1, let item = chosen.first {
            Button("Show Documents") { showDocuments(item) }
            Button("Rename “\(item.name)”…") { rename(item) }
            Divider()
            if isTags {
                Button("Delete Tag", role: .destructive) { delete(item) }
            } else {
                Button("Clear from \(item.count) Document\(item.count == 1 ? "" : "s")",
                       role: .destructive) { delete(item) }
            }
        } else if chosen.count > 1 {
            Button("Merge \(chosen.count) \(noun.many)…") { merging = MergeRequest(items: chosen) }
        }
    }

    private func showDocuments(_ item: MetadataItem) {
        if let field {
            model.selection = .field(field.key, item.value)
        } else if let id = Int64(item.id) {
            model.selection = .tag(id)
        }
    }

    private func rename(_ item: MetadataItem) {
        guard let new = TextPrompt.ask(
            title: "Rename \(noun.one)",
            message: "Renaming to a name already in use merges the two.",
            initial: item.value) else { return }
        if let field {
            model.renameFieldValue(field, from: item.value, to: new)
        } else if let tag = storedTag(item) {
            model.renameTag(tag, to: new)
        }
    }

    private func delete(_ item: MetadataItem) {
        if let field {
            model.deleteFieldValue(field, value: item.value)
        } else if let tag = storedTag(item) {
            model.deleteTag(tag)
        }
    }

    private func merge(_ chosen: [MetadataItem], into target: String) {
        if let field {
            model.mergeFieldValues(field, chosen.map(\.value), into: target)
        } else {
            model.mergeTags(chosen.compactMap(storedTag), into: target)
        }
        selected = []
    }

    private func storedTag(_ item: MetadataItem) -> Tag? {
        model.tags.first { String($0.tagID) == item.id }
    }

    static func display(_ value: String, field: Field) -> String {
        guard field.builtinColumn == "language" else { return value }
        return Locale.current.localizedString(forLanguageCode: value)?.capitalized ?? value.uppercased()
    }
}

struct MetadataItem: Identifiable, Hashable {
    var id: String
    /// What the table shows: a tag's whole path, a language's name.
    var name: String
    /// What renaming and merging act on.
    var value: String
    var count: Int
    var icon: String
    var color: Int64?
}

private struct MergeRequest: Identifiable {
    var items: [MetadataItem]
    var id: [String] { items.map(\.id) }
}

/// Picks the name merged values end up with: one of theirs or a new one.
struct MergeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let noun: (one: String, many: String)
    let items: [MetadataItem]
    let onMerge: (String) -> Void
    @State private var choice: String
    @State private var newName = ""

    /// Cannot be an id: every one of those is a value someone typed.
    private static let newChoice = "\u{0}new"

    init(noun: (one: String, many: String), items: [MetadataItem], onMerge: @escaping (String) -> Void) {
        self.noun = noun
        self.items = items
        self.onMerge = onMerge
        _choice = State(initialValue: items.max { $0.count < $1.count }?.id ?? Self.newChoice)
    }

    private var target: String {
        if choice == Self.newChoice { return newName.trimmingCharacters(in: .whitespacesAndNewlines) }
        return items.first { $0.id == choice }?.value ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(items.count) \(noun.many)")
                .font(.headline)
            Text("Every document with one of these gets the name picked here, and the others are gone afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Picker("Keep", selection: $choice) {
                    ForEach(items) { item in
                        Text("\(item.name)  (\(item.count))").tag(item.id)
                    }
                    Text("A new name").tag(Self.newChoice)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .disabled(choice != Self.newChoice)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    onMerge(target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
