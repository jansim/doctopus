import Foundation
import AppKit

extension AppModel {

    enum OpenOutcome { case opened, elsewhere, failed }

    /// Opens the library in this window, which has to be empty; one already
    /// showing a library hands the request on to a window of its own.
    @discardableResult
    func openLibrary(container: URL, rootBookmark: Data? = nil,
                     quietly: Bool = false) async -> OpenOutcome {
        let workspace = Workspace.shared
        guard !isClosed else { return .failed }
        guard isEmpty else {
            workspace.open(container, from: self)
            return .elsewhere
        }
        let silent = quietly || workspace.isReopening(container)
        defer { workspace.doneReopening(container) }
        let root = container.deletingLastPathComponent()
        let bookmark = rootBookmark ?? (try? root.bookmarkData(
            includingResourceValuesForKeys: nil, relativeTo: nil))

        isOpening = true
        defer { isOpening = false }
        // Before the lock is tried: this window's own lock would refuse it.
        if let other = workspace.window(holdingLockIn: container) {
            other.bringToFront()
            return .elsewhere
        }
        let store: Store
        do {
            store = try Store(directory: container, lock: LibraryLock.acquire(in: container))
        } catch let error as LibraryLock.Refusal {
            errorMessage = error.description
            return .failed
        } catch let error as Store.OpenError {
            errorMessage = error.description
            return .failed
        } catch {
            // An index that will not open at all cannot be restored through
            // View › Restore Index, so the newest backup is offered here.
            guard Store.isDamage(error), let backup = Store.backups(in: container).first,
                  confirmRestoreUnopenable(root.lastPathComponent, backup, error) else {
                errorMessage = "Could not open a library at \(root.lastPathComponent): \(error.localizedDescription)"
                return .failed
            }
            do {
                try Store.replaceUnopenableIndex(in: container, with: backup)
                store = try Store(directory: container, lock: LibraryLock.acquire(in: container))
            } catch {
                errorMessage = "Could not restore the index of \(root.lastPathComponent): \(error.localizedDescription)"
                return .failed
            }
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
        let loaded = await AppSettings.load(from: store)
        lib.settings = loaded.settings
        if let problem = loaded.problem { errorMessage = problem }
        lib.attachIndexer(
            intelligence: intelligence,
            onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } },
            onDataChanged: { [weak self] in Task { @MainActor in self?.refreshAll() } },
            onProblem: { [weak self] text in Task { @MainActor in self?.errorMessage = text } })

        if (try? await store.rules())?.isEmpty ?? true {
            for rule in Rule.starters { _ = try? await store.upsertRule(rule) }
        }
        // Closed while the library was on its way in: nothing is left to show it.
        guard !isClosed else { return .failed }

        library = lib
        Preferences.noteRecentLibrary(lib.container)
        startWatching(lib)
        startBackups(lib)
        adoptSettings(of: lib)
        viewMode = settings.viewMode
        await intelligence.update(settings: settings)
        modelStatus = await intelligence.status()

        refreshAll()
        workspace.persistOpenLibraries()
        let indexed = await lib.indexer.indexAll()
        if !silent, let indexed {
            notify(indexed == 0 ? "Opened \(lib.displayName)."
                                : "Indexed \(indexed) document\(indexed == 1 ? "" : "s") in \(lib.displayName).")
        }
        // Last, so no routine notice replaces it.
        if !silent, let service = SyncedFolder.service(for: lib.root) {
            notify(SyncedFolder.warning(for: lib.displayName, in: service), .warning)
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
    /// its documents are still recorded under the old one. Rules filing into
    /// the folder by name are then offered to `confirmRules`, and follow it
    /// only if that says so.
    func renameFolder(_ path: String, to name: String,
                      confirmRules: @escaping @MainActor ([Rule]) -> Bool = { _ in false }) {
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
            await refileRules(from: path, to: destination, in: lib, confirm: confirmRules)
        }
    }

    private func refileRules(from path: String, to destination: String, in lib: Library,
                             confirm: @MainActor ([Rule]) -> Bool) async {
        let rules = (try? await lib.store.rules()) ?? []
        let refiled = rules.compactMap {
            $0.refiling(Store.canonical(path), to: Store.canonical(destination), root: lib.store.root.path)
        }
        guard !refiled.isEmpty, confirm(refiled) else { return }
        do {
            for rule in refiled { _ = try await lib.store.upsertRule(rule) }
        } catch {
            report(error, "update the rules filing into “\(URL(fileURLWithPath: destination).lastPathComponent)”")
        }
        rulesChanged()
        notify(refiled.count == 1 ? "Updated rule “\(refiled[0].name)”" : "Updated \(refiled.count) rules")
    }

    /// The window goes with its library, unless it is the last one, which
    /// stays at the welcome screen rather than quitting the app.
    func closeLibrary() {
        guard let lib = library else { return }
        detachLibrary(lib)
        let workspace = Workspace.shared
        workspace.persistOpenLibraries()
        if workspace.windows.count > 1 { window?.close() }
    }

    /// Empties the window without closing it.
    private func detachLibrary(_ lib: Library) {
        stopLibrary(lib)
        library = nil
        selection = .all
        selectedIDs = []
        searchText = ""
        documents = []
        detail = nil
        hasMoreDocuments = false
        adoptSettings(of: nil)
    }

