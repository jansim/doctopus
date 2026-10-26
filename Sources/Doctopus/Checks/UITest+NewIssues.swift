import SwiftUI
import AppKit

extension UITest {
    static func folderCreationKeepsContext(_ model: AppModel) async {
        guard let lib = model.library, let row = model.documents.first else { return }
        let name = "New-folder-\(UUID().uuidString.prefix(6))"
        let folder = lib.root.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.selection = .all
        model.searchText = row.filename
        model.selectedIDs = [row.id]
        model.createFolder(named: name, in: lib.root)
        Check.that("creating a folder keeps the current view, search and document selection",
                   model.selection == .all && model.searchText == row.filename
                    && model.selectedIDs == [row.id] && FileManager.default.fileExists(atPath: folder.path))
        model.showInAllDocuments(row)
        let shown = await settle { model.documentToReveal == row.id }
        Check.that("Show in All Documents clears the search and keeps the document selected",
                   shown && model.selection == .all && model.searchText.isEmpty
                    && model.selectedIDs == [row.id] && model.documents.count > 1)
        model.documentToReveal = nil
        model.selectedIDs = []
    }

    static func windowMovesDoNotDragDocuments() {
        let source = DocumentDragSource.SourceView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 240),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: source.frame)
        content.addSubview(source)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { source.stopMonitoring(); window.orderOut(nil) }
        func send(_ type: NSEvent.EventType, at point: NSPoint) {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 1, clickCount: 1, pressure: 1) {
                _ = source.handle(event)
            }
        }
        send(.leftMouseDown, at: NSPoint(x: 100, y: window.contentLayoutRect.maxY + 5))
        Check.that("a titlebar press cannot arm a document drag", !source.isArmed)
        send(.leftMouseDown, at: NSPoint(x: 100, y: 100))
        let armed = source.isArmed
        window.setFrameOrigin(NSPoint(x: -4900, y: -4900))
        send(.leftMouseDragged, at: NSPoint(x: 110, y: 110))
        Check.that("moving the window cancels an armed document drag", armed && !source.isArmed)
    }
}
