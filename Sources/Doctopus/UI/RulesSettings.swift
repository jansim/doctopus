import SwiftUI

struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [Rule] = []
    @State private var selected: Rule.ID?
    @State private var editing: Rule?
    @State private var outlierCounts: [Rule.ID: Int] = [:]
    @State private var showingOutliers: Rule.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                ScopeBadge(scope: .library)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

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
                TableColumn("Suppressed") { r in
                    outlierCell(r)
                }
                .width(70)
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
        .task(id: model.library?.id) { await load() }
        .onChange(of: model.library?.outlierRevision) { Task { await load() } }
        .onChange(of: model.ruleToEdit) { openRequestedRule() }
        .sheet(item: $editing) { rule in
            if let library = model.library {
                RuleEditor(rule: rule, library: library) { save($0) }
            }
        }
    }

    @ViewBuilder
    private func outlierCell(_ rule: Rule) -> some View {
        let count = outlierCounts[rule.id] ?? 0
        if count == 0 {
            Text("—").foregroundStyle(.tertiary)
        } else {
            Button("\(count)") { showingOutliers = rule.id }
                .buttonStyle(.link)
                .monospacedDigit()
                .help("Documents marked as outliers for “\(rule.name)”")
                .popover(isPresented: Binding(
                    get: { showingOutliers == rule.id },
                    set: { if !$0 { showingOutliers = nil } }),
                         arrowEdge: .trailing) {
                    if let library = model.library {
                        OutlierList(rule: rule, library: library) {
                            Task { await load() }
                        } onShow: {
                            showingOutliers = nil
                        }
                    }
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
        let store = model.library?.store
        rules = (try? await store?.rules()) ?? []
        outlierCounts = (try? await store?.suppressionCounts()) ?? [:]
        openRequestedRule()
    }

    /// A rule asked for from elsewhere, such as a conflict in a document's rule
    /// matches. It waits for `load` when the pane has only just appeared, and
    /// is dropped if the rule has gone since, so it can't reopen the pane later.
    private func openRequestedRule() {
        guard let id = model.ruleToEdit else { return }
        model.ruleToEdit = nil
        guard let rule = rules.first(where: { $0.id == id }) else { return }
        selected = id
        editing = rule
    }

    private func toggle(_ rule: Rule, _ on: Bool) {
        var r = rule
        r.enabled = on
        save(r)
    }

    private func save(_ rule: Rule) {
        guard let store = model.library?.store else { return }
        Task {
            var id = rule.id
            do { id = try await store.upsertRule(rule) }
            catch { model.report(error, "save the rule “\(rule.name)”") }
            await load()
            selected = id
            rulesChanged()
        }
    }

    private func rulesChanged() {
        model.rulesChanged()
    }

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
        guard let store = model.library?.store else { return }
        Task {
            do {
                try await store.deleteRule(id)
                if selected == id { selected = nil }
            } catch { model.report(error, "delete the rule") }
            await load()
            rulesChanged()
        }
    }

    private func move(_ id: Rule.ID, by offset: Int) {
        guard let store = model.library?.store,
              let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        var ordered = rules.map(\.id)
        ordered.swapAt(index, target)
        Task {
            do { try await store.reorderRules(ordered) } catch { model.report(error, "reorder the rules") }
            await load()
            selected = id
            rulesChanged()
        }
    }
}

private struct OutlierList: View {
    @Environment(AppModel.self) private var model
    let rule: Rule
    let library: Library
    let onChange: () -> Void
    let onShow: () -> Void
    @State private var outliers: [Store.Outlier] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Outliers for “\(rule.name)”")
                .font(.headline)
            Text("The rule matches these documents but leaves them alone.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(outliers) { outlier in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(outlier.filename).lineLimit(1).truncationMode(.middle)
                                Text(outlier.folder)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 8)
                            Button {
                                unsuppress(outlier)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop suppressing: let “\(rule.name)” point this document out again")
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
            Divider()
            HStack {
                Spacer()
                Button("Show in Library") {
                    model.showOutliers(of: rule.id)
                    model.bringToFront()
                    onShow()
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .task { await load() }
    }

    private func load() async {
        outliers = (try? await library.store.outliers(of: rule.id)) ?? []
    }

    private func unsuppress(_ outlier: Store.Outlier) {
        Task {
            await model.setRuleSuppressed(false, rule: rule.id, name: rule.name,
                                          doc: outlier.doc, in: library)
            await load()
            onChange()
        }
    }
}
