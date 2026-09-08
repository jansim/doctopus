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
        // Regular rather than accessory: synthetic mouse events are only
        // delivered reliably once the process is genuinely the active app.
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let library = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).standardizedFileURL

        Task { @MainActor in
            let dbURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("doctopus-uitest-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: dbURL) }

            let model = AppModel(storeURL: dbURL)
            _ = try? await model.store.addRoot(path: library.path, bookmark: nil)
            await model.bootstrap()
            guard await settle({ !model.documents.isEmpty }) else {
                print("  ✗ indexed the library"); exit(1)
            }
            print("CHECKS")
            print("  ✓ indexed the library  (\(model.documents.count) documents)")

            await clickSelectsARow(model, snapshots: snapshots)
            await headerClickSorts(model, snapshots: snapshots)
            await rowThumbnailIsAPage(model)
            await inspectorDraws(model, snapshots: snapshots)
            await uiStatePersists(model)
            await sidebarShowsBothTagSystems(model, snapshots: snapshots)
            Check.finish("ui checks")
        }
        app.run()
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
        let selected = await click(window, at: NSPoint(x: 140, y: size.height - 43)) {
            !model.selectedIDs.isEmpty
        }
        Check.that("clicking a document's name selects it", selected,
                   model.documents.filter { model.selectedIDs.contains($0.id) }
                       .map(\.filename).joined(separator: ", "))
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
        let sorted = await click(window, at: header) { model.sort == .size }
        Check.that("clicking a column header sorts by it", sorted, "sort is \(model.sort.label)")

        let wasAscending = model.sortAscending
        let flipped = await click(window, at: header) { model.sortAscending != wasAscending }
        Check.that("clicking it again reverses the direction", flipped)
        if let dir = snapshots {
            try? await Task.sleep(for: .seconds(1))
            snapshot(host, to: dir + "/list-sorted.png")
        }
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

    /// The sidebar's collapsed folders and the list's column layout are meant
    /// to survive a relaunch, so they have to reach the settings table.
    private static func uiStatePersists(_ model: AppModel) async {
        model.collapsedFolders = ["/tmp/one", "/tmp/two"]
        model.listColumns[visibility: "size"] = .hidden

        let folders: [String]? = await settled(model, "sidebar_collapsed_v1")
        Check.that("collapsed folders are persisted", folders?.sorted() == ["/tmp/one", "/tmp/two"],
                   folders?.joined(separator: ", ") ?? "nothing stored")

        let columns: TableColumnCustomization<DocumentRow>? = await settled(model, "list_columns_v1")
        Check.that("column layout is persisted", columns?[visibility: "size"] == .hidden)
    }

    private static func settled<T: Decodable>(_ model: AppModel, _ key: String) async -> T? {
        for _ in 0..<20 {
            if let raw = try? await model.store.setting(key), let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
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
                              attempts: Int = 4, until condition: () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            NSApp.activate(ignoringOtherApps: true)
            _ = await settle({ NSApp.isActive }, timeout: 2)
            window.makeKeyAndOrderFront(nil)
            post(window, at: point)
            if await settle(condition, timeout: 3) { return true }
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
