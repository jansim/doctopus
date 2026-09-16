import SwiftUI

/// Edits one routing rule. Works on a draft, so Cancel really does leave the
/// rule — and for a new one, the rule list — exactly as it was.
///
/// Everything the router reads is here, and what it will make of the pattern
/// and the destination is spelled out as it is typed: which words it looks for
/// (or that it is a regex, or a regex that does not compile), where a document
/// would land, and how many documents already in the library it would catch.
struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Rule
    private let isNew: Bool
    private let library: Library
    private let threshold: Double
    private let onSave: (Rule) -> Void

    @State private var samples: [Store.RuleSample]?
    @State private var matched: [String] = []
    @State private var matchCount = 0
    @State private var applying = false
    @State private var applyStatus: String?

    init(rule: Rule, library: Library, threshold: Double, onSave: @escaping (Rule) -> Void) {
        _draft = State(initialValue: rule)
        isNew = rule.id == 0
        self.library = library
        self.threshold = threshold
        self.onSave = onSave
    }

    static let fields: [(key: String, label: String)] = [
        ("text", "Text and filename"),
        ("filename", "Filename"),
        ("correspondent", "Correspondent"),
        ("type", "Document type"),
    ]

    static func label(forField key: String) -> String {
        fields.first { $0.key == key }?.label ?? key
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Toggle("Enabled", isOn: $draft.enabled)
                }

                Section {
                    Picker("Look in", selection: $draft.field) {
                        ForEach(Self.fields, id: \.key) { Text($0.label).tag($0.key) }
                    }
                    Picker("Match", selection: $draft.mode) {
                        ForEach(MatchMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField(text: $draft.pattern, prompt: Text(patternPrompt)) {
                        Text("Pattern").font(.body)
                    }
                    .font(.system(.body, design: .monospaced))
                    Toggle("Ignore capitalisation", isOn: $draft.caseInsensitive)
                    patternExplanation
                    matchPreview
                } header: {
                    Text("Match")
                }

                Section {
                    TextField(text: $draft.destination, prompt: Text("Finances/Invoices/{year}")) {
                        Text("Destination").font(.body)
                    }
                    .font(.system(.body, design: .monospaced))
                    HStack(spacing: 4) {
                        ForEach(["{year}", "{month}", "{correspondent}", "{type}"], id: \.self) { token in
                            Button(token) { append(token) }
                                .buttonStyle(.borderless)
                                .font(.caption.monospaced())
                        }
                        Spacer()
                    }
                    LabeledContent("For example") {
                        Text(destinationPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if destinationLeavesLibrary {
                        Label("Outside the library. Doctopus only ever routes within a library, so this rule will be skipped.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("Tags", text: Binding(
                        get: { draft.tagNames ?? "" },
                        set: { draft.tagNames = $0.nilIfBlank }),
                              prompt: Text("invoice, finances"))
                    TextField("Set Correspondent", text: Binding(
                        get: { draft.setCorrespondent ?? "" },
                        set: { draft.setCorrespondent = $0.nilIfBlank }),
                              prompt: Text("Stadtwerke München"))
                    TextField("Set Document Type", text: Binding(
                        get: { draft.setDocType ?? "" },
                        set: { draft.setDocType = $0.nilIfBlank }),
                              prompt: Text("Invoice"))
                    Text("Relative to the library folder. Tags and metadata are assigned whenever the rule matches.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Then")
                }

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
                    var rule = draft
                    rule.name = rule.name.nilIfBlank ?? "Untitled Rule"
                    rule.pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
                    rule.destination = rule.destination.trimmingCharacters(in: .whitespaces)
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 540, height: 460)
        .task {
            samples = (try? await library.store.ruleSamples()) ?? []
            refreshMatches()
        }
        .onChange(of: draft.pattern) { refreshMatches() }
        .onChange(of: draft.field) { refreshMatches() }
        .onChange(of: draft.mode) { refreshMatches() }
        .onChange(of: draft.caseInsensitive) { refreshMatches() }
    }

    private var canSave: Bool {
        draft.pattern.nilIfBlank != nil && draft.destination.nilIfBlank != nil
    }

    private func applyToMatching() {
        applying = true
        applyStatus = nil
        Task {
            var rule = draft
            rule.name = rule.name.nilIfBlank ?? "Untitled Rule"
            rule.pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
            rule.destination = rule.destination.trimmingCharacters(in: .whitespaces)
            // Applied from the draft rather than a saved copy: the rule is only
            // written to the library when the user presses Add Rule / Save.
            let res = (try? await library.store.applyRuleToExisting(rule)) ?? Store.RuleApplyResult()
            applyStatus = "Applied to \(res.matched) document\(res.matched == 1 ? "" : "s") (\(res.moved) moved, \(res.tagged) tagged)."
            applying = false
        }
    }

    // MARK: - Pattern

    private var patternPrompt: String {
        switch draft.mode {
        case .anyWord, .allWords, .fuzzy: return "invoice, rechnung, facture"
        case .exactPhrase: return "amount due"
        case .regex: return "^inv-\\d+"
        }
    }

    @ViewBuilder
    private var patternExplanation: some View {
        switch Router.kind(of: draft.pattern, mode: draft.mode) {
        case .empty:
            Text("Comma-separated words are matched at the start of a word, so “rechnung” catches “Rechnungsnummer” without firing on “Gehaltsabrechnung”.")
                .font(.caption).foregroundStyle(.secondary)
        case .words(let words):
            Text(explain(words, joiner: draft.mode == .allWords ? "all of" : "any of"))
                .font(.caption).foregroundStyle(.secondary)
        case .phrase:
            Text("Matched as one phrase, with any line break or run of spaces allowed between the words — OCR breaks a phrase across a line more often than anything else defeats a literal match.")
                .font(.caption).foregroundStyle(.secondary)
        case .fuzzy(let words):
            Text(words.isEmpty
                 ? "Close enough counts, for OCR noise."
                 : "Matches words within a typo or two of \(words.map { "“\($0)”" }.joined(separator: ", ")) — “Rechnunq” still catches “Rechnung”.")
                .font(.caption).foregroundStyle(.secondary)
        case .regex:
            Text("A regular expression\(draft.caseInsensitive ? ", ignoring capitalisation" : "").")
                .font(.caption).foregroundStyle(.secondary)
        case .invalidRegex(let reason):
            Label("Not a valid regular expression, so this rule will never match. \(reason)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func explain(_ words: [String], joiner: String) -> String {
        guard !words.isEmpty else { return "Nothing to match yet." }
        if words.count == 1 { return "Matches words starting with “\(words[0])”." }
        return "Matches \(joiner) \(words.count) words: "
            + words.map { "“\($0)”" }.joined(separator: ", ") + "."
    }

    @ViewBuilder
    private var matchPreview: some View {
        if let samples, draft.pattern.nilIfBlank != nil {
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

    /// Runs the pattern over the library with the router's own matcher, so the
    /// count is what routing would actually do. Cheap enough to redo on every
    /// keystroke for a few thousand documents.
    private func refreshMatches() {
        guard let samples else { return }
        let rule = draft
        var names: [String] = []
        var count = 0
        for sample in samples {
            let subject = Router.subject(for: rule.field, text: sample.text, filename: sample.filename,
                                         correspondent: sample.correspondent, docType: sample.docType)
            guard Router.matches(rule, in: subject) else { continue }
            count += 1
            if names.count < 3 { names.append(sample.filename) }
        }
        matchCount = count
        matched = names
    }

    // MARK: - Destination

    private func append(_ token: String) {
        if draft.destination.isEmpty || draft.destination.hasSuffix("/") {
            draft.destination += token
        } else {
            draft.destination += "/" + token
        }
    }

    /// Expanded by the router itself against a made-up document, so tokens,
    /// empty values and absolute paths all come out the way they will for real.
    private var destinationPreview: String {
        guard draft.destination.nilIfBlank != nil else { return "—" }
        let router = Router(rules: [], threshold: threshold, derivedTemplate: "",
                            root: library.root, deriveWhenNoRule: false)
        let url = router.expand(draft.destination, correspondent: "Acme Corp",
                                docType: "Invoice", date: Date())
        let rootPath = library.root.path
        if url.path == rootPath { return "\(library.displayName) (the library folder itself)" }
        if url.path.hasPrefix(rootPath + "/") {
            return library.displayName + "/" + url.path.dropFirst(rootPath.count + 1)
        }
        return url.path
    }

    private var destinationLeavesLibrary: Bool {
        guard draft.destination.nilIfBlank != nil else { return false }
        let router = Router(rules: [], threshold: threshold, derivedTemplate: "",
                            root: library.root, deriveWhenNoRule: false)
        return !router.isInsideLibrary(router.expand(draft.destination, correspondent: "Acme Corp",
                                                     docType: "Invoice", date: Date()))
    }

    private var confidenceExplanation: String {
        let pct = { (v: Double) in "\(Int((v * 100).rounded()))%" }
        if draft.weight < threshold {
            return "Below the \(pct(threshold)) routing threshold, so a match only tags the document and leaves it for review."
        }
        return "How sure a match makes Doctopus. It is scaled down a little when the extracted details disagree, and a document is only moved at \(pct(threshold)) or more."
    }
}
