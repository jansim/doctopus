import SwiftUI
import AppKit

/// Moving an existing selection on to another document, by click and by
/// arrow key, rather than only making one from nothing.
extension UITest {
    static func selectionMovesInTheList(_ model: AppModel) async {
        model.selection = .all
        model.viewMode = .list
        // The library window's wider table would otherwise leave its column
        // widths to the checks after this one.
        let columns = model.listColumns
        defer { model.listColumns = columns }
        _ = await settle({ model.documents.count >= 4 }, timeout: 10)
        guard model.documents.count >= 4 else {
            return Check.that("enough documents to move the selection through", false,
                              "\(model.documents.count) documents")
        }

        let (window, host) = host(DocumentListView().environment(model), size: NSSize(width: 760, height: 420))
        try? await Task.sleep(for: .seconds(2))
        await moveSelection(in: window, host: host, model, where: "the list")
        window.orderOut(nil)

        // As the app shows it: sidebar, toolbar, search field and inspector,
        // which a selection fills with its document.
        let library = libraryWindow(model)
        try? await Task.sleep(for: .seconds(2))
        if let host = library.contentView {
            await moveSelection(in: library, host: host, model, where: "the library window")
        }
        library.orderOut(nil)
        model.selectedIDs = []
        yieldFocus()
    }

    static func selectionMovesInTheGallery(_ model: AppModel) async {
        model.selection = .all
        model.viewMode = .gallery
        defer { model.viewMode = .list }
        let (window, host) = host(DocumentListView().environment(model), size: NSSize(width: 760, height: 420))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))

        // The cells' own drag sources say where the thumbnails are, top row first.
        let cells = sources(in: host)
            .map { $0.convert($0.bounds, to: nil) }
            .filter { host.convert(host.bounds, to: nil).contains(NSPoint(x: $0.midX, y: $0.midY)) }
            .sorted { ($0.maxY, -$0.minX) > ($1.maxY, -$1.minX) }
        guard cells.count >= 2 else {
            return Check.that("two gallery thumbnails to click between", false, "\(cells.count) on screen")
        }
        let first = NSPoint(x: cells[0].midX, y: cells[0].midY)
        let second = NSPoint(x: cells[1].midX, y: cells[1].midY)

        model.selectedIDs = []
        _ = await click(window, at: first, attempts: 2, settling: 1) { model.selectedIDs.count == 1 }
        let before = model.selectedIDs
        let moved = await click(window, at: second, attempts: 2, settling: 1) {
            model.selectedIDs.count == 1 && model.selectedIDs != before
        }
        Check.that("clicking another gallery thumbnail moves the selection to it",
                   before.count == 1 && moved,
                   "\(names(before, model)) → \(names(model.selectedIDs, model)), cells at \(first) and \(second)")

        let back = await click(window, at: first, attempts: 2, settling: 1) { model.selectedIDs == before }
        Check.that("and clicking the first again moves it back", back, names(model.selectedIDs, model))
        model.selectedIDs = []
    }

    private static func moveSelection(in window: NSWindow, host: NSView, _ model: AppModel,
                                      where place: String) async {
        guard let table = documentTable(in: host) else {
            return Check.that("\(place) shows the documents in a table", false, tables(in: host))
        }
        let ids = model.documents.map(\.id)

        model.selectedIDs = [ids[1]]
        let shown = await settle({ table.selectedRowIndexes == [1] }, timeout: 3)
        Check.that("\(place) shows a selection the model makes", shown,
                   "rows \(Array(table.selectedRowIndexes))")

        model.selectedIDs = []
        let first = await click(window, at: point(ofRow: 0, in: table), activating: true) {
            model.selectedIDs == [ids[0]]
        }
        Check.that("clicking a document in \(place) selects it", first, names(model.selectedIDs, model))

        let moved = await click(window, at: point(ofRow: 2, in: table), activating: true) {
            model.selectedIDs == [ids[2]]
        }
        Check.that("clicking another document in \(place) moves the selection to it", moved,
                   "\(names(model.selectedIDs, model)), table rows \(Array(table.selectedRowIndexes))")

        // Arrows go to whoever has the keyboard, which a click on the table
        // should have made the table.
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        Check.that("a click in \(place) gives the table the keyboard", window.firstResponder === table,
                   "first responder: \(responder)")
        model.selectedIDs = [ids[2]]
        _ = await settle({ table.selectedRowIndexes == [2] }, timeout: 3)
        let down = await press(.down, in: window) { model.selectedIDs == [ids[3]] }
        Check.that("↓ in \(place) moves the selection to the next document", down,
                   "\(names(model.selectedIDs, model)), table rows \(Array(table.selectedRowIndexes))")
        let up = await press(.up, in: window) { model.selectedIDs == [ids[2]] }
        Check.that("↑ in \(place) moves it back", up,
                   "\(names(model.selectedIDs, model)), table rows \(Array(table.selectedRowIndexes))")
    }

    private static func allTables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(allTables)
    }

    /// The centre pane's table: the only one with several columns, where the
    /// sidebar and the inspector have one.
    private static func documentTable(in view: NSView) -> NSTableView? {
        allTables(in: view).first { $0.numberOfColumns > 1 }
    }

    private static func tables(in view: NSView) -> String {
        let found = allTables(in: view).map {
            "\(type(of: $0)): \($0.numberOfRows) rows × \($0.numberOfColumns) columns"
        }
        return found.isEmpty ? "no tables" : found.joined(separator: "; ")
    }

    private static func sources(in view: NSView) -> [DocumentDragSource.SourceView] {
        ((view as? DocumentDragSource.SourceView).map { [$0] } ?? []) + view.subviews.flatMap(sources)
    }

    /// In window coordinates, on the row's name rather than its thumbnail.
    private static func point(ofRow row: Int, in table: NSTableView) -> NSPoint {
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.minX + min(140, rect.width / 2), y: rect.midY), to: nil)
    }

    private enum Arrow {
        case up, down

        var code: UInt16 { self == .up ? 126 : 125 }
        /// NSUpArrowFunctionKey and NSDownArrowFunctionKey.
        var characters: String { self == .up ? "\u{F700}" : "\u{F701}" }
    }

    /// Posted, so it goes where a real key press would: the key window's
    /// first responder.
    private static func press(_ arrow: Arrow, in window: NSWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0..<3 {
            NSApp.activate(ignoringOtherApps: true)
            _ = await settle({ NSApp.isActive }, timeout: 2)
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [.numericPad, .function],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: arrow.characters, charactersIgnoringModifiers: arrow.characters,
                    isARepeat: false, keyCode: arrow.code)
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            if await settle(condition, timeout: 2) { return true }
        }
        return false
    }

    private static func names(_ ids: Set<Int64>, _ model: AppModel) -> String {
        let names = model.documents.filter { ids.contains($0.id) }.map(\.filename)
        return names.isEmpty ? "nothing selected" : names.joined(separator: ", ")
    }
}
