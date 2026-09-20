import SwiftUI

/// Edits one rule: the conditions a document has to satisfy, and what happens
/// to it when it does. Works on a draft, so Cancel really does leave the rule —
/// and for a new one, the rule list — exactly as it was.
///
/// What the rule will do is spelled out as it is typed: a regex that does not
/// compile says so on the condition that owns it, the folder shows where a
/// document would land, and the count says how many documents already in the
/// library the whole rule catches — conditions, join and all, through the same
/// matcher routing uses.
struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Rule
    private let isNew: Bool
    private let library: Library
    private let threshold: Double
    private let onSave: (Rule) -> Void

    @State private var samples: [Rule.Subject]?
    @State private var matched: [String] = []
    @State private var matchCount = 0
    @State private var applying = false
    @State private var applyStatus: String?

    init(rule: Rule, library: Library, threshold: Double, onSave: @escaping (Rule) -> Void) {
        var rule = rule
        // A rule always shows at least one condition and one action: an empty
        // list would make the first thing anyone has to do be finding the
        // button that adds one.
        if rule.conditions.isEmpty { rule.conditions = [RuleCondition()] }
        if rule.actions.isEmpty { rule.actions = [RuleAction(kind: .fileInto)] }
        _draft = State(initialValue: rule)
        isNew = rule.id == 0
        self.library = library
        self.threshold = threshold
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Toggle("Enabled", isOn: $draft.enabled)
                }

                conditionsSection
                actionsSection

                if matchCount > 0 {
                    Section {
                        Button(applying ? "Applying…" : "Apply to \(matchCount) matching document\(matchCount == 1 ? "" : "s")…") {
                            applyToMatching()
                        }
                        .disabled(applying || !canSave)
                        if let applyStatus {
                            Text(applyStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Apply to Existing")
                    }
                }

                Section {
                    LabeledContent("Confidence") {
                        HStack {
                            Slider(value: $draft.weight, in: 0.5...0.99)
                            Text("\(Int((draft.weight * 100).rounded()))%")
                                .monospacedDigit().frame(width: 40)
                        }
                    }
                    Text(confidenceExplanation)
                        .font(.caption)
                        .foregroundStyle(draft.weight < threshold ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    onSave(tidied())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 580, height: 600)
        .task {
            samples = (try? await library.store.ruleSamples()) ?? []
            refreshMatches()
        }
        .onChange(of: draft.conditions) { refreshMatches() }
        .onChange(of: draft.requiresAll) { refreshMatches() }
    }

    /// The draft as it deserves to be stored: trimmed, named, and without the
    /// rows the editor keeps on screen but nobody filled in.
    private func tidied() -> Rule {
        var rule = draft
        rule.name = rule.name.nilIfBlank ?? "Untitled Rule"
        rule.conditions = rule.conditions.filter { $0.pattern.nilIfBlank != nil }
        rule.actions = rule.actions.filter { $0.value.nilIfBlank != nil }
        return rule
    }

    private var canSave: Bool {
        !draft.liveConditions.isEmpty && draft.hasEffect
    }

    // MARK: - Conditions

    @ViewBuilder
    private var conditionsSection: some View {
        Section {
            if draft.conditions.count > 1 {
                Picker("Match", selection: $draft.requiresAll) {
                    Text("Any of these conditions").tag(false)
                    Text("All of these conditions").tag(true)
                }
            }
            ForEach($draft.conditions) { $condition in
                ConditionRow(condition: $condition,
                             removable: draft.conditions.count > 1) {
                    draft.conditions.removeAll { $0.id == condition.id }
                }
            }
            Button {
                draft.conditions.append(RuleCondition())
            } label: {
                Label("Add Condition", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            matchPreview
        } header: {
            Text("If")
        } footer: {
            Text("Comma-separated words are matched at the start of a word, so “rechnung” catches “Rechnungsnummer” without firing on “Gehaltsabrechnung”.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var matchPreview: some View {
        if let samples, !draft.liveConditions.isEmpty {
            LabeledContent("In this library") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(matchCount) of \(samples.count) document\(samples.count == 1 ? "" : "s")")
                        .monospacedDigit()
                    if !matched.isEmpty {
                        Text(matched.joined(separator: ", ") + (matchCount > matched.count ? ", …" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    /// Runs the rule over the library with its own matcher, so the count is
    /// what routing would really do. Cheap enough to redo on every keystroke
    /// for a few thousand documents.
    private func refreshMatches() {
        guard let samples else { return }
        let rule = draft
        var names: [String] = []
        var count = 0
        for sample in samples where rule.matches(sample) {
            count += 1
            if names.count < 3 { names.append(sample.filename) }
        }
        matchCount = count
        matched = names
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            ForEach($draft.actions) { $action in
                ActionRow(action: $action, library: library,
                          removable: draft.actions.count > 1) {
                    draft.actions.removeAll { $0.id == action.id }
                }
            }
            if !unusedActionKinds.isEmpty {
                Menu {
                    ForEach(unusedActionKinds, id: \.self) { kind in
                        Button(kind.label) { draft.actions.append(RuleAction(kind: kind)) }
                    }
                } label: {
                    Label("Add Action", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let folder = destinationURL {
                LabeledContent("For example") {
                    Text(describe(folder))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !previewRouter.isInsideLibrary(folder) {
                    Label("Outside the library. Doctopus only ever routes within a library, so this rule will file nothing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Then")
        } footer: {
            Text("Folders are relative to the library. Tags and metadata are assigned whenever the rule matches, whether or not the document is moved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Each kind of action says one thing, so a rule that already files into a
    /// folder is not offered a second folder to file into.
    private var unusedActionKinds: [RuleActionKind] {
        let used = Set(draft.actions.map(\.kind))
        return RuleActionKind.allCases.filter { !used.contains($0) }
    }

    private var previewRouter: Router {
        Router(rules: [], threshold: threshold, derivedTemplate: "",
               root: library.root, deriveWhenNoRule: false)
    }

    private var destinationURL: URL? {
        guard let template = draft.destination else { return nil }
        return previewRouter.expand(template, correspondent: "Acme Corp",
                                    docType: "Invoice", date: Date())
    }

    private func describe(_ url: URL) -> String {
        let rootPath = library.root.path
        if url.path == rootPath { return "\(library.displayName) (the library folder itself)" }
        if url.path.hasPrefix(rootPath + "/") {
            return library.displayName + "/" + url.path.dropFirst(rootPath.count + 1)
        }
        return url.path
    }

    // MARK: - Applying

    private func applyToMatching() {
        applying = true
        applyStatus = nil
        Task {
            // Applied from the draft rather than a saved copy: the rule is only
            // written to the library when the user presses Add Rule / Save.
            let res = (try? await library.store.applyRuleToExisting(tidied())) ?? Store.RuleApplyResult()
            applyStatus = "Applied to \(res.matched) document\(res.matched == 1 ? "" : "s") (\(res.moved) moved, \(res.tagged) tagged)."
            applying = false
        }
    }

    private var confidenceExplanation: String {
        let pct = { (v: Double) in "\(Int((v * 100).rounded()))%" }
        if draft.destination == nil {
            return "This rule files nothing, so its confidence only labels what it did in the queue."
        }
        if draft.weight < threshold {
            return "Below the \(pct(threshold)) routing threshold, so a match only tags the document and leaves it for review."
        }
        return "How sure a match makes Doctopus. It is scaled down a little when the extracted details disagree, and a document is only moved at \(pct(threshold)) or more."
    }
}

/// One condition: what to look at, whether the match is wanted or unwanted,
/// how to read the pattern, and the pattern itself.
private struct ConditionRow: View {
    @Binding var condition: RuleCondition
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: $condition.field) {
                    ForEach(RuleField.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                Picker("", selection: $condition.negated) {
                    Text("matches").tag(false)
                    Text("does not match").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                // Hidden rather than disabled on the last one: a control that
                // is always there and never works reads as broken.
                if removable {
                    Button(role: .destructive) { remove() } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this condition")
                }
            }
            HStack(spacing: 6) {
                Picker("", selection: $condition.mode) {
                    ForEach(MatchMode.allCases, id: \.self) { Text($0.shortLabel).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("", text: $condition.pattern, prompt: Text(prompt))
                    .font(.system(.body, design: .monospaced))
                Toggle("Aa", isOn: Binding(get: { !condition.caseInsensitive },
                                           set: { condition.caseInsensitive = !$0 }))
                    .toggleStyle(.button)
                    .help("Match capitalisation exactly")
            }
            if case .invalidRegex(let reason) = Router.kind(of: condition.pattern, mode: condition.mode) {
                Label("Not a valid regular expression, so this condition will never match. \(reason)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var prompt: String {
        switch condition.mode {
        case .anyWord, .allWords, .fuzzy: return "invoice, rechnung, facture"
        case .exactPhrase: return "amount due"
        case .regex: return "^inv-\\d+"
        }
    }
}

/// One action: what to do, and the one value it takes.
private struct ActionRow: View {
    @Binding var action: RuleAction
    let library: Library
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(action.kind.label)
                    .frame(width: 130, alignment: .leading)
                TextField("", text: $action.value, prompt: Text(action.kind.placeholder))
                    .font(action.kind == .fileInto
                          ? .system(.body, design: .monospaced) : .body)
                if action.kind == .fileInto {
                    Button {
                        guard let chosen = FolderPicker.chooseRelativePath(
                            in: library, message: "Choose a folder inside \(library.displayName).")
                        else { return }
                        action.value = chosen
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Choose a folder")
                }
                if removable {
                    Button(role: .destructive) { remove() } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this action")
                }
            }
            if action.kind == .fileInto {
                HStack(spacing: 4) {
                    ForEach(["{year}", "{month}", "{correspondent}", "{type}"], id: \.self) { token in
                        Button(token) { append(token) }
                            .buttonStyle(.borderless)
                            .font(.caption.monospaced())
                    }
                    Spacer()
                }
            }
        }
    }

    private func append(_ token: String) {
        if action.value.isEmpty || action.value.hasSuffix("/") {
            action.value += token
        } else {
            action.value += "/" + token
        }
    }
}
