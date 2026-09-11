import SwiftUI
import AppKit
import QuickLookThumbnailing
import QuickLookUI

/// Headless checks for the parts of the UI that only break when they are
/// actually on screen: hit testing and thumbnail rendering. Runs a real
/// AppModel against a throwaway index, hosts the panes in an off-screen
/// window and drives them with synthetic events.
///
/// `Doctopus --uitest <library> [snapshot dir]`
@MainActor
enum UITest {
    static func run(root: String, snapshots: String?) {
        let app = NSApplication.shared
        // Accessory, and windows are hosted off-screen: nothing of this should
        // appear in front of whoever is running it. The one unavoidable
        // intrusion is that `NSTableView` ignores a synthetic click unless the
        // process is genuinely frontmost, so the checks that drive the list ask
        // for focus and hand it straight back to whatever had it.
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
            await headerClickSorts(model, snapshots: snapshots)
            await rowThumbnailIsAPage(model)
            await inspectorDraws(model, snapshots: snapshots)
            await intelligencePaneDraws(model, snapshots: snapshots)
            await ruleEditorDraws(model, snapshots: snapshots)
            await finishedActionsAreToasts(model, snapshots: snapshots)
            await uiStatePersists(model)
            await sidebarShowsBothTagSystems(model, snapshots: snapshots)
            await secondLibraryMerges(model, alongside: library, snapshots: snapshots)
            // Last: they import documents, which the checks above count.
            await reviewPanelFiles(model, snapshots: snapshots)
            await droppingAFolderImportsIt(model)
            Check.finish("ui checks")
        }
        app.run()
    }

    private static var previousApp: NSRunningApplication?

    /// Gives focus back to the app the checks took it from.
    private static func yieldFocus() {
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    // MARK: - Checks

    /// Regression: with the drag attached to the cell rather than the row, a
    /// click on the document name — the largest target in the row — selected
    /// nothing at all.
    private static func clickSelectsARow(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/list.png") }

        model.selectedIDs = []
        // Over the title text of the first row, well clear of the thumbnail.
        let selected = await click(window, at: NSPoint(x: 140, y: size.height - 43),
                                   activating: true) {
            !model.selectedIDs.isEmpty
        }
        Check.that("clicking a document's name selects it", selected,
                   model.documents.filter { model.selectedIDs.contains($0.id) }
                       .map(\.filename).joined(separator: ", "))

        // The row thumbnail is hit-testable now, which must not mean it eats
        // the click on its way to the row.
        model.selectedIDs = []
        let viaThumbnail = await click(window, at: NSPoint(x: 22, y: size.height - 43),
                                       activating: true) {
            !model.selectedIDs.isEmpty
        }
        Check.that("clicking a row's thumbnail selects it too", viaThumbnail)
        yieldFocus()
    }

    /// Regression: the gallery cell had no hit shape of its own, so only the
    /// pixels the fitted page actually covered responded. The padding around
    /// the thumbnail, the bands either side of a page narrower than its frame
    /// and the gap above the title all swallowed clicks.
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
        // Middle of the first thumbnail, and its top-left corner — the corner
        // is the one that used to do nothing.
        for (where_, point) in [("middle", middle),
                                ("corner", NSPoint(x: 22, y: size.height - 24))] {
            model.selectedIDs = []
            // One click, briefly: this is about a click landing, not about
            // eventually landing after a few tries.
            let selected = await click(window, at: point, attempts: 1, settling: 0.6) {
                !model.selectedIDs.isEmpty
            }
            Check.that("clicking the \(where_) of a gallery thumbnail selects it", selected)
        }

        // Regression: a double-click gesture stacked on the single-click one
        // made SwiftUI hold every click back for the double-click interval, in
        // case a second one followed, so a selection in the gallery trailed
        // the mouse by half a second where the list's was instant.
        model.selectedIDs = []
        let start = Date()
        post(window, at: middle)
        let landed = await settle({ !model.selectedIDs.isEmpty }, timeout: 2, every: .milliseconds(5))
        let elapsed = Date().timeIntervalSince(start)
        Check.that("a gallery click selects without waiting out the double-click interval",
                   landed && elapsed < NSEvent.doubleClickInterval * 0.6,
                   "\(Int(elapsed * 1000)) ms, interval \(Int(NSEvent.doubleClickInterval * 1000)) ms")

        // Which leaves telling a double-click apart to the tap handler.
        model.selectedIDs = []
        post(window, at: middle)
        post(window, at: middle, clickCount: 2)
        let opened = await settle({ QuickLookController.shared.isOpen }, timeout: 3)
        Check.that("double-clicking a gallery thumbnail opens Quick Look", opened,
                   "\(model.selectedIDs.count) selected")
        if opened { QLPreviewPanel.shared().orderOut(nil) }
        model.selectedIDs = []
    }

    /// Clicking a column header sorts by that column, and clicking it again
    /// reverses the direction.
    private static func headerClickSorts(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))

        // The Size header, at the far right of the header row.
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

    /// Regression: list rows asked Quick Look for `.icon`, which always returns
    /// the generic file-type badge instead of the page.
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

    /// A smoke test that the inspector lays out and draws something: a blank
    /// pane is the failure mode when a layout container rejects its content.
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

    /// Everything about how the library is being looked at is meant to survive
    /// a relaunch, so it all has to reach the settings table.
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

        // How documents are looked at is about this Mac rather than about a
        // folder, so it is written to preferences and not into any library.
        model.viewMode = .gallery
        model.settings.galleryThumbnailSize = 190
        _ = await settle {
            Preferences.appWide.viewMode == .gallery && Preferences.appWide.galleryThumbnailSize == 190
        }
        let stored = Preferences.appWide
        Check.that("view mode and thumbnail size are persisted",
                   stored.viewMode == .gallery && stored.galleryThumbnailSize == 190,
                   "\(stored.viewMode.rawValue) at \(Int(stored.galleryThumbnailSize))")

        let inLibrary: AppSettings? = await settled(model, AppSettings.storageKey)
        Check.that("a library's own copy carries no app-wide settings",
                   inLibrary?.viewMode == AppSettings().viewMode && inLibrary?.remoteAPIKey == "",
                   inLibrary.map { "library blob says \($0.viewMode.rawValue)" } ?? "nothing stored")

        // Regression: `AppSettings` decoded key by key or not at all, and `load`
        // swallowed the failure — so the first release to add a setting reset
        // every one the user had already chosen.
        let partial = #"{"viewMode":"Gallery","galleryThumbnailSize":190}"#
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
        Check.that("settings stored by an older version still load",
                   decoded?.viewMode == .gallery && decoded?.galleryThumbnailSize == 190
                       && decoded?.namingTemplate == AppSettings().namingTemplate,
                   decoded == nil ? "decode failed outright" : "decoded")

        // The on-device model used to be a plain on/off switch. Someone who
        // turned it off meant it, so the choice survives the move to a picker
        // rather than silently coming back on.
        let legacyOff = #"{"useOnDeviceModel":false}"#
        let legacyOn = #"{"useOnDeviceModel":true}"#
        let off = try? JSONDecoder().decode(AppSettings.self, from: Data(legacyOff.utf8))
        let on = try? JSONDecoder().decode(AppSettings.self, from: Data(legacyOn.utf8))
        Check.that("an older on/off model setting becomes a backend choice",
                   off?.llmBackend == .off && on?.llmBackend == .onDevice,
                   "\(off?.llmBackend.rawValue ?? "nil") / \(on?.llmBackend.rawValue ?? "nil")")

        model.viewMode = .list
        model.setSort(.docDate, ascending: false)
    }

    /// The Intelligence pane changes shape with the chosen backend, and a
    /// branch that lays out to nothing is the failure mode worth catching.
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

    /// The rule editor is a sheet over a fixed-size Settings window, so a
    /// layout that overflows it shows up as a blank or clipped pane.
    private static func ruleEditorDraws(_ model: AppModel, snapshots: String?) async {
        guard let library = model.libraries.first,
              let rule = (try? await library.store.rules())?.first else {
            Check.that("the rule editor draws", false, "no rule to edit"); return
        }
        let editor = RuleEditor(rule: rule, library: library,
                                threshold: model.settings.routingThreshold) { _ in }
        let (window, host) = host(editor.environment(model), size: NSSize(width: 540, height: 460))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(1))
        if let dir = snapshots { snapshot(host, to: dir + "/rule-editor.png") }
        Check.that("the rule editor draws", inkedRows(host) > 20, "\(inkedRows(host)) rows with ink")
    }

    /// Finishing something is a toast that goes away by itself; only a failure
    /// is an alert that has to be clicked away.
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

        // The demo fixtures are small, so Optimize has nothing to do — which is
        // still a result, and should read as one.
        model.optimize(model.documents)
        let toasted = await settle({ model.notice != nil }, timeout: 20)
        try? await Task.sleep(for: .seconds(0.6))
        if let dir = snapshots { snapshot(host, to: dir + "/toast.png") }
        Check.that("a finished action reports as a toast", toasted && model.errorMessage == nil,
                   model.notice?.text ?? model.errorMessage ?? "nothing")
        Check.that("the toast draws", inkedRows(host) > blank + 10, "\(inkedRows(host)) rows with ink")
        let gone = await settle({ model.notice == nil }, timeout: 10)
        Check.that("the toast dismisses itself", gone)

        // A run that cannot start is a problem, and stays an alert.
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

    /// The approval view splits into the list and a review of the selected
    /// document, from which it can be filed — moved to one folder, aliased
    /// into others — approved, and have what was generated thrown away.
    private static func reviewPanelFiles(_ model: AppModel, snapshots: String?) async {
        guard let lib = model.libraries.first else { return }
        let fm = FileManager.default
        // New documents from outside, with no folder chosen: the router files
        // what is clear and leaves the rest waiting with suggestions.
        let staging = fm.temporaryDirectory.appendingPathComponent("doctopus-review-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var copies: [URL] = []
        for row in model.documents where ["scan 003.pdf", "IMG_4821.pdf"].contains(row.filename) {
            let copy = staging.appendingPathComponent("review-" + row.filename)
            if (try? fm.copyItem(at: row.url, to: copy)) != nil { copies.append(copy) }
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
        // A suggestion other than where it is, so filing really moves it.
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

        // File it: the first suggestion as its home, Work as an alias.
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

        // Throwing away what was generated clears it from the index only.
        model.discardGeneratedInfo([filed?.row ?? candidate])
        let discarded = await poll(timeout: 10, { await model.loadDetail(candidate.id) }) {
            $0 != nil && $0?.row.title == nil && $0?.row.docType == nil && $0?.pathSuggestions.isEmpty == true
        }
        let cleared = discarded != nil && discarded?.row.title == nil && discarded?.pathSuggestions.isEmpty == true
        Check.that("discarding generated info clears it and keeps the file", cleared
                   && fm.fileExists(atPath: discarded?.row.path ?? ""))
        model.selection = .all
    }

    /// Mirrors what `AppModel` writes for the sort, which is private to it.
    private struct StoredSort: Codable {
        var field: String
        var ascending: Bool
    }

    /// Waits for a settings key to hold what is expected. `until` matters where
    /// the key already carries a value from an earlier check: without it the
    /// first read would return the old one and pass or fail on nothing.
    private static func settled<T: Decodable>(_ model: AppModel, _ key: String,
                                              until: (T) -> Bool = { _ in true }) async -> T? {
        var last: T?
        for _ in 0..<20 {
            // Column/collapsed/sort state lives in UserDefaults now; the settings
            // blob still lives in the library's database.
            var raw = Preferences.uiState(key)
            if raw == nil, let store = model.activeLibrary?.store {
                raw = (try? await store.setting(key)) ?? nil
            }
            if let raw, let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                last = decoded
                if until(decoded) { return decoded }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return last
    }

    /// Doctopus's tags and the Finder's are separate sections, and a document
    /// type can carry its own icon. Mutating state here touches the library's
    /// files, so everything is put back afterwards.
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

        // Both tag columns, which are off by default.
        model.listColumns[visibility: "tags"] = .visible
        model.listColumns[visibility: "finderTags"] = .visible
        let (listWindow, listHost) = host(DocumentListView().environment(model),
                                          size: NSSize(width: 900, height: 300))
        defer { listWindow.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(listHost, to: dir + "/list-tags.png") }

        // The index is a throwaway, but the Finder tag was written to the
        // user's own file and has to go back the way it was found.
        FinderTags.write(originalFinderTags, to: row.url)
    }

    /// Two libraries open at once: the centre pane merges them, the sort still
    /// holds across the join, and tags stay with the library they were made in.
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

        // Rows arrive already sorted per library; the merge is what has to keep
        // them in order once they are one list.
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

        // A tag belongs to the library it was made in, even when the same name
        // exists in both.
        let newer = model.libraries[1]
        guard let row = model.documents.first(where: { $0.library == newer.id }) else { return }
        model.addTag("OnlyHere", to: [row])
        _ = await settle { newer.tags.contains { $0.name == "OnlyHere" } }
        Check.that("a tag is made in the library of the row it was dropped on",
                   newer.tags.contains { $0.name == "OnlyHere" }
                       && !model.libraries[0].tags.contains { $0.name == "OnlyHere" },
                   "first: \(model.libraries[0].tags.map(\.name)), second: \(newer.tags.map(\.name))")

        // The sidebar groups folders and tags per library, and the list gains a
        // Library column — both are new shapes that only exist with two open,
        // and a duplicated ForEach id here is a runtime trap rather than a
        // build error.
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

    /// Regression: a drop onto the document pane only took files of a type
    /// Doctopus reads, so a folder dragged in from Finder bounced straight
    /// back. It is driven through AppKit's own drag entry points, since what
    /// broke was what the drop target accepts.
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
            try? fm.copyItem(at: row.url, to: (i == 0 ? folder : nested)
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

    // MARK: - Harness

    private static func dropTarget(in view: NSView) -> NSView? {
        if !view.registeredDraggedTypes.isEmpty { return view }
        return view.subviews.lazy.compactMap { dropTarget(in: $0) }.first
    }

    private static func host<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        // Off-screen: the checks drive the views directly, and nothing should
        // flash up in front of whoever is running them.
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // AppKit releases a programmatically created window when it closes,
        // and the harness still holds it.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (window, host)
    }

    /// Clicks until the expected effect shows up. A synthetic click is dropped
    /// if the process is not active yet or the view is still settling, and
    /// re-clicking is cheaper than guessing at a long enough delay.
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

    /// Waits for an asynchronous condition, since indexing and detail loading
    /// both hop between actors.
    /// Fetches until the value satisfies `until`, and returns the last fetch
    /// either way — for state that is read asynchronously, like a detail.
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

    /// How many scanlines contain something other than the background colour.
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

/// The least of a drag session AppKit hands a drop target: a pasteboard, a
/// place and an operation. Everything about the drag image is inert.
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
    var draggingSourceOperationMask: NSDragOperation { .copy }
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