    /// The library's folder was moved, renamed or deleted while open, or its
    /// volume went away. Every path the index hands out is now wrong, so the
    /// library is reopened wherever its bookmark finds it, or closed.
    func libraryFolderChanged(_ lib: Library) async {
        guard library === lib else { return }
        let fm = FileManager.default
        // Renamed away and back before anyone looked: nothing to do.
        if fm.fileExists(atPath: lib.container.path) { return }

        var stale = false
        let found = lib.bookmark.flatMap {
            try? URL(resolvingBookmarkData: $0, options: [.withoutUI], bookmarkDataIsStale: &stale)
        }
        let name = lib.displayName
        detachLibrary(lib)
        if let found, !found.path.contains("/.Trash/"),
           fm.fileExists(atPath: found.appendingPathComponent("library.doctopus").path) {
            let outcome = await openLibrary(container: found.appendingPathComponent("library.doctopus"),
                                            quietly: true)
            if outcome == .opened {
                notify("\(name) moved to \(found.path); it was reopened there.", .info)
                return
            }
        }
        errorMessage = "The folder of \(name) was moved, renamed, deleted or disconnected, "
            + "so the library was closed. Nothing in it was changed. Open it again from wherever it is now."
        Workspace.shared.persistOpenLibraries()
    }

    /// Closing the last window quits the app, and whatever it showed should
    /// be open again next time, so only a window closed among others is
    /// dropped from the list.
    func windowClosed() {
        let workspace = Workspace.shared
        let last = workspace.windows.count <= 1
        isClosed = true
        if let lib = library { stopLibrary(lib) }
        workspace.unregister(self)
        if !last { workspace.persistOpenLibraries() }
    }

    private func stopLibrary(_ lib: Library) {
        if scanSession != nil { stopContinuousScan() }
        lib.watcher?.stop()
        lib.watcher = nil
        lib.backups?.cancel()
        lib.backups = nil
        // Now, not when the last task lets go of the store: the library may be
        // reopening in this very window.
        lib.store.lock?.release()
        Task { await lib.indexer.cancel() }
    }

    private func startWatching(_ lib: Library) {
        lib.watcher?.stop()
        guard let indexer = lib.indexer else { return }
        let watcher = FileWatcher(
            onChange: { changes in
                Task { await indexer.handleChanges(paths: changes.paths, rescanning: changes.rescan) }
            },
            onRootChanged: { [weak self, weak lib] in
                Task { @MainActor in
                    guard let self, let lib else { return }
                    await self.libraryFolderChanged(lib)
                }
            })
        watcher.start(paths: [lib.root.path])
        lib.watcher = watcher
    }

    /// Snapshots the index once a day while the library is open. The first
    /// look waits for the opening scan, so it catches what that scan found.
    private func startBackups(_ lib: Library) {
        lib.backups?.cancel()
        lib.backups = Task { [weak self, weak lib] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let lib else { return }
                let outcome: Store.BackupOutcome
                do { outcome = try await lib.store.backUpIfDue() }
                catch {
                    self?.errorMessage = "Could not back up the index of \(lib.displayName): \(error.localizedDescription)"
                    return
                }
                if case .damaged(let problem) = outcome, !lib.damageReported {
                    lib.damageReported = true
                    self?.errorMessage = "The index of \(lib.displayName) failed SQLite’s integrity check (\(problem)). "
                        + "No backup was taken, so the last good ones are kept: View › Restore Index puts one back."
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Puts the index back as it was in `backup`, keeping the current one
    /// among the backups, and reopens the library so every pane reads it.
    func restoreIndex(from backup: Store.Backup, confirm: @MainActor (String) -> Bool = AppModel.confirmRestore) {
        guard let lib = library else { return }
        let when = backup.date.formatted(date: .abbreviated, time: .shortened)
        guard confirm("Restore the index of \(lib.displayName) from \(when)?") else { return }
        lib.watcher?.stop()
        lib.backups?.cancel()
        Task {
            await lib.indexer.cancel()
            do {
                try await lib.store.restore(from: backup)
            } catch {
                report(error, "restore the index of \(lib.displayName)")
                startWatching(lib)
                startBackups(lib)
                return
            }
            let container = lib.container
            detachLibrary(lib)
            if await openLibrary(container: container, quietly: true) == .opened {
                notify("Restored the index of \(lib.displayName) from \(when). The one it replaced is kept among the backups.")
            }
        }
    }

    private func confirmRestoreUnopenable(_ name: String, _ backup: Store.Backup, _ error: Error) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The index of \(name) could not be opened."
        alert.informativeText = "\(error.localizedDescription)\n\nIt can be restored from the backup of "
            + backup.date.formatted(date: .abbreviated, time: .shortened)
            + ". Tags, fields, notes and reviews go back to how they were then; no document is moved or changed. "
            + "The damaged index is kept in the library’s backups folder."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmRestore(_ question: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "Tags, fields, notes, reviews and history go back to how they were then. "
            + "No document is moved or changed; files added since are picked up again by the scan. "
            + "The index as it is now is kept among the backups."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
        offerUndo(name, docs: rows.map(\.doc), since: mark, restoring: trashed)
    }

    func offerUndo(_ name: String, docs: [Int64], since mark: Int64,
                   restoring trashed: [DocumentRow] = []) {
        guard let undoManager, let lib = library, !docs.isEmpty || !trashed.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if !trashed.isEmpty { model.restore(trashed) }
                Task {
                    if !docs.isEmpty { await lib.indexer.undo(docs, since: mark) }
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
