import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// SwiftUI's gallery drag exports one Transferable, even when its preview
/// counts a selection. AppKit needs one dragging item per file for other apps.
struct DocumentDragSource: NSViewRepresentable {
    let row: DocumentRow
    let model: AppModel

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.rows = { model.selectedIDs.contains(row.id) ? model.selectedRows : [row] }
        view.ended = { model.folderDropTarget = nil }
    }

    static func dismantleNSView(_ view: SourceView, coordinator: ()) { view.stopMonitoring() }

    static func pasteboardItems(for rows: [DocumentRow]) -> [NSPasteboardItem] {
        rows.compactMap { row in
            guard let data = try? JSONEncoder().encode(DocumentDragItem(row)) else { return nil }
            let item = NSPasteboardItem()
            item.setString(row.url.absoluteString, forType: .fileURL)
            item.setData(data, forType: .init(UTType.doctopusDocument.identifier))
            return item
        }
    }

    final class SourceView: NSView, NSDraggingSource {
        var rows: () -> [DocumentRow] = { [] }
        var ended: () -> Void = {}
        private var monitor: Any?
        private var down: NSPoint?

        // The gallery keeps receiving clicks, including modifier clicks and
        // double-clicks. Only a movement past the drag threshold is taken.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
                [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            down = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                down = bounds.contains(point) && !isHiddenOrHasHiddenAncestor ? point : nil
            case .leftMouseUp:
                down = nil
            case .leftMouseDragged:
                guard let start = down, hypot(point.x - start.x, point.y - start.y) >= 4 else { break }
                down = nil
                let selected = rows()
                let payloads = DocumentDragSource.pasteboardItems(for: selected)
                guard !payloads.isEmpty else { return event }
                let items = zip(selected, payloads).enumerated().map { index, pair in
                    let item = NSDraggingItem(pasteboardWriter: pair.1)
                    item.setDraggingFrame(NSRect(x: point.x + CGFloat(index * 4),
                                                 y: point.y + CGFloat(index * 4), width: 48, height: 64),
                                          contents: NSWorkspace.shared.icon(forFile: pair.0.path))
                    return item
                }
                let session = beginDraggingSession(with: items, event: event, source: self)
                session.draggingFormation = .pile
                return nil
            default: break
            }
            return event
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? [.copy, .move] : .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            ended()
        }
    }
}
