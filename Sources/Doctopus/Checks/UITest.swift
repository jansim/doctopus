import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing
import QuickLookUI

/// Headless checks for UI that only breaks on screen: hit testing and thumbnail
/// rendering. `Doctopus --uitest <library> [snapshot dir]`
@MainActor
enum UITest {
    static func run(root: String, snapshots: String?) {
        let app = NSApplication.shared
        // `NSTableView` ignores a synthetic click unless the process is frontmost, so
        // the list checks take focus and hand it straight back.
        app.setActivationPolicy(.accessory)
        previousApp = NSWorkspace.shared.frontmostApplication
        let library = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL

        Task { @MainActor in
            // Work on a throwaway copy so the checked-in fixture is never
            // written to, and keep persisted UI state out of real preferences.
            let suite = "doctopus-uitest-\(UUID().uuidString)"
            Preferences.defaults = UserDefaults(suiteName: suite) ?? .standard
            defer { UserDefaults().removePersistentDomain(forName: suite) }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("doctopus-uitest-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.copyItem(at: library, to: root)
            let container = root.appendingPathComponent("library.doctopus", isDirectory: true)

            let model = AppModel(openingLibraryAt: container)
            await model.bootstrap()
            guard await settle({ !model.documents.isEmpty }) else {
                print("  ✗ indexed the library"); exit(1)
            }
            print("CHECKS")
            print("  ✓ indexed the library  (\(model.documents.count) documents)")

            await clickSelectsARow(model, snapshots: snapshots)
            await clickSelectsAGalleryThumbnail(model, snapshots: snapshots)
            galleryModifierClicks(model)
            dragCountsTheSelection(model)
            folderPickerResolvesPaths(model)
            await headerClickSorts(model, snapshots: snapshots)
            await rowThumbnailIsAPage(model)
            await inspectorDraws(model, snapshots: snapshots)
            await intelligencePaneDraws(model, snapshots: snapshots)
            await ruleEditorDraws(model, snapshots: snapshots)
            await rulesPaneDraws(model, snapshots: snapshots)
            await finishedActionsAreToasts(model, snapshots: snapshots)
            await uiStatePersists(model)
            await sidebarShowsBothTagSystems(model, snapshots: snapshots)
            await handEditsReachTheHistory(model)
            await optionRevealsFolders(model)
            await secondLibraryMerges(model, alongside: library, snapshots: snapshots)
            await reviewPanelFiles(model, snapshots: snapshots)
            await droppingAFolderImportsIt(model)
            await draggingOntoAFolderFilesOrMoves(model)
            Check.finish("ui checks")
        }
        app.run()
    }

    private static var previousApp: NSRunningApplication?

    private static func yieldFocus() {
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    private static func clickSelectsARow(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/list.png") }

        model.selectedIDs = []
        let selected = await click(window, at: NSPoint(x: 140, y: size.height - 43),
                                   activating: true) {
            !model.selectedIDs.isEmpty
        }
        Check.that("clicking a document's name selects it", selected,
                   model.documents.filter { model.selectedIDs.contains($0.id) }
                       .map(\.filename).joined(separator: ", "))

        model.selectedIDs = []
        let viaThumbnail = await click(window, at: NSPoint(x: 22, y: size.height - 43),
                                       activating: true) {
            !model.selectedIDs.isEmpty
        }
        Check.that("clicking a row's thumbnail selects it too", viaThumbnail)
        yieldFocus()
    }

    private static func clickSelectsAGalleryThumbnail(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        model.viewMode = .gallery
        defer { model.viewMode = .list }
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/gallery.png") }

        let cell = CGFloat(model.settings.galleryThumbnailSize)
        let middle = NSPoint(x: 18 + cell / 2, y: size.height - (18 + cell * 0.65))
        for (where_, point) in [("middle", middle),
                                ("corner", NSPoint(x: 22, y: size.height - 24))] {
            model.selectedIDs = []
            let selected = await click(window, at: point, attempts: 1, settling: 0.6) {
                !model.selectedIDs.isEmpty
            }
            Check.that("clicking the \(where_) of a gallery thumbnail selects it", selected)
        }

        model.selectedIDs = []
        let start = Date()
        post(window, at: middle)
        let landed = await settle({ !model.selectedIDs.isEmpty }, timeout: 2, every: .milliseconds(5))
        let elapsed = Date().timeIntervalSince(start)
        Check.that("a gallery click selects without waiting out the double-click interval",
                   landed && elapsed < NSEvent.doubleClickInterval * 0.6,
                   "\(Int(elapsed * 1000)) ms, interval \(Int(NSEvent.doubleClickInterval * 1000)) ms")

        model.selectedIDs = []
        let handedOver = URLRecorder()
        AppModel.opener = { handedOver.urls.append($0) }
        defer { AppModel.opener = AppModel.defaultOpener }
        post(window, at: middle)
        post(window, at: middle, clickCount: 2)
        let opened = await settle({ !handedOver.urls.isEmpty }, timeout: 3)
        Check.that("double-clicking a gallery thumbnail opens it in its default app",
                   opened, "\(model.selectedIDs.count) selected")
        Check.that("and does not open Quick Look instead", !QuickLookController.shared.isOpen)
        if QuickLookController.shared.isOpen { QLPreviewPanel.shared().orderOut(nil) }
        model.selectedIDs = []
    }

    /// Asks `GallerySelection` rather than the hosted grid because the branch
    /// turns on `NSEvent.modifierFlags`, which reads the keyboard and not the
    /// event — a posted click cannot hold ⇧ down.
    private static func galleryModifierClicks(_ model: AppModel) {
        let order = model.documents.map(\.id)
        guard order.count >= 4 else {
            Check.that("enough documents to select a run of", false, "\(order.count) documents")
            return
        }

        let plain = GallerySelection.click(order[1], in: order, modifiers: [],
                                           selection: [order[3]], anchor: order[3])
        Check.that("a plain click selects only what was clicked",
                   plain == .init(selection: [order[1]], anchor: order[1]))

        let forwards = GallerySelection.click(order[3], in: order, modifiers: .shift,
                                              selection: plain.selection, anchor: plain.anchor)
        Check.that("⇧ extends the selection from the anchor to the click",
                   forwards.selection == Set(order[1...3]), "\(forwards.selection.count) selected")
        Check.that("and a ⇧ click leaves the anchor where it was", forwards.anchor == order[1])

        let backwards = GallerySelection.click(order[0], in: order, modifiers: .shift,
                                               selection: forwards.selection, anchor: forwards.anchor)
        Check.that("a following ⇧ click extends from that same anchor",
                   backwards == .init(selection: Set(order[0...1]), anchor: order[1]),
                   "\(backwards.selection.count) selected")

        let added = GallerySelection.click(order[3], in: order, modifiers: [.shift, .command],
                                           selection: [order[0]], anchor: order[2])
        Check.that("⌘⇧ adds the run to what was already selected",
                   added.selection == Set([order[0], order[2], order[3]]),
                   "\(added.selection.count) selected")

        let picked = GallerySelection.click(order[2], in: order, modifiers: .command,
                                            selection: [order[0]], anchor: order[0])
        Check.that("⌘ adds a cell and moves the anchor to it",
                   picked == .init(selection: [order[0], order[2]], anchor: order[2]))
        let dropped = GallerySelection.click(order[2], in: order, modifiers: .command,
                                             selection: picked.selection, anchor: picked.anchor)
        Check.that("and ⌘ on a selected cell takes it back out",
                   dropped.selection == [order[0]])

        let unanchored = GallerySelection.click(order[2], in: order, modifiers: .shift,
                                                selection: [], anchor: nil)
        Check.that("⇧ before anything has been clicked selects the one cell",
                   unanchored == .init(selection: [order[2]], anchor: order[2]))
        let stale = GallerySelection.click(order[2], in: order, modifiers: .shift, selection: [],
                                           anchor: DocumentRef(library: "gone", doc: -1))
        Check.that("⇧ with an anchor no longer in the pane selects the one cell",
                   stale == .init(selection: [order[2]], anchor: order[2]))
    }

    private static func dragCountsTheSelection(_ model: AppModel) {
        let rows = model.documents
        guard rows.count >= 3 else {
            Check.that("enough documents to drag a selection of", false, "\(rows.count) documents")
            return
        }
        let saved = model.selectedIDs
        defer { model.selectedIDs = saved }

        model.selectedIDs = [rows[0].id, rows[1].id]
        let promised = model.dragCount(from: rows[0])
        let dropped = model.rows(forDropped: [DocumentDragItem(rows[0])]).count
        Check.that("dragging a selected document counts the whole selection",
                   promised == 2 && dropped == promised, "badge \(promised), drop \(dropped)")
        let outside = model.dragCount(from: rows[2])
        Check.that("dragging a document outside the selection counts just that one",
                   outside == 1 && model.rows(forDropped: [DocumentDragItem(rows[2])]).count == 1,
                   "badge \(outside)")
    }

    private static func folderPickerResolvesPaths(_ model: AppModel) {
        guard let library = model.libraries.first else {
            Check.that("a library to resolve chosen folders against", false)
            return
        }
        let root = library.root
        func relative(_ url: URL) -> String? { FolderPicker.relativePath(for: url, in: library) }

        Check.that("the library root itself is the empty path", relative(root) == "",
                   relative(root).map { "\"\($0)\"" } ?? "refused")
        let statements = root.appendingPathComponent("Finances", isDirectory: true)
            .appendingPathComponent("Statements", isDirectory: true)
        Check.that("a folder inside the library comes back relative to the root",
                   relative(statements) == "Finances/Statements", relative(statements) ?? "refused")

        let roundabout = root.appendingPathComponent("Finances", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("Personal", isDirectory: true)
        Check.that("a path that doubles back is resolved before it is made relative",
                   relative(roundabout) == "Personal", relative(roundabout) ?? "refused")

        Check.that("a folder outside the library is refused",
                   relative(root.deletingLastPathComponent()) == nil)
        Check.that("a sibling folder whose name merely starts with the root's is refused",
                   relative(URL(fileURLWithPath: root.path + "-elsewhere", isDirectory: true)) == nil)

        let container = root.appendingPathComponent("library.doctopus", isDirectory: true)
        Check.that("the library's own container is refused", relative(container) == nil)
        Check.that("and so is a folder inside it",
                   relative(container.appendingPathComponent("thumbnails", isDirectory: true)) == nil)

        if root.path.hasPrefix("/private/var/") {
            let throughSymlink = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)),
                                     isDirectory: true)
                .appendingPathComponent("Work", isDirectory: true)
            Check.that("a folder reached through the /var symlink is still owned",
                       relative(throughSymlink) == "Work", relative(throughSymlink) ?? "refused")
        }
    }

