import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AppKit needs one dragging item per file to export a selection to other apps.
struct DocumentDragSource: NSViewRepresentable {
    let row: DocumentRow
    let model: AppModel
    var wholeTableRow = false
    var onClick: ((NSEvent) -> Void)?

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.rows = { model.selectedIDs.contains(row.id) ? model.selectedRows : [row] }
        view.wholeTableRow = wholeTableRow
        view.onClick = onClick
        view.ended = { model.folderDropTarget = nil }
    }

    static func dismantleNSView(_ view: SourceView, coordinator: ()) { view.stopMonitoring() }

    @MainActor
    static func containsDocumentClick(_ event: NSEvent?) -> Bool {
        guard let event, let root = event.window?.contentView else { return false }
        func contains(_ view: NSView) -> Bool {
            if let source = view as? SourceView, !source.wholeTableRow,
               !source.isHiddenOrHasHiddenAncestor,
               source.visibleRect.contains(source.convert(event.locationInWindow, from: nil)) {
                return true
            }
            return view.subviews.contains(where: contains)
        }
        return contains(root)
    }

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
        var onClick: ((NSEvent) -> Void)?
        private var monitor: Any?
        private var down: NSPoint?
        private var startingRows: [DocumentRow] = []
        var wholeTableRow = false

        // Native controls keep their normal hit testing. Gallery clicks and
        // movements past the drag threshold are handled by the event monitor.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
                [weak self] event in
                guard let self else { return event }
                let consumed = MainActor.assumeIsolated { self.handle(event) == nil }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            down = nil
            startingRows = []
        }

        private func containsStart(_ event: NSEvent, point: NSPoint) -> Bool {
            guard !isHiddenOrHasHiddenAncestor else { return false }
            // Native controls, such as the gallery's approval checkbox, keep
            // their own click and tracking loop.
            var hit = window?.contentView?.hitTest(event.locationInWindow)
            while let view = hit {
                if view is NSControl && !(view is NSTableView) { return false }
                hit = view.superview
            }
            if wholeTableRow {
                var ancestor = superview
                while let view = ancestor {
                    if let table = view as? NSTableView {
                        let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: table)
                        let offered = table.convert(event.locationInWindow, from: nil)
                        let row = table.row(at: center)
                        return row >= 0 && table.visibleRect.contains(offered) && table.row(at: offered) == row
                    }
                    ancestor = view.superview
                }
            }
            return visibleRect.contains(point)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                down = containsStart(event, point: point) ? point : nil
                startingRows = down == nil ? [] : rows()
            case .leftMouseUp:
                let wasClick = down != nil && containsStart(event, point: point)
                down = nil
                startingRows = []
                if wasClick, let onClick {
                    onClick(event)
                    return nil
                }
            case .leftMouseDragged:
                guard let start = down, hypot(point.x - start.x, point.y - start.y) >= 4 else { break }
                down = nil
                let selected = startingRows
                startingRows = []
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
