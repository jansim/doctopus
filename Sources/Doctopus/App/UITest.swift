import SwiftUI
import AppKit
import QuickLookThumbnailing

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
            await uiStatePersists(model)
            await sidebarShowsBothTagSystems(model, snapshots: snapshots)
            await secondLibraryMerges(model, alongside: library, snapshots: snapshots)
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
        // Middle of the first thumbnail, and its top-left corner — the corner
        // is the one that used to do nothing.
        for (where_, point) in [("middle", NSPoint(x: 18 + cell / 2, y: size.height - (18 + cell * 0.65))),
                                ("corner", NSPoint(x: 22, y: size.height - 24))] {
            model.selectedIDs = []
            // One click, briefly: this is about a click landing, not about
            // eventually landing after a few tries.
            let selected = await click(window, at: point, attempts: 1, settling: 0.6) {
                !model.selectedIDs.isEmpty
            }
            Check.that("clicking the \(where_) of a gallery thumbnail selects it", selected)
        }
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

    // MARK: - Harness

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

    private static func post(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: Int.random(in: 1000...9999), clickCount: 1, pressure: 1)
            else { continue }
            // Posted rather than sent: NSTableView's mouseDown runs its own
            // tracking loop and pulls the mouseUp off the queue itself.
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Waits for an asynchronous condition, since indexing and detail loading
    /// both hop between actors.
    private static func settle(_ condition: () -> Bool, timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
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
