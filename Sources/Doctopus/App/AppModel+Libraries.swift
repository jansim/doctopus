import Foundation
import AppKit

extension AppModel {

    func existingContainer(in folder: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
            .first { $0.lastPathComponent.hasSuffix(".doctopus") }
    }

    func openLibrary(container: URL, rootBookmark: Data? = nil,
                             persist: Bool = true, index: Bool = true) async {
        let root = container.deletingLastPathComponent()
        let bookmark = rootBookmark ?? (try? root.bookmarkData(
            includingResourceValuesForKeys: nil, relativeTo: nil))

        let store: Store
        do {
            store = try Store(directory: container)
        } catch let error as Store.OpenError {
            errorMessage = error.description
            return
        } catch {
            errorMessage = "Could not open a library at \(root.lastPathComponent)."
            return
        }

        // Identity is the id in `meta.json`, so the same library reached by two
        // different paths — a bookmark and a Finder open, say — is one library.
        if let already = library(store.libraryID) {
            if let bookmark { already.bookmark = bookmark }
            if persist { persistOpenLibraries() }
            return
        }
        guard opening.insert(store.libraryID).inserted else { return }
        defer { opening.remove(store.libraryID) }

        let lib = Library(store: store, bookmark: bookmark)
        lib.settings = await AppSettings.load(from: store)
        lib.attachIndexer(
            intelligence: intelligence,
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onDataChanged: { [weak self] in Task { @MainActor in self?.refreshAll() } })

        if (try? await store.rules())?.isEmpty ?? true {
            for rule in Rule.starters { _ = try? await store.upsertRule(rule) }
        }

        libraries.append(lib)
        if persist { Preferences.noteRecentLibrary(lib.container) }
        startWatching(lib)

        if libraries.count == 1 {
            adoptSettings(of: lib)
            viewMode = settings.viewMode
            await intelligence.update(settings: settings)
            modelStatus = await intelligence.status()
        }

        refreshAll()
        if persist { persistOpenLibraries() }
        guard index else { return }
        let indexed = await lib.indexer.indexAll()
        if persist, let indexed {
            notify(indexed == 0 ? "Opened \(lib.displayName)."
                                : "Indexed \(indexed) document\(indexed == 1 ? "" : "s") in \(lib.displayName).")
        }
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

    func openLibrary(at url: URL) {
        let container: URL
        if url.lastPathComponent.hasSuffix(".doctopus") {
            container = url
        } else if let existing = existingContainer(in: url) {
            container = existing
        } else {
            container = url.appendingPathComponent(Preferences.libraryFolderName, isDirectory: true)
        }
        Task { await openLibrary(container: container) }
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
        guard let lib = libraries.first(where: { $0.owns(path: path) }) else { return }
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

    func closeLibrary(_ lib: Library) {
        lib.watcher?.stop()
        libraries.removeAll { $0 === lib }
        if settingsLibraryID == lib.id { settingsLibraryID = nil }
        if selectionBelongs(to: lib) { selection = .all }
        selectedIDs = selectedIDs.filter { $0.library != lib.id }
        persistOpenLibraries()
        adoptSettings(of: settingsLibrary)
        refreshAll()
    }

    private func selectionBelongs(to lib: Library) -> Bool {
        switch selection {
        case .tag(let ref): return ref.library == lib.id
        case .folder(let path): return lib.owns(path: path)
        default: return false
        }
    }

    func persistOpenLibraries() {
        guard !restoring else { return }
        Preferences.libraryBookmarks = libraries.compactMap(\.bookmark)
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

    func reindex(_ lib: Library? = nil) {
        let targets = lib.map { [$0] } ?? libraries
        Task {
            var changed = 0
            var ran = false
            for lib in targets {
                guard let n = await lib.indexer.indexAll() else { continue }
                changed += n
                ran = true
            }
            guard ran else { return }
            let scope = targets.count == 1 ? targets[0].displayName : "\(targets.count) libraries"
            if changed == 0 { notify("\(scope) is up to date.", .info) }
            else { notify("Indexed \(changed) new or changed document\(changed == 1 ? "" : "s") in \(scope).") }
        }
    }
    func cancelIndexing() { Task { for lib in libraries { await lib.indexer.cancel() } } }

    /// Where each library's event log stands before a file change, so Edit ›
    /// Undo can take back that change alone and not whatever was filed since.
    func eventMarks(_ rows: [DocumentRow]) async -> [LibraryID: Int64] {
        var marks: [LibraryID: Int64] = [:]
        for (lib, _) in grouped(rows) { marks[lib.id] = (try? await lib.store.latestEventID()) ?? 0 }
        return marks
    }

    func offerUndo(_ name: String, of rows: [DocumentRow], since marks: [LibraryID: Int64],
                   restoring trashed: [DocumentRow] = []) {
        guard let undoManager, !rows.isEmpty || !trashed.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if !trashed.isEmpty { model.restore(trashed) }
                Task {
                    for (lib, rows) in model.grouped(rows) {
                        await lib.indexer.undo(rows.map(\.doc), since: marks[lib.id] ?? .max)
                    }
                    model.refreshAll()
                }
            }
        }
        undoManager.setActionName(name)
    }

    func verifyLibrary() {
        guard let lib = activeLibrary else { return }
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
