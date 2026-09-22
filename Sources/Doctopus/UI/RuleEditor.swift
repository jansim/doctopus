import SwiftUI

/// Edits one rule: the conditions a document has to satisfy, and what happens
/// to it when it does. Works on a draft, so Cancel really does leave the rule —
/// and for a new one, the rule list — exactly as it was.
///
/// The count of documents already in the library the rule catches goes
/// through the same matcher routing uses, so it is what routing will do.
struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Rule
    private let isNew: Bool
    private let library: Library
    private let onSave: (Rule) -> Void

    @State private var samples: [Rule.Subject]?
    @State private var matched: [String] = []
    @State private var matchCount = 0
    @State private var applying = false
    @State private var applyStatus: String?

    init(rule: Rule, library: Library, onSave: @escaping (Rule) -> Void) {
        var rule = rule
        if rule.conditions.isEmpty { rule.conditions = [RuleCondition()] }
        if rule.actions.isEmpty { rule.actions = [RuleAction(kind: .moveFile)] }
        _draft = State(initialValue: rule)
        isNew = rule.id == 0
        self.library = library
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

    /// The draft without the rows the editor keeps on screen but nobody
    /// filled in.
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
            Picker("Match", selection: $draft.requiresAll) {
                Text("Any of these conditions").tag(false)
                Text("All of these conditions").tag(true)
            }
            .disabled(draft.conditions.count < 2)
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
            Text("Comma-separated words are matched as whole words. A * widens one: “rechnung*” also catches “Rechnungsnummer”, “*rechnung” catches “Gehaltsabrechnung”.")
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
            if let example {
                LabeledContent("For example") {
                    Text(example)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if let folder = destinationURL, !previewRouter.isInsideLibrary(folder) {
                Label("Outside the library. Doctopus only ever routes within a library, so this rule will move nothing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Then")
        } footer: {
            Text("Folders are relative to the library. When matching rules move a document to different folders, it waits in Needs Review for you to choose.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var unusedActionKinds: [RuleActionKind] {
        let used = Set(draft.actions.map(\.kind))
        return RuleActionKind.allCases.filter { !used.contains($0) }
    }

    private var previewRouter: Router {
        Router(rules: [], threshold: 1, derivedTemplate: "",
               root: library.root, deriveWhenNoRule: false)
    }

    private var destinationURL: URL? {
        guard let template = draft.destination else { return nil }
        return previewRouter.expand(template, correspondent: "Acme Corp", docType: "Invoice",
                                    date: DayDate.calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)))
    }

    /// Rendered from the same sample values as the template fields elsewhere.
    private var example: String? {
        let folder = destinationURL.map(describe)
        let name = draft.rename.map { TemplateFieldKind.filename.preview($0) }
        switch (folder, name) {
        case let (folder?, name?): return folder + "/" + name
        case let (folder?, nil): return folder + "/"
        case let (nil, name?): return name
        case (nil, nil): return nil
        }
    }

    private func describe(_ url: URL) -> String {
        let rootPath = library.root.path
        if url.path == rootPath { return library.displayName }
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
            // The draft, not a saved copy: the rule is only written to the
            // library when the user presses Add Rule / Save.
            let res = (try? await library.store.applyRuleToExisting(tidied())) ?? Store.RuleApplyResult()
            applyStatus = "Applied to \(res.matched) document\(res.matched == 1 ? "" : "s") (\(res.moved) moved, \(res.renamed) renamed, \(res.tagged) tagged)."
            applying = false
        }
    }
}

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
                RemoveButton(help: "Remove this condition", enabled: removable, action: remove)
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
        case .anyWord, .allWords: return "invoice, rechnung*"
        case .fuzzy: return "invoice, rechnung"
        case .exactPhrase: return "amount due"
        case .regex: return "^inv-\\d+"
        }
    }
}

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
                    .font(templateKind != nil ? .system(.body, design: .monospaced) : .body)
                    .onChange(of: action.value) { _, value in
                        guard templateKind == .filename, value.contains("/") else { return }
                        action.value = value.filter { $0 != "/" }
                    }
                if action.kind == .moveFile {
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
                RemoveButton(help: "Remove this action", enabled: removable, action: remove)
            }
            if let templateKind {
                HStack(spacing: 4) {
                    ForEach(tokens, id: \.self) { token in
                        Button(token) { append(token, separator: templateKind.separator) }
                            .buttonStyle(.borderless)
                            .font(.caption.monospaced())
                            .help(TemplateTokens.all.first { $0.symbol == token }?.help ?? "")
                    }
                    Spacer()
                }
            }
        }
    }

    private var templateKind: TemplateFieldKind? {
        switch action.kind {
        case .moveFile: return .path
        case .renameFile: return .filename
        default: return nil
        }
    }

    private var tokens: [String] {
        action.kind == .moveFile
            ? ["{year}", "{month}", "{correspondent}", "{type}"]
            : ["{date}", "{correspondent}", "{title}", "{type}"]
    }

    private func append(_ token: String, separator: Character) {
        if action.value.isEmpty || action.value.last == separator {
            action.value += token
        } else {
            action.value += String(separator) + token
        }
    }
}

private struct RemoveButton: View {
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}
