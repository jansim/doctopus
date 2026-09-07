import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RoutingSettings().tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
            OptimizationSettings().tabItem { Label("Optimization", systemImage: "arrow.down.circle") }
            IntelligenceSettings().tabItem { Label("Intelligence", systemImage: "sparkles") }
        }
        .frame(width: 560, height: 430)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Indexed Folders") {
                if model.roots.isEmpty {
                    Text("No folders indexed yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.roots) { root in
                        HStack {
                            Text(shorten(root.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove", role: .destructive) { model.removeRoot(root) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Folder…") { model.addRoot() }
            }

            Section("Naming") {
                TextField("Default rename template", text: $model.settings.namingTemplate)
                    .font(.system(.body, design: .monospaced))
                Text("Tokens: {date} {year} {month} {day} {correspondent} {title} {type} {lang} {n} {original}. Add a format like {date:yyyy-MM} for custom dates.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Scanning") {
                TextField("Scan destination folder", text: $model.settings.scanDestination)
                Text("Relative to the first indexed folder. Right-clicking a folder in the sidebar always overrides this.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Indexing") {
                Picker("OCR concurrency", selection: $model.settings.ocrConcurrency) {
                    Text("Automatic (\(model.settings.effectiveConcurrency))").tag(0)
                    ForEach([1, 2, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Mirror all tags to disk as Finder aliases", isOn: $model.settings.mirrorTagsAsAliases)
                Text("Aliases live in a Tags folder inside the indexed root. Individual tags can override this from the sidebar.")
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

private struct RoutingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [Rule] = []
    @State private var selected: Rule.ID?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Auto-route imports and scans", isOn: $model.settings.autoRouteImports)
                    Toggle("Derive a folder when no rule matches", isOn: $model.settings.deriveWhenNoRule)
                        .disabled(!model.settings.autoRouteImports)
                    TextField("Derived path template", text: $model.settings.derivedTemplate)
                        .font(.system(.body, design: .monospaced))
                        .disabled(!model.settings.deriveWhenNoRule)
                    LabeledContent("Confidence threshold") {
                        HStack {
                            Slider(value: $model.settings.routingThreshold, in: 0.4...0.99)
                            Text("\(Int(model.settings.routingThreshold * 100))%")
                                .monospacedDigit().frame(width: 40)
                        }
                    }
                    Text("Below the threshold a file stays where it landed and shows up in Recent Processing as Needs Review. Files already in your library are never moved automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Auto-Routing")
                }
            }
            .formStyle(.grouped)

            Divider()

            Table(rules, selection: $selected) {
                TableColumn("Rule") { r in Text(r.name) }
                TableColumn("Matches") { r in Text(r.pattern).font(.caption.monospaced()).lineLimit(1) }
                TableColumn("Destination") { r in Text(r.destination).font(.caption.monospaced()).lineLimit(1) }
                TableColumn("On") { r in
                    Toggle("", isOn: Binding(get: { r.enabled }, set: { toggle(r, $0) })).labelsHidden()
                }
                .width(30)
            }
            .frame(minHeight: 130)

            HStack {
                Button { addRule() } label: { Image(systemName: "plus") }
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                Spacer()
                Text("Rules are evaluated top to bottom; the first match wins.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .task { await load() }
    }

    private func load() async {
        rules = (try? await model.store.rules()) ?? []
    }

    private func toggle(_ rule: Rule, _ on: Bool) {
        var r = rule
        r.enabled = on
        Task { _ = try? await model.store.upsertRule(r); await load() }
    }

    private func addRule() {
        let r = Rule(id: 0, name: "New Rule", pattern: "keyword", field: "text",
                     destination: "Unsorted/{year}", tagNames: nil, weight: 0.85,
                     enabled: false, priority: 0)
        Task { _ = try? await model.store.upsertRule(r); await load() }
    }

    private func removeSelected() {
        guard let id = selected else { return }
        Task { try? await model.store.deleteRule(id); await load() }
    }
}

private struct OptimizationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("When to Optimize") {
                Toggle("Optimize imports and scans", isOn: $model.settings.optimizeOnImport)
                Toggle("Optimize existing files while indexing", isOn: $model.settings.optimizeExisting)
                Text("Off by default: existing files are yours, and Doctopus does not rewrite them unless you say so. You can always run Optimize from the context menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quality") {
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

private struct IntelligenceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Apple On-Device Model") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(model.modelStatus.isReady ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(model.modelStatus.label)
                    }
                }
                Toggle("Use the on-device model for summaries and metadata",
                       isOn: $model.settings.useOnDeviceModel)
                    .disabled(!model.modelStatus.isReady)
                Text("Everything runs locally — no document text ever leaves this Mac. When the model is unavailable, Doctopus falls back to its built-in heuristics and keeps working exactly the same way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What it extracts") {
                Label("A one or two sentence summary", systemImage: "text.alignleft")
                Label("Correspondent, category, language and intent", systemImage: "person.text.rectangle")
                Label("Proposed tags and a canonical title", systemImage: "tag")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}
