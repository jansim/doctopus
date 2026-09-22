import SwiftUI

/// Every rule in the chosen library, in the order they are evaluated.
struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [Rule] = []
    @State private var selected: Rule.ID?
    /// The rule open in the editor sheet — an unsaved draft when adding.
    @State private var editing: Rule?

    var body: some View {
        VStack(spacing: 0) {
            if model.libraries.count > 1 {
                Form { LibraryPicker() }
                    .formStyle(.grouped)
                    .frame(height: 64)
                Divider()
            }

            Table(rules, selection: $selected) {
                TableColumn("Rule") { r in
                    Text(r.name).foregroundStyle(r.enabled ? .primary : .secondary)
                }
                TableColumn("If") { r in
                    Text(r.conditionSummary)
                        .font(.caption.monospaced()).lineLimit(1)
                        .help(conditionHelp(r))
                }
                TableColumn("Then") { r in
                    Text(r.actionSummary)
                        .font(.caption.monospaced()).lineLimit(1)
                        .help(r.actionSummary)
                }
                TableColumn("On") { r in
                    Toggle("", isOn: Binding(get: { r.enabled }, set: { toggle(r, $0) })).labelsHidden()
                }
                .width(30)
            }
            .contextMenu(forSelectionType: Rule.ID.self) { ids in
                if let id = ids.first, let rule = rules.first(where: { $0.id == id }) {
                    Button("Edit…") { editing = rule }
                    Button("Duplicate") { duplicate(rule) }
                    Divider()
                    Button("Move Up") { move(id, by: -1) }.disabled(rules.first?.id == id)
                    Button("Move Down") { move(id, by: 1) }.disabled(rules.last?.id == id)
                    Divider()
                    Button("Delete", role: .destructive) { remove(id) }
                }
            } primaryAction: { ids in
                // Double-click (or Return) opens the rule.
                if let id = ids.first { editing = rules.first { $0.id == id } }
            }

            HStack(spacing: 10) {
                Button { addRule() } label: { Image(systemName: "plus") }
                    .help("Add a rule")
                Button { if let selected { remove(selected) } } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                    .help("Delete the selected rule")
                Button { editing = selectedRule } label: { Image(systemName: "pencil") }
                    .disabled(selected == nil)
                    .help("Edit the selected rule")
                Divider().frame(height: 14)
                Button { if let selected { move(selected, by: -1) } } label: { Image(systemName: "chevron.up") }
                    .disabled(selected == nil || rules.first?.id == selected)
                    .help("Evaluate earlier")
                Button { if let selected { move(selected, by: 1) } } label: { Image(systemName: "chevron.down") }
                    .disabled(selected == nil || rules.last?.id == selected)
                    .help("Evaluate later")
                Spacer()
                Text("Every rule that matches applies. If matching rules move a document to different folders, it waits in Needs Review; otherwise the higher rule wins. Double-click to edit.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .task { await load() }
        .task(id: model.settingsLibrary?.id) { await load() }
        .sheet(item: $editing) { rule in
            if let library = model.settingsLibrary {
                RuleEditor(rule: rule, library: library) { save($0) }
            }
        }
    }

    private func conditionHelp(_ rule: Rule) -> String {
        let live = rule.liveConditions
        guard !live.isEmpty else { return "No conditions yet" }
        let lines = live.map { "\($0.field.label) \($0.negated ? "does not match" : "matches") \($0.mode.shortLabel.lowercased()): \($0.pattern)" }
        guard lines.count > 1 else { return lines[0] }
        return (rule.requiresAll ? "All of:\n" : "Any of:\n") + lines.joined(separator: "\n")
    }

    private var selectedRule: Rule? { rules.first { $0.id == selected } }

    private func load() async {
        rules = (try? await model.settingsLibrary?.store.rules()) ?? []
    }

    private func toggle(_ rule: Rule, _ on: Bool) {
        var r = rule
        r.enabled = on
        save(r)
    }

    private func save(_ rule: Rule) {
        guard let store = model.settingsLibrary?.store else { return }
        Task {
            let id = (try? await store.upsertRule(rule)) ?? rule.id
            await load()
            selected = id
        }
    }

    /// A new rule is only a draft until the editor saves it, so cancelling
    /// leaves nothing behind. It goes to the bottom of the list, where it
    /// cannot pre-empt a rule that already works.
    private func addRule() {
        let lowest = rules.map(\.priority).min() ?? 10
        editing = Rule(id: 0, name: "", priority: lowest - 10)
    }

    private func duplicate(_ rule: Rule) {
        var copy = rule
        copy.id = 0
        copy.name = rule.name + " copy"
        copy.priority = rule.priority - 1
        editing = copy
    }

    private func remove(_ id: Rule.ID) {
        guard let store = model.settingsLibrary?.store else { return }
        Task {
            try? await store.deleteRule(id)
            if selected == id { selected = nil }
            await load()
        }
    }

    /// Order is priority, so moving a rule rewrites every priority to match
    /// the new order rather than trying to squeeze one number in between.
    private func move(_ id: Rule.ID, by offset: Int) {
        guard let store = model.settingsLibrary?.store,
              let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        var ordered = rules.map(\.id)
        ordered.swapAt(index, target)
        Task {
            try? await store.reorderRules(ordered)
            await load()
            selected = id
        }
    }
}
