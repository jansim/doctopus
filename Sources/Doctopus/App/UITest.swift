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
        app.setActivationPolicy(.accessory)
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
            await rowThumbnailIsAPage(model)
            await inspectorDraws(model, snapshots: snapshots)
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
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))

        // Over the title text of the first row, well clear of the thumbnail.
        click(window, at: NSPoint(x: 140, y: size.height - 43))
        let selected = await settle { !model.selectedIDs.isEmpty }
        Check.that("clicking a document's name selects it", selected,
                   model.documents.filter { model.selectedIDs.contains($0.id) }
                       .map(\.filename).joined(separator: ", "))
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

    private static func click(_ window: NSWindow, at point: NSPoint) {
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
