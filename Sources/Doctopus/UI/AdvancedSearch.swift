import SwiftUI

/// The search field's query as a form: its words, and a row for each filter,
/// with what the filter can be picked from. It writes the same syntax the
/// field takes and shows it as it is built, so it is also where that syntax
/// is learnt.
struct AdvancedSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var criteria = SearchCriteria()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Advanced Search").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Containing")
                        .gridColumnAlignment(.trailing)
                    TextField("Containing", text: $criteria.words,
                              prompt: Text("words, \"an exact phrase\", rent OR lease"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Not containing")
                    TextField("Not containing", text: $criteria.excluded,
                              prompt: Text("words to leave out"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if !criteria.conditions.isEmpty {
                    Text("And matching all of these")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(criteria.conditions) { condition in
                    ConditionRow(condition: binding(for: condition.id)) {
                        criteria.conditions.removeAll { $0.id == condition.id }
                    }
                }
                Button {
                    criteria.conditions.append(SearchCriteria.Condition(attribute: .tag))
                } label: {
                    Label("Add Condition", systemImage: "plus")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("In the search field")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(criteria.query.isEmpty ? "Everything" : criteria.query)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(criteria.query.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Save as Smart Folder…", action: saveAsSmartFolder)
                    .disabled(criteria.query.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Search", action: search)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 660)
        .onAppear {
            criteria = SearchCriteria(model.searchText, fieldKeys: Set(model.fields.map(\.key)))
        }
    }

    /// By id rather than by index, so the row a removal leaves behind cannot
    /// be read past the end of the list.
    private func binding(for id: UUID) -> Binding<SearchCriteria.Condition> {
        Binding(
            get: { criteria.conditions.first { $0.id == id } ?? SearchCriteria.Condition(id: id, attribute: .tag) },
            set: { changed in
                guard let i = criteria.conditions.firstIndex(where: { $0.id == id }) else { return }
                criteria.conditions[i] = changed
            })
    }

    private func search() {
        // The metadata pane has no list for a search to show in.
        if model.selection == .metadata { model.selection = .all }
        model.searchText = criteria.query
        dismiss()
    }

    private func saveAsSmartFolder() {
        let query = criteria.query
        guard let name = TextPrompt.ask(title: "New Smart Folder",
                                        message: "Creates a smart folder matching “\(query)”.",
                                        initial: "", confirm: "Create") else { return }
        search()
        model.saveCurrentSearchAsSmartFolder(name: name)
    }
}

private struct ConditionRow: View {
    @Environment(AppModel.self) private var model
    @Binding var condition: SearchCriteria.Condition
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Attribute", selection: attribute) {
                ForEach([SearchCriteria.Attribute.tag, .finderTag, .folder, .fileType, .status], id: \.self) {
                    Text(name(of: $0)).tag($0)
                }
                Divider()
                ForEach(fieldAttributes, id: \.self) { Text(name(of: $0)).tag($0) }
                Divider()
                ForEach([SearchCriteria.Attribute.documentDate, .added, .analyzed], id: \.self) {
                    Text(name(of: $0)).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Picker("Relation", selection: $condition.relation) {
                ForEach(condition.attribute.relations, id: \.self) { relation in
                    Text(label(relation)).tag(relation)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            value
                .frame(maxWidth: .infinity)

            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this condition")
        }
    }

    @ViewBuilder
    private var value: some View {
        switch condition.attribute {
        case .status:
            Picker("Status", selection: status) {
                ForEach(statuses, id: \.self) { Text(Self.statusLabels[$0] ?? $0).tag($0) }
            }
            .labelsHidden()
        case .fileType:
            Picker("File Type", selection: $condition.value) {
                ForEach(fileTypes, id: \.self) { Text($0.uppercased()).tag($0) }
            }
            .labelsHidden()
        case .documentDate, .added, .analyzed:
            HStack(spacing: 4) {
                TextField("Date", text: $condition.value, prompt: Text("this month, 2025, 2025-03…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if !condition.value.isEmpty, SearchDateParser.parse(condition.value) == nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Not a date search can read. Try today, last month, 2025, 2025-03 or 2025-01..2025-06.")
                }
                Menu {
                    ForEach(datePresets, id: \.self) { preset in
                        Button(preset.capitalized) { condition.value = preset }
                    }
                } label: {
                    Image(systemName: "calendar")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick a period")
            }
        default:
            HStack(spacing: 4) {
                TextField(name(of: condition.attribute), text: $condition.value)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .valueSuggestions(candidates, for: condition.value)
                if !candidates.isEmpty {
                    Menu {
                        ForEach(candidates.prefix(50), id: \.self) { candidate in
                            Button(candidate) { condition.value = candidate }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pick one already in use")
                }
            }
        }
    }

    /// A value typed into the row stays when it still means something under
    /// the new attribute — a date is still a date, a name still a name.
    private var attribute: Binding<SearchCriteria.Attribute> {
        Binding(
            get: { condition.attribute },
            set: { next in
                let before = condition.attribute
                guard next != before else { return }
                condition.attribute = next
                if !next.relations.contains(condition.relation) { condition.relation = .is }
                if next.hasFixedValues || before.hasFixedValues || next.isDate != before.isDate {
                    condition.value = next.initialValue
                }
            })
    }

    /// `is:` takes any of a flag's names; the picker shows each flag under its first.
    private var status: Binding<String> {
        Binding(
            get: {
                let typed = condition.value.lowercased()
                return SearchQuery.flagPredicates.first { $0.names.contains(typed) }?.names[0] ?? condition.value
            },
            set: { condition.value = $0 })
    }

    private var fieldAttributes: [SearchCriteria.Attribute] {
        var listed = model.fields.filter(\.enabled).map { SearchCriteria.Attribute.field($0.key) }
        // A field the query names but the library no longer offers, so the
        // picker still has a row to show it on.
        if case .field = condition.attribute, !listed.contains(condition.attribute) {
            listed.append(condition.attribute)
        }
        return listed
    }

    private func name(of attribute: SearchCriteria.Attribute) -> String {
        switch attribute {
        case .tag: return "Tag"
        case .finderTag: return "Finder Tag"
        case .folder: return "Folder"
        case .fileType: return "File Type"
        case .status: return "Status"
        case .field(let key): return model.fields.first { $0.key == key }?.name ?? key
        case .documentDate: return "Document Date"
        case .added: return "Date Added"
        case .analyzed: return "Date Analyzed"
        }
    }

    /// A field matches what contains the value; everything else matches it whole.
    private func label(_ relation: SearchCriteria.Relation) -> String {
        if case .field = condition.attribute {
            return relation == .isNot ? "does not contain" : "contains"
        }
        switch relation {
        case .is: return "is"
        case .isNot: return "is not"
        case .before: return "is before"
        case .after: return "is after"
        }
    }

    private static let statusLabels = [
        "review": "Not reviewed", "approved": "Reviewed", "untagged": "Untagged", "tagged": "Tagged",
        "pending": "Waiting for OCR", "failed": "OCR failed", "optimized": "Optimized",
        "duplicate": "A duplicate", "stale-analysis": "Analysis out of date", "analyzed": "Analyzed",
        "unanalyzed": "Not analyzed", "missing": "Missing", "trashed": "In the Trash",
    ]

    private var statuses: [String] {
        let known = SearchQuery.flagPredicates.map { $0.names[0] }
        return known.contains(status.wrappedValue) ? known : known + [status.wrappedValue]
    }

    private var fileTypes: [String] {
        let types = SearchCriteria.fileTypes
        let typed = condition.value.lowercased()
        return types.contains(typed) || typed.isEmpty ? types : types + [typed]
    }

    private var datePresets: [String] {
        let year = Calendar.current.component(.year, from: .now)
        return ["today", "yesterday", "this week", "last week", "this month", "last month",
                "this quarter", "last quarter", "this year", "last year", "\(year)", "\(year - 1)"]
    }

    private var candidates: [String] {
        switch condition.attribute {
        case .tag: return model.tagNames
        case .finderTag: return model.finderTags.map(\.value)
        case .folder: return Self.folderNames(model.folders)
        case .field(let key):
            let options = model.fields.first { $0.key == key }?.options ?? []
            let used = (model.facets[key] ?? []).map(\.value)
            return options + used.filter { !options.contains($0) }
        default: return []
        }
    }

    /// `in:` names a folder at any depth, so each name is offered once.
    private static func folderNames(_ nodes: [FolderNode]) -> [String] {
        var names: Set<String> = []
        func collect(_ nodes: [FolderNode]) {
            for node in nodes {
                if !node.isRoot { names.insert(node.name) }
                collect(node.children)
            }
        }
        collect(nodes)
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
