import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showInspector = true
    @State private var renameSheet = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 360)
        } detail: {
            Group {
                if model.libraries.isEmpty {
                    WelcomeView()
                } else {
                    // Queue mode is the same browser with review affordances
                    // turned on, so view switching and drag-and-drop work there
                    // exactly as they do everywhere else.
                    DocumentListView()
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
            }
        }
        .navigationTitle("")
        .toolbar { toolbar }
        .searchable(text: $model.searchText, placement: .toolbar,
                    prompt: "Search text, titles, tags…")
        .searchSuggestions { SearchSuggestions() }
        .sheet(isPresented: $renameSheet) { RenameSheet(isPresented: $renameSheet) }
        .onReceive(NotificationCenter.default.publisher(for: .showRenameSheet)) { _ in
            if !model.selectedIDs.isEmpty { renameSheet = true }
        }
        .alert("Doctopus", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Add Folder to Index…") { model.addLibrary() }
                Button("Import Files…") { importFiles() }
                ScanMenu(destination: model.contextImportDirectory)
                Divider()
                Button("New Tag…") {
                    guard let name = TextPrompt.ask(title: "New Tag", message: "",
                                                    initial: "", confirm: "Create") else { return }
                    model.createTag(named: name)
                }
                Divider()
                Button("Rescan All Folders") { model.reindex() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .help("Add documents or folders")
        }

        ToolbarItem(placement: .navigation) {
            if model.progress.isRunning {
                HStack(spacing: 8) {
                    ProgressView(value: model.progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                    Text("\(model.progress.phase) \(model.progress.done)/\(model.progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { model.cancelIndexing() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop indexing")
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ViewModePicker()
            SortMenu()

            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls, into: nil)
    }
}

private struct ViewModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("View", selection: $model.viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.rawValue, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Switch between list and gallery")
    }
}

private struct SortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Sort by", selection: $model.sort) {
                ForEach(SortField.standard, id: \.self) { Text($0.label).tag($0) }
                // The configured columns sort too, so the menu and the list
                // header offer the same choices.
                ForEach(model.fields) { field in
                    Text(field.name).tag(SortField.field(field.key))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Order", selection: $model.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
            if model.viewMode == .gallery {
                Divider()
                Slider(value: $model.settings.galleryThumbnailSize, in: 90...260) {
                    Text("Thumbnail Size")
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
    }
}

private struct SearchSuggestions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.searchText.isEmpty {
            ForEach(["is:review", "is:untagged", "is:optimized", "ext:pdf"], id: \.self) { token in
                Text(token).searchCompletion(token)
            }
        } else if let last = model.searchText.split(separator: " ").last.map(String.init),
                  last.hasSuffix(":") {
            let prefix = model.searchText.dropLast(last.count)
            ForEach(completions(for: last).prefix(12), id: \.self) { value in
                Text(value).searchCompletion("\(prefix)\(last)\(quoted(value))")
            }
        }
    }

    private func completions(for token: String) -> [String] {
        let prefix = String(token.dropLast()).lowercased()
        switch prefix {
        case "tag": return model.tagNames
        case "is": return ["review", "approved", "untagged", "tagged", "pending", "failed", "optimized"]
        case "ext": return ["pdf", "png", "jpg"]
        default:
            let key = SearchQuery.aliases[prefix] ?? prefix
            return (model.facets[key] ?? []).map(\.value)
        }
    }

    private func quoted(_ v: String) -> String { v.contains(" ") ? "\"\(v)\"" : v }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Point Doctopus at a folder")
                .font(.title2.weight(.medium))
            Text("Your documents stay exactly where they are. Doctopus reads them in place, runs OCR, and builds a searchable index — it never moves or renames anything on its own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose Folder…") { model.addLibrary() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