    private static func headerClickSorts(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))

        let header = NSPoint(x: size.width - 40, y: size.height - 14)
        let sorted = await click(window, at: header, activating: true) { model.sort == .size }
        Check.that("clicking a column header sorts by it", sorted, "sort is \(model.sort.label)")

        let wasAscending = model.sortAscending
        let flipped = await click(window, at: header, activating: true) {
            model.sortAscending != wasAscending
        }
        Check.that("clicking it again reverses the direction", flipped)
        if let dir = snapshots {
            try? await Task.sleep(for: .seconds(1))
            snapshot(host, to: dir + "/list-sorted.png")
        }
        yieldFocus()
    }

    private static func rowThumbnailIsAPage(_ model: AppModel) async {
        guard let row = model.documents.first(where: { $0.ext == "pdf" }) else {
            Check.that("row thumbnail renders the page", false, "no PDF in the library")
            return
        }
        let rendered = await ThumbnailCache.shared.thumbnail(for: row.url, size: .row, mtime: row.mtime)
        let request = QLThumbnailGenerator.Request(
            fileAt: row.url, size: ThumbnailCache.SizeClass.row.points, scale: 2,
            representationTypes: .icon)
        let icon = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        Check.that("row thumbnail renders the page rather than the file icon",
                   rendered != nil && rendered?.tiffRepresentation != icon?.nsImage.tiffRepresentation)
    }

    private static func inspectorDraws(_ model: AppModel, snapshots: String?) async {
        guard let first = model.documents.first else { return }
        model.selectedIDs = [first.id]
        guard await settle({ model.detail != nil }) else {
            Check.that("inspector loads the selected document", false)
            return
        }
        let (window, host) = host(InspectorView().environment(model),
                                  size: NSSize(width: 300, height: 780))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/inspector.png") }
        Check.that("inspector draws its content", inkedRows(host) > 20, "\(inkedRows(host)) rows with ink")
    }

    private static func uiStatePersists(_ model: AppModel) async {
        model.collapsedFolders = ["/tmp/one", "/tmp/two"]
        model.listColumns[visibility: "size"] = .hidden

        let folders: [String]? = await settled(model, "sidebar_collapsed_v1")
        Check.that("collapsed folders are persisted", folders?.sorted() == ["/tmp/one", "/tmp/two"],
                   folders?.joined(separator: ", ") ?? "nothing stored")

        let columns: TableColumnCustomization<DocumentRow>? = await settled(model, "list_columns_v1")
        Check.that("column layout is persisted", columns?[visibility: "size"] == .hidden)

        model.setSort(.name, ascending: true)
        let sort: StoredSort? = await settled(model, "list_sort_v1") {
            $0.field == "name" && $0.ascending
        }
        Check.that("sort order is persisted", sort?.field == "name" && sort?.ascending == true,
                   sort.map { "\($0.field) \($0.ascending ? "ascending" : "descending")" } ?? "nothing stored")

        model.viewMode = .gallery
        model.settings.galleryThumbnailSize = 190
        _ = await settle {
            Preferences.appWide.viewMode == .gallery && Preferences.appWide.galleryThumbnailSize == 190
        }
        let stored = Preferences.appWide
        Check.that("view mode and thumbnail size are persisted",
                   stored.viewMode == .gallery && stored.galleryThumbnailSize == 190,
                   "\(stored.viewMode.rawValue) at \(Int(stored.galleryThumbnailSize))")

        let blob = await settledRaw(model, AppSettings.storageKey)
        let appWideKeys = ["remoteAPIKey", "viewMode"].filter { blob?.contains($0) == true }
        Check.that("a library's own copy carries no app-wide settings",
                   blob != nil && appWideKeys.isEmpty,
                   blob == nil ? "nothing stored"
                       : (appWideKeys.isEmpty ? "library keys only" : appWideKeys.joined(separator: ", ")))

        let inLibrary: LibrarySettings? = await settled(model, AppSettings.storageKey)
        Check.that("what the blob holds is the library's own half", inLibrary != nil,
                   inLibrary == nil ? "nothing stored" : "stored")

        let partial = AppWideSettings.decoded(
            from: Data(#"{"viewMode":"Gallery","galleryThumbnailSize":190}"#.utf8))
        Check.that("a blob missing app-wide keys keeps the ones it has",
                   partial.viewMode == .gallery && partial.galleryThumbnailSize == 190
                       && partial.remoteEndpoint == AppWideSettings().remoteEndpoint,
                   "\(partial.viewMode.rawValue) at \(Int(partial.galleryThumbnailSize))")

        let partialLibrary = LibrarySettings.decoded(from: Data(#"{"routingThreshold":0.9}"#.utf8))
        Check.that("a blob missing library keys keeps the ones it has",
                   partialLibrary.routingThreshold == 0.9
                       && partialLibrary.namingTemplate == LibrarySettings().namingTemplate,
                   "threshold \(partialLibrary.routingThreshold)")

        model.viewMode = .list
        model.setSort(.docDate, ascending: false)
    }

    private static func intelligencePaneDraws(_ model: AppModel, snapshots: String?) async {
        let before = model.settings.llmBackend
        defer { model.settings.llmBackend = before }
        for backend in LLMBackend.allCases {
            model.settings.llmBackend = backend
            let (window, host) = host(IntelligenceSettings().environment(model),
                                      size: NSSize(width: 620, height: 470))
            defer { window.orderOut(nil) }
            try? await Task.sleep(for: .seconds(1))
            if let dir = snapshots { snapshot(host, to: dir + "/intelligence-\(backend.rawValue).png") }
            Check.that("the \(backend.label) settings pane draws", inkedRows(host) > 20,
                       "\(inkedRows(host)) rows with ink")
        }
    }

    private static func ruleEditorDraws(_ model: AppModel, snapshots: String?) async {
        guard let library = model.libraries.first,
              let rule = (try? await library.store.rules())?.first else {
            Check.that("the rule editor draws", false, "no rule to edit"); return
        }
        var full = rule
        full.requiresAll = true
        full.conditions.append(RuleCondition(field: .filename, pattern: "credit note", negated: true))
        full.conditions.append(RuleCondition(field: .correspondent, pattern: "acme", mode: .fuzzy))
        full.actions = RuleActionKind.allCases.map {
            RuleAction(kind: $0, value: rule.action($0) ?? $0.placeholder)
        }

        for (label, subject) in [("one condition", rule), ("every condition and action", full)] {
            let editor = RuleEditor(rule: subject, library: library) { _ in }
            let (window, host) = host(editor.environment(model), size: NSSize(width: 580, height: 600))
            defer { window.orderOut(nil) }
            try? await Task.sleep(for: .seconds(1))
            if let dir = snapshots {
                snapshot(host, to: dir + "/rule-editor-\(subject.conditions.count).png")
            }
            Check.that("the rule editor draws a rule with \(label)", inkedRows(host) > 20,
                       "\(inkedRows(host)) rows with ink")
        }
    }

    private static func rulesPaneDraws(_ model: AppModel, snapshots: String?) async {
        let (window, host) = host(RulesSettings().environment(model),
                                  size: NSSize(width: 620, height: 470))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(1))
        if let dir = snapshots { snapshot(host, to: dir + "/rules-pane.png") }
        Check.that("the rules pane draws", inkedRows(host) > 20, "\(inkedRows(host)) rows with ink")

        let rules = (try? await model.libraries.first?.store.rules()) ?? []
        Check.that("every rule says what it looks for and what it does",
                   !rules.isEmpty && rules.allSatisfy {
                       $0.conditionSummary != "—" && !$0.actionSummary.isEmpty
                   })
    }

    private static func finishedActionsAreToasts(_ model: AppModel, snapshots: String?) async {
        model.errorMessage = nil
        model.dismissNotice()
        let size = NSSize(width: 620, height: 200)
        let (window, host) = host(Color(nsColor: .windowBackgroundColor)
                                    .frame(width: size.width, height: size.height)
                                    .noticeOverlay(model)
                                    .environment(model), size: size)
        defer { window.orderOut(nil) }
        let blank = inkedRows(host)

        model.optimize(model.documents)
        let toasted = await settle({ model.notice != nil }, timeout: 20)
        try? await Task.sleep(for: .seconds(0.6))
        if let dir = snapshots { snapshot(host, to: dir + "/toast.png") }
        Check.that("a finished action reports as a toast", toasted && model.errorMessage == nil,
                   model.notice?.text ?? model.errorMessage ?? "nothing")
        Check.that("the toast draws", inkedRows(host) > blank + 10, "\(inkedRows(host)) rows with ink")
        let gone = await settle({ model.notice == nil }, timeout: 10)
        Check.that("the toast dismisses itself", gone)

        let backend = model.settings.llmBackend
        model.settings.llmBackend = .off
        defer { model.settings.llmBackend = backend }
        try? await Task.sleep(for: .seconds(0.5))
        model.analyze(Array(model.documents.prefix(1)))
        let alerted = await settle({ model.errorMessage != nil }, timeout: 10)
        Check.that("a failed action is still an alert", alerted && model.notice == nil,
                   model.errorMessage ?? model.notice?.text ?? "nothing")
        model.errorMessage = nil
    }

    private static func reviewPanelFiles(_ model: AppModel, snapshots: String?) async {
        guard let lib = model.libraries.first else { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("doctopus-review-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var copies: [URL] = []
        for row in model.documents where ["scan 003.pdf", "IMG_4821.pdf"].contains(row.filename) {
            let copy = staging.appendingPathComponent("review-" + row.filename)
            if copyAsNew(row.url, to: copy) { copies.append(copy) }
        }
        model.selection = .all
        model.importFiles(copies, into: nil)

        model.selection = .needsReview
        var candidate: DocumentRow?
        var detail: DocumentDetail?
        let found = await settle({
            candidate = model.documents.first { $0.filename.hasPrefix("review-") }
            return candidate != nil
        }, timeout: 60)
        if found, let candidate {
            model.selectedIDs = [candidate.id]
            _ = await settle({
                detail = model.detail
                return detail?.row.id == candidate.id && !(detail?.pathSuggestions.isEmpty ?? true)
            }, timeout: 20)
        }
        Check.that("a new document waits in Needs Review with suggested folders",
                   detail?.pathSuggestions.isEmpty == false,
                   candidate.map { "\($0.filename): \(detail?.pathSuggestions.map { ($0.path as NSString).lastPathComponent } ?? [])" } ?? "none waiting")
        guard let candidate, let detail,
              let primary = detail.pathSuggestions.first(where: { $0.path != candidate.directory })
        else {
            Check.that("a suggestion other than where it already is", false)
            return
        }

        let size = NSSize(width: 900, height: 660)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/review.png") }
        Check.that("the approval view draws the review under the list", inkedRows(host) > 100,
                   "\(inkedRows(host)) rows with ink")

        let secondary = lib.root.appendingPathComponent("Work").path
        model.file(candidate, in: URL(fileURLWithPath: primary.path), alsoIn: [secondary],
                   approve: true, advance: true)
        let filed = await poll(timeout: 20, { await model.loadDetail(candidate.id) }) {
            $0?.row.directory == primary.path && $0?.row.approved == true
                && $0?.folderAliases.contains { ($0 as NSString).deletingLastPathComponent == secondary } == true
        }
        let moved = filed?.row.directory == primary.path && filed?.row.approved == true
        Check.that("filing moves it to the chosen folder, aliases it into another and approves it", moved,
                   filed.map { "\($0.row.directory) · aliases \($0.folderAliases) · approved \($0.row.approved)" } ?? "gone")
        Check.that("filing leaves the aliased original findable",
                   filed.map { fm.fileExists(atPath: $0.row.path) } ?? false)

        model.discardGeneratedInfo([filed?.row ?? candidate])
        let discarded = await poll(timeout: 10, { await model.loadDetail(candidate.id) }) {
            $0 != nil && $0?.row.title == nil && $0?.row.docType == nil && $0?.pathSuggestions.isEmpty == true
        }
        let cleared = discarded != nil && discarded?.row.title == nil && discarded?.pathSuggestions.isEmpty == true
        Check.that("discarding generated info clears it and keeps the file", cleared
                   && fm.fileExists(atPath: discarded?.row.path ?? ""))
        model.selection = .all
    }

    private struct StoredSort: Codable {
        var field: String
        var ascending: Bool
    }

    private static func settled<T: Decodable>(_ model: AppModel, _ key: String,
                                              until: (T) -> Bool = { _ in true }) async -> T? {
        var last: T?
        _ = await settledRaw(model, key) { raw in
            guard let decoded = try? JSONDecoder().decode(T.self, from: Data(raw.utf8)) else { return false }
            last = decoded
            return until(decoded)
        }
        return last
    }

    private static func settledRaw(_ model: AppModel, _ key: String,
                                   until: (String) -> Bool = { _ in true }) async -> String? {
        var last: String?
        for _ in 0..<20 {
            var raw = Preferences.uiState(key)
            if raw == nil, let store = model.activeLibrary?.store {
                raw = (try? await store.setting(key)) ?? nil
            }
            if let raw {
                last = raw
                if until(raw) { return raw }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return last
    }

    private static func sidebarShowsBothTagSystems(_ model: AppModel, snapshots: String?) async {
        guard let row = model.documents.first else { return }
        let originalFinderTags = FinderTags.entries(row.url)

        model.addTag("Receipts", to: [row])
        model.addFinderTag("Blue", to: [row])
        if let type = model.fields.first(where: { $0.key == "doc_type" }),
           let value = row.values["doc_type"] {
            model.setValueIcon(type, value: value, icon: "banknote")
        }
        let indexed = await settle {
            model.finderTags.contains { $0.value == "Blue" } && model.tags.contains { $0.name == "Receipts" }
        }
        Check.that("both tag systems reach the sidebar", indexed,
                   "own: \(model.tags.map(\.name)), finder: \(model.finderTags.map(\.value))")

        let (sidebarWindow, sidebar) = host(SidebarView().environment(model),
                                            size: NSSize(width: 260, height: 700))
        defer { sidebarWindow.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(sidebar, to: dir + "/sidebar.png") }
        Check.that("sidebar draws its sections", inkedRows(sidebar) > 20)

        model.listColumns[visibility: "tags"] = .visible
        model.listColumns[visibility: "finderTags"] = .visible
        let (listWindow, listHost) = host(DocumentListView().environment(model),
                                          size: NSSize(width: 900, height: 300))
        defer { listWindow.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(listHost, to: dir + "/list-tags.png") }

        FinderTags.write(originalFinderTags, to: row.url)
    }

    /// Driven through `revealingFolders`, which is what the ⌥ monitor sets:
    /// the checks have no keyboard to hold.
    private static func optionRevealsFolders(_ model: AppModel) async {
        let rows = Array(model.documents.prefix(2))
        guard !rows.isEmpty else { return }
        defer { model.revealingFolders = false; model.selectedIDs = [] }

        model.selectedIDs = Set(rows.map(\.id))
        Check.that("nothing is pointed out before ⌥ is held", model.revealedFolders.isEmpty)
        model.revealingFolders = true
        let expected = Set(rows.map(\.directory))
        let lit = await settle { expected.isSubset(of: model.revealedFolders) }
        Check.that("⌥ points out every selected document's folder", lit,
                   "expected \(expected), got \(model.revealedFolders)")

        model.selectedIDs = []
        Check.that("and follows the selection while it is held", model.revealedFolders.isEmpty,
                   "\(model.revealedFolders)")
        model.selectedIDs = [rows[0].id]
        let back = await settle { model.revealedFolders.contains(rows[0].directory) }
        Check.that("including back onto a document", back)

        model.revealingFolders = false
        Check.that("letting go of ⌥ clears it", model.revealedFolders.isEmpty)
    }

    private static func handEditsReachTheHistory(_ model: AppModel) async {
        guard let row = model.documents.first else { return }
        model.selectedIDs = [row.id]
        guard await settle({ model.detail?.row.id == row.id }) else {
            Check.that("the document a hand edit is made on loads", false)
            return
        }
        let before = model.detail?.history.count ?? 0
        let queueBefore = model.queue.count

        func recorded(_ needle: String) -> Bool {
            model.detail?.history.contains {
                $0.action == "edited" && $0.detail?.contains(needle) == true
            } == true
        }

        let tag = "HandEdited"
        model.addTag(tag, to: [row])
        let tagged = await settle { recorded(tag) }
        Check.that("a tag added by hand is recorded in the history", tagged,
                   model.detail?.history.compactMap(\.detail).prefix(3)
                       .joined(separator: " / ") ?? "no events")

        let finderTag = "Green"
        model.addFinderTag(finderTag, to: [row])
        let finderTagged = await settle { recorded(finderTag) }
        Check.that("a Finder tag added by hand is recorded in the history", finderTagged)

        let title = "Titled by the checks"
        model.editMetadata(row.id, column: "title", value: title)
        let retitled = await settle { recorded(title) }
        Check.that("a title typed by hand is recorded in the history", retitled)

        Check.that("hand edits add to the history rather than replacing it",
                   (model.detail?.history.count ?? 0) >= before + 3,
                   "\(model.detail?.history.count ?? 0) events, was \(before)")

        Check.that("a hand edit does not queue the document for review",
                   model.queue.count <= queueBefore
                       && model.documents.first { $0.id == row.id }?.approved != false,
                   "\(model.queue.count) entries, was \(queueBefore)")

        model.removeFinderTag(finderTag, from: [row])
        if let added = model.tags.first(where: { $0.name == tag }) {
            model.removeTag(added, from: [row])
            let untagged = await settle { recorded("Untagged") }
            Check.that("taking a tag off by hand is recorded too", untagged)
            model.deleteTag(added)
        }
        model.editMetadata(row.id, column: "title", value: row.title)
        _ = await settle { model.documents.first { $0.id == row.id }?.title == row.title }
    }

    private static func secondLibraryMerges(_ model: AppModel, alongside fixture: URL,
                                            snapshots: String?) async {
        let alone = model.documents.count
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-uitest-2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: second) }
        try? FileManager.default.copyItem(at: fixture, to: second)

        model.selection = .all
        model.openLibrary(at: second)
        let opened = await settle { model.libraries.count == 2 && model.documents.count > alone }
        Check.that("a second library opens alongside the first",
                   opened, "\(model.libraries.count) libraries, \(model.documents.count) documents")
        guard model.libraries.count == 2 else { return }

        Check.that("the centre pane merges both libraries",
                   model.documents.count == alone * 2,
                   "\(model.documents.count) of an expected \(alone * 2)")
        Check.that("every row knows which library it came from",
                   Set(model.documents.map(\.library)).count == 2)

        if let sample = model.documents.first {
            let hits = model.globalSearch(text: sample.displayTitle, limit: 50).compactMap(\.document)
            let named = Set(hits.map(\.library))
            Check.that("a search result names the library its document is in",
                       hits.contains(sample.id) && named.count == 2,
                       "\(hits.count) hit(s) across \(named.count) of 2 libraries")
        }

        func ascendingByName() -> Bool {
            let titles = model.documents.map(\.displayTitle)
            guard titles.count == alone * 2 else { return false }
            return zip(titles, titles.dropFirst()).allSatisfy {
                $0.localizedStandardCompare($1) != .orderedDescending
            }
        }
        model.setSort(.name, ascending: true)
        let ordered = await settle(ascendingByName)
        Check.that("the merged list is still in sort order", ordered,
                   model.documents.map(\.displayTitle).prefix(3).joined(separator: " · "))

        let newer = model.libraries[1]
        guard let row = model.documents.first(where: { $0.library == newer.id }) else { return }
        model.addTag("OnlyHere", to: [row])
        _ = await settle { newer.tags.contains { $0.name == "OnlyHere" } }
        Check.that("a tag is made in the library of the row it was dropped on",
                   newer.tags.contains { $0.name == "OnlyHere" }
                       && !model.libraries[0].tags.contains { $0.name == "OnlyHere" },
                   "first: \(model.libraries[0].tags.map(\.name)), second: \(newer.tags.map(\.name))")

        let (sidebarWindow, sidebar) = host(SidebarView().environment(model),
                                            size: NSSize(width: 260, height: 700))
        defer { sidebarWindow.orderOut(nil) }
        let (listWindow, listHost) = host(DocumentListView().environment(model),
                                          size: NSSize(width: 900, height: 400))
        defer { listWindow.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots {
            snapshot(sidebar, to: dir + "/sidebar-two-libraries.png")
            snapshot(listHost, to: dir + "/list-two-libraries.png")
        }
        Check.that("the sidebar draws a group per library", inkedRows(sidebar) > 20,
                   "\(inkedRows(sidebar)) rows with ink")
        Check.that("the list draws with both libraries in it", inkedRows(listHost) > 20,
                   "\(inkedRows(listHost)) rows with ink")

        model.closeLibrary(newer)
        let closed = await settle { model.libraries.count == 1 && model.documents.count == alone }
        Check.that("closing a library takes its rows out of the pane", closed,
                   "\(model.documents.count) documents left")
        Check.that("closing a library leaves its folder on disk",
                   FileManager.default.fileExists(
                       atPath: second.appendingPathComponent("library.doctopus").path))
        model.setSort(.docDate, ascending: false)
    }

    private static func droppingAFolderImportsIt(_ model: AppModel) async {
        let fm = FileManager.default
        model.selection = .all
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(1))

        let folder = fm.temporaryDirectory.appendingPathComponent("doctopus-drop-\(UUID().uuidString)")
        let nested = folder.appendingPathComponent("Receipts/2025", isDirectory: true)
        try? fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let tag = String(UUID().uuidString.prefix(6))
        for (i, row) in model.documents.prefix(2).enumerated() {
            copyAsNew(row.url, to: (i == 0 ? folder : nested)
                .appendingPathComponent("dropped-\(tag)-\(i).pdf"))
        }

        let pasteboard = NSPasteboard(name: .init("doctopus-uitest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        let drag = SyntheticDrag(pasteboard: pasteboard, window: window,
                                 at: NSPoint(x: size.width / 2, y: size.height / 2))
        // SwiftUI registers a subview of the hosting view for drops, not the
        // hosting view itself.
        guard let target = dropTarget(in: host) else {
            Check.that("dropping a folder imports the documents inside it", false, "no drop target"); return
        }
        let accepted = target.draggingEntered(drag) != [] && target.draggingUpdated(drag) != []
            && target.prepareForDragOperation(drag) && target.performDragOperation(drag)
        target.concludeDragOperation(drag)

        let arrived = await settle({ model.documents.filter { $0.filename.contains(tag) }.count == 2 },
                                   timeout: 30)
        Check.that("dropping a folder imports the documents inside it", accepted && arrived,
                   "accepted \(accepted), \(model.documents.filter { $0.filename.contains(tag) }.count) of 2 arrived")
        for row in model.documents where row.filename.contains(tag) { try? fm.removeItem(at: row.url) }
    }

    private static func draggingOntoAFolderFilesOrMoves(_ model: AppModel) async {
        let fm = FileManager.default
        defer { FolderDropIntent.heldModifiers = { NSEvent.modifierFlags } }
        func fail(_ why: String) {
            Check.that("a drag onto a folder files the document there as well", false, why)
        }
        guard let library = model.libraries.first else { return fail("no library open") }

        let name = "Dropped-\(UUID().uuidString.prefix(6))"
        let destination = library.root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let node = FolderNode(path: destination.path, name: name,
                              children: [], count: 0, deepCount: 0)
        let (window, host) = host(VStack { FolderRow(node: node, depth: 0) }.environment(model),
                                  size: NSSize(width: 240, height: 90))
        defer { window.orderOut(nil) }
        // SwiftUI registers a drop target under the types the wanted one
        // conforms to — `public.data` and `public.item` for ours — rather than
        // under its own identifier, and not before the view has been laid out.
        func takesDocuments(_ view: NSView) -> Bool {
            view.registeredDraggedTypes.contains {
                UTType($0.rawValue).map(UTType.doctopusDocument.conforms(to:)) == true
            }
        }
        var targets: [NSView] = []
        _ = await settle({
            targets = dropTargets(in: host)
            return targets.contains(where: takesDocuments)
        }, timeout: 10)
        guard let target = targets.first(where: takesDocuments) else {
            return fail("nothing under the hosted row takes a Doctopus document · registered "
                + "\(Set(targets.flatMap { $0.registeredDraggedTypes.map(\.rawValue) }).sorted())")
        }

        model.selectedIDs = []
        let candidates = model.documents.filter {
            $0.library == library.id && !$0.isAliasHere && !$0.missing
                && $0.directory != destination.path && fm.fileExists(atPath: $0.path)
        }
        guard candidates.count >= 2 else { return fail("\(candidates.count) usable documents") }

        FolderDropIntent.heldModifiers = { NSEvent.ModifierFlags() }
        let filed = candidates[0]
        let filedTaken = drop(DocumentDragItem(filed), on: target, in: window)
        let aliased = await settle({
            ((try? fm.contentsOfDirectory(atPath: destination.path)) ?? []).count > 0
        }, timeout: 20)
        Check.that("a drag onto a folder files the document there as well",
                   filedTaken && aliased && fm.fileExists(atPath: filed.path),
                   "taken \(filedTaken), filed \(aliased), master still in place \(fm.fileExists(atPath: filed.path))")

        FolderDropIntent.heldModifiers = { NSEvent.ModifierFlags.command }
        let moving = candidates[1]
        let cameFrom = URL(fileURLWithPath: moving.directory)
        let movedTaken = drop(DocumentDragItem(moving), on: target, in: window)
        let landed = destination.appendingPathComponent(moving.filename)
        let arrived = await settle({
            fm.fileExists(atPath: landed.path) && !fm.fileExists(atPath: moving.path)
        }, timeout: 20)
        Check.that("⌘ held over the folder moves the file instead of filing it twice",
                   movedTaken && arrived,
                   "taken \(movedTaken), at \(name)/\(moving.filename) \(fm.fileExists(atPath: landed.path)), "
                       + "gone from where it was \(!fm.fileExists(atPath: moving.path))")

        try? fm.createDirectory(at: cameFrom, withIntermediateDirectories: true)
        try? fm.moveItem(at: landed, to: cameFrom.appendingPathComponent(moving.filename))
        try? fm.removeItem(at: destination)
    }

    private static func drop(_ item: DocumentDragItem, on target: NSView, in window: NSWindow) -> Bool {
        guard let payload = try? JSONEncoder().encode(item) else { return false }
        let pasteboard = NSPasteboard(name: .init("doctopus-uitest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        _ = entry.setData(payload, forType: .init(UTType.doctopusDocument.identifier))
        _ = pasteboard.writeObjects([entry])

        let middle = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let drag = SyntheticDrag(pasteboard: pasteboard, window: window, at: middle)
        drag.draggingSourceOperationMask = [.copy, .move]
        let taken = target.draggingEntered(drag) != [] && target.draggingUpdated(drag) != []
            && target.prepareForDragOperation(drag) && target.performDragOperation(drag)
        target.concludeDragOperation(drag)
        return taken
    }

    @discardableResult
    private static func copyAsNew(_ source: URL, to target: URL) -> Bool {
        guard var data = try? Data(contentsOf: source) else { return false }
        data.append(Data("\n% unique-\(UUID().uuidString)\n".utf8))
        return (try? data.write(to: target)) != nil
    }

    private static func dropTarget(in view: NSView) -> NSView? {
        if !view.registeredDraggedTypes.isEmpty { return view }
        return view.subviews.lazy.compactMap { dropTarget(in: $0) }.first
    }

    private static func dropTargets(in view: NSView) -> [NSView] {
        (view.registeredDraggedTypes.isEmpty ? [] : [view])
            + view.subviews.flatMap { dropTargets(in: $0) }
    }

    private static func host<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // AppKit releases a programmatically created window when it closes,
        // and the harness still holds it.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (window, host)
    }

    @discardableResult
    private static func click(_ window: NSWindow, at point: NSPoint,
                              attempts: Int = 4, settling: TimeInterval = 3,
                              activating: Bool = false,
                              until condition: () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if activating {
                NSApp.activate(ignoringOtherApps: true)
                _ = await settle({ NSApp.isActive }, timeout: 2)
            }
            window.makeKeyAndOrderFront(nil)
            post(window, at: point)
            if await settle(condition, timeout: settling) { return true }
        }
        return false
    }

    private static func post(_ window: NSWindow, at point: NSPoint, clickCount: Int = 1) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: Int.random(in: 1000...9999), clickCount: clickCount, pressure: 1)
            else { continue }
            // Posted rather than sent: NSTableView's mouseDown runs its own
            // tracking loop and pulls the mouseUp off the queue itself.
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func poll<T>(timeout: TimeInterval, _ fetch: () async -> T,
                                until: (T) -> Bool) async -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var value = await fetch()
        while !until(value), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            value = await fetch()
        }
        return value
    }

    private static func settle(_ condition: () -> Bool, timeout: TimeInterval = 30,
                               every interval: Duration = .milliseconds(200)) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }

    private static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func inkedRows(_ view: NSView) -> Int {
        guard let rep = bitmap(view) else { return 0 }
        let background = rep.colorAt(x: rep.pixelsWide - 2, y: rep.pixelsHigh - 2)
        var rows = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                if let c = rep.colorAt(x: x, y: y), c != background { rows += 1; break }
            }
        }
        return rows
    }

    private static func snapshot(_ view: NSView, to path: String) {
        guard let png = bitmap(view)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: path))
        print("  snapshot: \(path)")
    }
}

private final class SyntheticDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    private weak var window: NSWindow?

    init(pasteboard: NSPasteboard, window: NSWindow, at point: NSPoint) {
        draggingPasteboard = pasteboard
        draggingLocation = point
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class URLRecorder {
    var urls: [URL] = []
}
