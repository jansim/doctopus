import SwiftUI
import AppKit

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

            let model = AppModel()
            await model.bootstrap()
            await model.openLibrary(container: container, quietly: true)
            guard await settle({ !model.documents.isEmpty }) else {
                print("  ✗ indexed the library"); exit(1)
            }
            print("CHECKS")
            print("  ✓ indexed the library  (\(model.documents.count) documents)")

            await clickSelectsARow(model, snapshots: snapshots)
            await clickSelectsAGalleryThumbnail(model, snapshots: snapshots)
            galleryModifierClicks(model)
            commandASelectsEverything(model)
            dragCountsTheSelection(model)
            folderPickerResolvesPaths(model)
            await headerClickSorts(model, snapshots: snapshots)
            await rowThumbnailIsAPage(model)
            await inspectorDraws(model, snapshots: snapshots)
            await intelligencePaneDraws(model, snapshots: snapshots)
            await ruleEditorDraws(model, snapshots: snapshots)
            await rulesPaneDraws(model, snapshots: snapshots)
            await finishedActionsAreToasts(model, snapshots: snapshots)
            await approvingIsNotAToast(model)
            await uiStatePersists(model)
            await sidebarShowsBothTagSystems(model, snapshots: snapshots)
            await handEditsReachTheHistory(model)
            await unsavedEditsAreAskedAbout(model)
            await dateCommitsWhenDone()
            await tagCountsFollowEdits(model)
            await tagIconsReachTheSidebar(model, snapshots: snapshots)
            await metadataPaneLists(model, snapshots: snapshots)
            await optionRevealsFolders(model)
            await searchFieldTakesAndGivesUpFocus(model)
            await secondLibraryOpensApart(model, alongside: library, snapshots: snapshots)
            await reviewPanelFiles(model, snapshots: snapshots)
            await reviewBatchTreatsEachKindApart(model, snapshots: snapshots)
            await recentlyReviewedHasNoCheckboxes(model, snapshots: snapshots)
            await droppingAFolderImportsIt(model)
            await draggingOntoAFolderFilesOrMoves(model)
            await undoTakesBackAMove(model)
            await namingMismatchDraws(model, snapshots: snapshots)
            await libraryFollowsItsFolder(model, fixture: library)
            cancelEndsAScanRun(model)
            Check.finish("ui checks")
        }
        app.run()
    }

    private static var previousApp: NSRunningApplication?

    static func yieldFocus() {
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    @discardableResult
    static func copyAsNew(_ source: URL, to target: URL) -> Bool {
        guard var data = try? Data(contentsOf: source) else { return false }
        data.append(Data("\n% unique-\(UUID().uuidString)\n".utf8))
        return (try? data.write(to: target)) != nil
    }

    static func host<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSView) {
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
    static func click(_ window: NSWindow, at point: NSPoint,
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

    static func post(_ window: NSWindow, at point: NSPoint, clickCount: Int = 1) {
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

    static func poll<T>(timeout: TimeInterval, _ fetch: () async -> T,
                        until: (T) -> Bool) async -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var value = await fetch()
        while !until(value), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            value = await fetch()
        }
        return value
    }

    static func settle(_ condition: () -> Bool, timeout: TimeInterval = 30,
                       every interval: Duration = .milliseconds(200)) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }

    static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    static func inkedRows(_ view: NSView) -> Int {
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

    static func snapshot(_ view: NSView, to path: String) {
        guard let png = bitmap(view)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: path))
        print("  snapshot: \(path)")
    }
}
