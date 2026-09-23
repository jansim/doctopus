import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FieldSettings().tabItem { Label("Fields", systemImage: "list.bullet.rectangle") }
            TagSettings().tabItem { Label("Tags", systemImage: "tag") }
            RoutingSettings().tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
            RulesSettings().tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease") }
            OptimizationSettings().tabItem { Label("Optimization", systemImage: "arrow.down.circle") }
            IntelligenceSettings().tabItem { Label("Intelligence", systemImage: "sparkles") }
        }
        .frame(width: 620, height: 470)
        .noticeOverlay(model)
    }
}

struct LibraryPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.libraries.count > 1 {
            Picker("Library", selection: Binding(
                get: { model.settingsLibrary?.id ?? "" },
                set: { model.settingsLibraryID = $0.isEmpty ? nil : $0 })) {
                ForEach(model.libraries) { library in
                    Text(library.displayName).tag(library.id)
                }
            }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Libraries") {
                if model.libraries.isEmpty {
                    Text("No library open yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.libraries) { library in
                        HStack {
                            Text(shorten(library.root.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Reveal", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([library.container])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            Button("Close", role: .destructive) { model.closeLibrary(library) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button("New Library from Folder…") { model.addLibrary() }
                Button("Open Library…") { model.openLibraryPicker() }
            }

            if !model.libraries.isEmpty {
                Section("Library Settings", scope: .library) {
                    LibraryPicker()
                    TemplateField(title: "Default rename template",
                                  template: $model.settings.namingTemplate, kind: .filename,
                                  naming: model.settings.namingOptions)
                    Toggle("Replace spaces with underscores in filenames",
                           isOn: $model.settings.filenameUnderscoresForSpaces)
                    Toggle("Replace special characters with ASCII in filenames",
                           isOn: $model.settings.filenameASCIIOnly)
                    Text("For example ä becomes ae and á becomes a; characters with no ASCII equivalent are dropped. Applies to every rename, including rules. Folder names are left as they are.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Scan destination folder", text: $model.settings.scanDestination)
                    Text("Relative to this library's folder. Right-clicking a folder in the sidebar always overrides it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Mirror all tags to disk as Finder aliases", isOn: $model.settings.mirrorTagsAsAliases)
                    Text("Aliases live in a Tags folder inside the library's folder. Individual tags can override this from the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Dates", scope: .library) {
                    Picker("Read 03/04/2026 as", selection: $model.settings.dateOrder) {
                        ForEach(DateOrder.allCases, id: \.self) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    Text("A numeric date with no month name in it is ambiguous, and reading it by this Mac's own region means the same library answering differently on another one. Automatic reads it from the language most of these documents are in.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Never a document date", text: $model.settings.ignoredDates,
                              prompt: Text("2019-01-01, 2020-05-04"))
                        .font(.system(.body, design: .monospaced))
                    Text("Days to skip when reading a document's date, as yyyy-MM-dd — the date printed in a letterhead, or a form's revision date, which otherwise gets picked up on every document that uses it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Indexing", scope: .app) {
                Picker("OCR concurrency", selection: $model.settings.ocrConcurrency) {
                    Text("Automatic (\(model.settings.effectiveConcurrency))").tag(0)
                    ForEach([1, 2, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Text("How much of this Mac to spend on OCR, whichever library is being indexed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct FieldSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var newType: FieldType = .string

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(model.fields) { field in
                        FieldRow(field: field)
                    }
                } header: {
                    HStack {
                        Text("Fields")
                        ScopeBadge(scope: .openLibraries)
                        Spacer()
                        Text("Sidebar")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 52)
                        Text("Column")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 52)
                    }
                } footer: {
                    Text("Sidebar shows the field as a browsable section; Column adds it to the list view. Every enabled field is editable in the inspector, and its values can be renamed — or merged — by right-clicking them in the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Add a Field") {
                    HStack {
                        TextField("Name", text: $newName)
                            .onSubmit(add)
                        Picker("", selection: $newType) {
                            ForEach(FieldType.allCases, id: \.self) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Button("Add", action: add)
                            .disabled(newName.nilIfBlank == nil)
                    }
                    Text("A field's type is what makes it sortable: amounts compare as numbers rather than as text, so €90 comes before €1,200, and a Yes / No field stops being three spellings of the same answer.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Custom fields are yours to fill in — the extraction pipeline populates the built-in ones only. Fields are shared by every open library, so the list shows one column per field however many libraries fill it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func add() {
        guard let name = newName.nilIfBlank else { return }
        model.addCustomField(named: name, type: newType)
        newName = ""
        newType = .string
    }
}

private struct FieldRow: View {
    @Environment(AppModel.self) private var model
    let field: Field
    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: field.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .onSubmit {
                    guard let clean = name.nilIfBlank, clean != field.name else { return }
                    var updated = field
                    updated.name = clean
                    model.updateField(updated)
                }
            if field.isBuiltin {
                Text(field.type == .string ? "built-in" : "built-in · \(field.type.label)")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Picker("", selection: Binding(
                    get: { field.type },
                    set: { new in
                        var updated = field
                        updated.type = new
                        model.updateField(updated)
                    })) {
                    ForEach(FieldType.allCases, id: \.self) { type in
                        Text(type.label).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .help("What this field holds. Changing it re-reads every value it already has.")
            }
            Toggle("", isOn: binding(\.showInSidebar)).labelsHidden().frame(width: 52)
            Toggle("", isOn: binding(\.showInList)).labelsHidden().frame(width: 52)
            Menu {
                Button("Move Up") { move(by: -1) }
                Button("Move Down") { move(by: 1) }
                Divider()
                Button(field.isBuiltin ? "Hide Field" : "Delete Field", role: .destructive) {
                    model.deleteField(field)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .onAppear { name = field.name }
        .onChange(of: field.name) { _, new in name = new }
    }

    private func binding(_ path: WritableKeyPath<Field, Bool>) -> Binding<Bool> {
        Binding(get: { field[keyPath: path] },
                set: { new in
                    var updated = field
                    updated[keyPath: path] = new
                    model.updateField(updated)
                })
    }

    private func move(by offset: Int) {
        let ordered = model.fields
        guard let index = ordered.firstIndex(where: { $0.id == field.id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        var a = ordered[index], b = ordered[target]
        swap(&a.position, &b.position)
        model.updateField(a)
        model.updateField(b)
    }
}

private struct TagSettings: View {
    @Environment(AppModel.self) private var model

    private var tags: [Tag] { model.settingsLibrary?.tags ?? [] }

    var body: some View {
        Form {
            Section {
                LibraryPicker()
                if tags.isEmpty {
                    Text("No tags yet. Add one from a document's inspector or context menu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(tags) { tag in
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(Array(TagColor.names.enumerated()), id: \.offset) { index, name in
                                Button(name) { model.setTagColor(tag, Int64(index)) }
                            }
                        } label: {
                            Circle()
                                .fill(TagColor.color(tag.color))
                                .frame(width: 13, height: 13)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 20)

                        Text(tag.name)
                        Spacer()
                        Text("\(tag.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Toggle("Mirror", isOn: Binding(
                            get: { tag.mirrors },
                            set: { model.setTagMirroring(tag, enabled: $0) }))
                            .toggleStyle(.checkbox)
                            .help("Mirror this tag to disk as Finder aliases")
                        Button {
                            guard let new = TextPrompt.ask(title: "Rename Tag",
                                                           message: "Renaming to an existing tag merges them.",
                                                           initial: tag.name) else { return }
                            model.renameTag(tag, to: new)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            model.deleteTag(tag)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                ScopedHeader(title: "Tags", scope: .library)
            } footer: {
                Text("Mirrored tags get a folder of Finder aliases inside the indexed root, so tag membership is visible from Finder without duplicating any file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RoutingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LibraryPicker()
                Toggle("Auto-route imports and scans", isOn: $model.settings.autoRouteImports)
                Toggle("Derive a folder when no rule matches", isOn: $model.settings.deriveWhenNoRule)
                    .disabled(!model.settings.autoRouteImports)
                TemplateField(title: "Derived path template",
                              template: $model.settings.derivedTemplate, kind: .path,
                              library: model.settingsLibrary)
                    .disabled(!model.settings.deriveWhenNoRule)
                LabeledContent("Confidence threshold") {
                    HStack {
                        Slider(value: $model.settings.routingThreshold, in: 0.4...0.99)
                        Text("\(Int(model.settings.routingThreshold * 100))%")
                            .monospacedDigit().frame(width: 40)
                    }
                }
                .disabled(!model.settings.deriveWhenNoRule)
                Text("Only new scans and imports with no folder chosen are routed. A derived folder is only used above the threshold, and when matching rules name different folders a file stays in the Inbox and waits in Needs Review with its suggestions. Files already in your library are never moved automatically, and nothing is ever routed outside it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                ScopedHeader(title: "Auto-Routing", scope: .library)
            } footer: {
                Text("What a document is matched against, and where it goes, is in Rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct OptimizationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("When to Optimize", scope: .library) {
                LibraryPicker()
                Toggle("Optimize imports and scans", isOn: $model.settings.optimizeOnImport)
                Text("Only files Doctopus brings in itself are optimized automatically. Files already in your library are yours, and are never rewritten unless you choose Optimize from the context menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quality", scope: .app) {
                LabeledContent("Raster resolution") {
                    HStack {
                        Slider(value: $model.settings.targetDPI, in: 96...300, step: 6)
                        Text("\(Int(model.settings.targetDPI)) dpi").monospacedDigit().frame(width: 62)
                    }
                }
                LabeledContent("JPEG quality") {
                    HStack {
                        Slider(value: $model.settings.jpegQuality, in: 0.3...0.95)
                        Text("\(Int(model.settings.jpegQuality * 100))%").monospacedDigit().frame(width: 40)
                    }
                }
                Text("Only pages with no text layer are ever rasterized, so a searchable PDF never loses its selectable text. If the result is not at least 15% smaller, the original is kept untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.stats.saved > 0 {
                Section("Savings") {
                    LabeledContent("Reclaimed so far", value: ByteFormat.string(model.stats.saved))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Not private, unlike its siblings: the headless checks host this pane on its
/// own to catch the blank-pane failure mode, and a tab cannot be selected from
/// outside a `TabView`.
struct IntelligenceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var availableModels: [String] = []
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Model", scope: .app) {
                Picker("Enrichment", selection: $model.settings.llmBackend) {
                    ForEach(LLMBackend.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: model.settings.llmBackend) { model.refreshModelStatus() }

                if model.settings.llmBackend != .off {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle().fill(model.modelStatus.isReady ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(model.modelStatus.label)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            switch model.settings.llmBackend {
            case .off:
                Section {
                    Text("Doctopus falls back to its built-in heuristics for dates, correspondents, types and titles. Everything else works exactly the same way — you simply get no summaries and no proposed tags.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .onDevice:
                Section {
                    Text("Everything runs locally — no document text leaves this Mac. Requires macOS 26 with Apple Intelligence turned on.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .remote:
                remoteSection
            }

            if model.settings.llmBackend != .off {
                Section {
                    ForEach(InsightField.allCases) { field in
                        Toggle(field.label, isOn: Binding(
                            get: { model.settings.predictedFields.contains(field) },
                            set: { on in
                                if on { model.settings.predictedFields.insert(field) }
                                else { model.settings.predictedFields.remove(field) }
                            }))
                    }
                } header: {
                    ScopedHeader(title: "Suggestions", scope: .app)
                } footer: {
                    Text("Only the checked fields are asked of the model. The others are left to the built-in heuristics, and re-analyzing a document leaves them as they are.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: promptTemplate)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 260)
                    HStack {
                        Text(model.settings.llmPromptTemplate.isEmpty
                             ? "Using the default prompt." : "Using your own prompt.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Default") { model.settings.llmPromptTemplate = "" }
                            .disabled(model.settings.llmPromptTemplate.isEmpty)
                    }
                } header: {
                    ScopedHeader(title: "Prompt", scope: .app)
                } footer: {
                    Text(verbatim: "Text between {{#summary}} and {{/summary}} is only sent when Summary is checked above — likewise correspondent, documentType, language, intent, title and tags. {{#pageImage}}…{{/pageImage}} is only sent with a page image, {{^pageImage}}…{{/pageImage}} only without one. Keep asking for a JSON object with those keys; the document itself follows in a separate message.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if model.settings.predictedFields.contains(.tags) {
                    Section("Tag Suggestions", scope: .library) {
                        LibraryPicker()
                        Text("Proposed tags appear in a document's inspector as suggestions you accept or dismiss individually — they never show up in the sidebar on their own.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Automatically accept suggestions that match an existing tag",
                               isOn: $model.settings.autoAcceptMatchingTagSuggestions)
                    }
                }
            }

            Section("Run it now") {
                Text("New documents are enriched as they are indexed. These re-ask the model about documents that are already in the index — the way to catch up a library indexed before a model was configured, or to try a better one.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Analyze Selected Documents") { model.analyze(model.selectedRows) }
                        .disabled(model.selectedIDs.isEmpty || !model.modelStatus.isReady)
                    Button("Analyze Entire Library…") { confirmLibraryRun() }
                        .disabled(!model.modelStatus.isReady)
                }
                if model.progress.phase == "Analyzing" {
                    HStack(spacing: 8) {
                        ProgressView(value: model.progress.fraction)
                        Text("\(model.progress.done) / \(model.progress.total)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Button("Stop") { model.cancelIndexing() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            model.refreshModelStatus()
            await loadModels()
        }
    }

    /// Stores "" while the text matches the default.
    private var promptTemplate: Binding<String> {
        Binding(get: { model.settings.llmPromptTemplate.nilIfBlank ?? LLMPrompt.defaultTemplate },
                set: { model.settings.llmPromptTemplate = $0 == LLMPrompt.defaultTemplate ? "" : $0 })
    }

    @ViewBuilder
    private var remoteSection: some View {
        @Bindable var model = model
        Section("Endpoint", scope: .app) {
            TextField("Address", text: $model.settings.remoteEndpoint,
                      prompt: Text("http://localhost:1234/v1"))
                .font(.system(.body, design: .monospaced))

            HStack {
                TextField("Model", text: $model.settings.remoteModel,
                          prompt: Text("the model identifier the server reports"))
                    .font(.system(.body, design: .monospaced))
                if !availableModels.isEmpty {
                    Menu {
                        ForEach(availableModels, id: \.self) { name in
                            Button(name) { model.settings.remoteModel = name }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            SecureField("API key", text: $model.settings.remoteAPIKey,
                        prompt: Text("optional — local servers rarely need one"))

            HStack {
                Button(testing ? "Testing…" : "Test Connection") { test() }
                    .disabled(testing)
                Spacer()
                if !availableModels.isEmpty {
                    Text("\(availableModels.count) model\(availableModels.count == 1 ? "" : "s") offered")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        Section("Requests", scope: .app) {
            Picker("Text sent per document", selection: $model.settings.llmExcerptLimit) {
                Text("3,000 characters").tag(3000)
                Text("6,000 characters").tag(6000)
                Text("12,000 characters").tag(12000)
                Text("32,000 characters").tag(32000)
            }
            Picker("Documents at a time", selection: $model.settings.remoteParallelRequests) {
                ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
            }
            LabeledContent("Timeout") {
                HStack {
                    Slider(value: $model.settings.remoteTimeout, in: 15...600, step: 15)
                    Text("\(Int(model.settings.remoteTimeout))s").monospacedDigit().frame(width: 46)
                }
            }
            Text("Works with any OpenAI-compatible server — LM Studio, Ollama, llama.cpp, vLLM, or a hosted API. Unlike the on-device model, this sends the text of your documents to that endpoint, and the API key is stored in Doctopus's own preferences rather than the Keychain — it never travels inside a library folder.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Page Image", scope: .app) {
            Toggle("Send the first page as an image", isOn: $model.settings.remoteVision)
            if model.settings.remoteVision {
                Picker("Longest edge", selection: $model.settings.remoteVisionImageSize) {
                    Text("768 px").tag(768)
                    Text("1,024 px").tag(1024)
                    Text("1,536 px").tag(1536)
                    Text("2,048 px").tag(2048)
                }
                Text("The model is shown the first page as well as the text and the page count, so the letterhead, a logo, a stamp or the layout of a table count towards its answer — which is what a scan loses on the way through OCR. It needs a model that can see, such as Qwen2.5-VL, Gemma 3, LLaVA or a hosted multimodal model; a text model refuses the image, and Doctopus then carries on with text alone for the rest of the session. A larger page reads more small print and costs more tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func test() {
        testing = true
        Task {
            await loadModels()
            model.refreshModelStatus()
            testing = false
        }
    }

    private func loadModels() async {
        guard model.settings.llmBackend == .remote else { return }
        availableModels = await model.intelligence.models(model.settings.remoteConfig)
    }

    private func confirmLibraryRun() {
        let count = model.stats.total
        let alert = NSAlert()
        alert.messageText = "Analyze \(count) document\(count == 1 ? "" : "s")?"
        let sent = model.settings.remoteVision ? "its text and an image of its first page" : "its text"
        alert.informativeText = model.settings.llmBackend == .remote
            ? "Each one sends \(sent) to \(model.settings.remoteEndpoint). Summaries, types, correspondents and titles found by the model will replace what is stored now."
            : "Summaries, types, correspondents and titles found by the model will replace what is stored now."
        alert.addButton(withTitle: "Analyze")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.analyzeLibrary()
    }
}
