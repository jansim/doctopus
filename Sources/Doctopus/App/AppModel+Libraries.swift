import Foundation
import AppKit

extension AppModel {

    enum OpenOutcome { case opened, elsewhere, failed }

    /// Opens the library in this window, which has to be empty; one already
    /// showing a library hands the request on to a window of its own.
    @discardableResult
    func openLibrary(container: URL, rootBookmark: Data? = nil,
                     quietly: Bool = false, index: Bool = true) async -> OpenOutcome {
        let workspace = Workspace.shared
        guard isEmpty else {
            workspace.open(container, from: self)
            return .elsewhere
        }
        let silent = workspace.takeQuiet(container) || quietly
        let root = container.deletingLastPathComponent()
        let bookmark = rootBookmark ?? (try? root.bookmarkData(
            includingResourceValuesForKeys: nil, relativeTo: nil))

        isOpening = true
        defer { isOpening = false }
        let store: Store
        do {
            store = try Store(directory: container)
        } catch let error as Store.OpenError {
            errorMessage = error.description
            return .failed
        } catch {
            errorMessage = "Could not open a library at \(root.lastPathComponent)."
            return .failed
        }

        // Identity is the id in `meta.json`, so the same library reached by two
        // different paths — a bookmark and a Finder open, say — is one library,
        // and stays in the one window.
        if let other = workspace.window(showing: store.libraryID) {
            if let bookmark { other.library?.bookmark = bookmark }
            other.bringToFront()
            return .elsewhere
        }
        guard workspace.opening.insert(store.libraryID).inserted else { return .elsewhere }
        defer { workspace.opening.remove(store.libraryID) }

        let lib = Library(store: store, bookmark: bookmark)
        lib.settings = await AppSettings.load(from: store)
        lib.attachIndexer(
            intelligence: intelligence,
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onDataChanged: { [weak self] in Task { @MainActor in self?.refreshAll() } })

        if (try? await store.rules())?.isEmpty ?? true {
            for rule in Rule.starters { _ = try? await store.upsertRule(rule) }
        }

        library = lib
        Preferences.noteRecentLibrary(lib.container)
        startWatching(lib)
        adoptSettings(of: lib)
        viewMode = settings.viewMode
        await intelligence.update(settings: settings)
        modelStatus = await intelligence.status()

        refreshAll()
        workspace.persistOpenLibraries()
        guard index else { return .opened }
        let indexed = await lib.indexer.indexAll()
        if !silent, let indexed {
            notify(indexed == 0 ? "Opened \(lib.displayName)."
                                : "Indexed \(indexed) document\(indexed == 1 ? "" : "s") in \(lib.displayName).")
        }
        return .opened
    }

    func bringToFront() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func addLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder to index in place. Doctopus keeps its index in “\(Preferences.libraryFolderName)” inside it — nothing else is moved or renamed."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        openLibrary(at: folder)
    }

    func openLibraryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.doctopusLibrary]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Library"
        panel.message = "Choose a “\(Preferences.libraryFolderName)” library, or a folder that contains one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLibrary(at: url)
    }

    /// Here if this window is still empty, in a window of its own if not.
    func openLibrary(at url: URL) {
        Workspace.shared.open(Workspace.container(for: url), from: self)
    }

    func createFolder(named name: String, in parent: URL) {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            refreshAll()
            selection = .folder(url.path)
        } catch {
            errorMessage = "Could not create “\(name)”: \(error.localizedDescription)"
        }
    }

    /// The index moves first, so the watcher never sees the new folder while
    /// its documents are still recorded under the old one.
    func renameFolder(_ path: String, to name: String) {
        guard let lib = library, lib.owns(path: path) else { return }
        let source = URL(fileURLWithPath: path)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true).path
        Task {
            do {
                try await lib.store.moveFolder(from: path, to: destination)
                do {
                    try FileManager.default.moveItem(atPath: path, toPath: destination)
                } catch {
                    try? await lib.store.moveFolder(from: destination, to: path)
                    throw error
                }
            } catch {
                errorMessage = "Could not rename “\(source.lastPathComponent)”: \(error.localizedDescription)"
                return
            }
            if case .folder(let selected) = selection, selected == path || selected.hasPrefix(path + "/") {
                selection = .folder(destination + selected.dropFirst(path.count))
            }
            refreshAll()
        }
    }

    /// The window goes with its library, unless it is the last one, which
    /// stays at the welcome screen rather than quitting the app.
    func closeLibrary() {
        guard let lib = library else { return }
        stopLibrary(lib)
        library = nil
        selection = .all
        selectedIDs = []
        searchText = ""
        documents = []
        detail = nil
        hasMoreDocuments = false
        adoptSettings(of: nil)
        let workspace = Workspace.shared
        workspace.persistOpenLibraries()
        if workspace.windows.count > 1 { window?.close() }
    }

    /// Closing the last window quits the app, and whatever it showed should
    /// be open again next time, so only a window closed among others is
    /// dropped from the list.
    func windowClosed() {
        let workspace = Workspace.shared
        let last = workspace.windows.count <= 1
        if let lib = library { stopLibrary(lib) }
        workspace.unregister(self)
        if !last { workspace.persistOpenLibraries() }
    }

    private func stopLibrary(_ lib: Library) {
        if scanSession != nil { stopContinuousScan() }
        lib.watcher?.stop()
        lib.watcher = nil
        Task { await lib.indexer.cancel() }
    }

    private func startWatching(_ lib: Library) {
        lib.watcher?.stop()
        guard let indexer = lib.indexer else { return }
        let watcher = FileWatcher { changed in
            Task { await indexer.handleChanges(paths: changed) }
        }
        watcher.start(paths: [lib.root.path])
        lib.watcher = watcher
    }

    func reindex() {
        guard let lib = library else { return }
        Task {
            guard let changed = await lib.indexer.indexAll() else { return }
            if changed == 0 { notify("\(lib.displayName) is up to date.", .info) }
            else { notify("Indexed \(changed) new or changed document\(changed == 1 ? "" : "s") in \(lib.displayName).") }
        }
    }
    func cancelIndexing() {
        guard let lib = library else { return }
        Task { await lib.indexer.cancel() }
    }

    /// Where the event log stands before a file change, so Edit › Undo can
    /// take back that change alone and not whatever was filed since.
    func eventMark() async -> Int64 {
        guard let lib = library else { return 0 }
        return (try? await lib.store.latestEventID()) ?? 0
    }

    func offerUndo(_ name: String, of rows: [DocumentRow], since mark: Int64,
                   restoring trashed: [DocumentRow] = []) {
        guard let undoManager, let lib = library, !rows.isEmpty || !trashed.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if !trashed.isEmpty { model.restore(trashed) }
                Task {
                    if !rows.isEmpty { await lib.indexer.undo(rows.map(\.doc), since: mark) }
                    model.refreshAll()
                }
            }
        }
        undoManager.setActionName(name)
    }

    func verifyLibrary() {
        guard let lib = library else { return }
        Task {
            do {
                let report = try await LibraryVerifier.verify(store: lib.store)
                if report.isClean {
                    notify("Library “\(lib.displayName)” is healthy with 0 errors.", .success)
                } else {
                    notify("Library verification found \(report.errorsCount) error(s) and \(report.warningsCount) warning(s).", .warning)
                }
            } catch {
                errorMessage = "Could not verify library: \(error.localizedDescription)"
            }
        }
    }
}
