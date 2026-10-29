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
        view.count = { model.dragCount(from: row) }
        view.wholeTableRow = wholeTableRow
        view.onClick = onClick
        view.ended = { model.folderDropTarget = nil }
    }

    static func dismantleNSView(_ view: SourceView, coordinator: ()) { SourceMonitor.remove(view) }

    static func pasteboardItems(for rows: [DocumentRow]) -> [NSPasteboardItem] {
        rows.compactMap { row in
            guard let data = try? JSONEncoder().encode(DocumentDragItem(row)) else { return nil }
            let item = NSPasteboardItem()
            item.setString(row.url.absoluteString, forType: .fileURL)
            item.setData(data, forType: .init(UTType.doctopusDocument.identifier))
            return item
        }
    }

    /// The file's icon, badged with how many documents the drag carries when
    /// that is more than one, as `DocumentDragPreview` does.
    static func dragImage(for row: DocumentRow, count: Int) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: row.path)
        let size = NSSize(width: 48, height: 64)
        guard count > 1 else { return icon }
        return NSImage(size: size, flipped: false) { bounds in
            icon.draw(in: bounds.insetBy(dx: 0, dy: 8))
            let label = NSAttributedString(string: "\(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let width = max(22, label.size().width + 12)
            let badge = NSRect(x: bounds.maxX - width, y: bounds.maxY - 22, width: width, height: 22)
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 11, yRadius: 11).fill()
            label.draw(at: NSPoint(x: badge.midX - label.size().width / 2,
                                   y: badge.midY - label.size().height / 2))
            return true
        }
    }

    final class SourceView: NSView, NSDraggingSource {
        var rows: () -> [DocumentRow] = { [] }
        var count: () -> Int = { 1 }
        var ended: () -> Void = {}
        var onClick: ((NSEvent) -> Void)?
        private var down: NSPoint?
        private var startingRows: [DocumentRow] = []
        private var startingCount = 1
        var wholeTableRow = false

        // Native controls keep their normal hit testing. Gallery clicks and
        // movements past the drag threshold are handled by `SourceMonitor`.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { SourceMonitor.add(self) } else { SourceMonitor.remove(self) }
        }

        func reset() {
            down = nil
            startingRows = []
        }

        /// Whether a mouse-down at the event starts on this view. Native
        /// controls were ruled out by the monitor already.
        func claims(_ event: NSEvent) -> Bool {
            guard event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
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
            return visibleRect.contains(convert(event.locationInWindow, from: nil))
        }

        func begin(_ event: NSEvent) {
            down = convert(event.locationInWindow, from: nil)
            startingRows = rows()
            startingCount = count()
        }

        /// Nil when the event was used up here.
        func handle(_ event: NSEvent) -> NSEvent? {
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseUp:
                let wasClick = down != nil && !SourceMonitor.hitsNativeControl(event) && claims(event)
                reset()
                if wasClick, let onClick {
                    onClick(event)
                    return nil
                }
            case .leftMouseDragged:
                guard let start = down, hypot(point.x - start.x, point.y - start.y) >= 4 else { break }
                let selected = startingRows
                reset()
                let payloads = DocumentDragSource.pasteboardItems(for: selected)
                guard !payloads.isEmpty else { return event }
                let items = zip(selected, payloads).enumerated().map { index, pair in
                    let item = NSDraggingItem(pasteboardWriter: pair.1)
                    let image = index == 0
                        ? DocumentDragSource.dragImage(for: pair.0, count: startingCount)
                        : NSWorkspace.shared.icon(forFile: pair.0.path)
                    item.setDraggingFrame(NSRect(x: point.x + CGFloat(index * 4),
                                                 y: point.y + CGFloat(index * 4), width: 48, height: 64),
                                          contents: image)
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

/// One event monitor for every drag source on screen, rather than one per
/// row or cell: a mouse-down is offered to the sources once, and the one that
/// claims it follows the drag or click through to its end.
@MainActor
private enum SourceMonitor {
    static let sources = NSHashTable<DocumentDragSource.SourceView>.weakObjects()
    static var token: Any?
    static weak var active: DocumentDragSource.SourceView?

    static func add(_ view: DocumentDragSource.SourceView) {
        sources.add(view)
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            event in
            let consumed = MainActor.assumeIsolated { handle(event) == nil }
            return consumed ? nil : event
        }
    }

    static func remove(_ view: DocumentDragSource.SourceView) {
        view.reset()
        sources.remove(view)
        if active === view { active = nil }
        if sources.allObjects.isEmpty, let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }

    /// Native controls, such as the gallery's approval checkbox, keep their
    /// own click and tracking loop; the table itself is not one of them.
    static func hitsNativeControl(_ event: NSEvent) -> Bool {
        var hit = event.window?.contentView?.hitTest(event.locationInWindow)
        while let view = hit {
            if view is NSControl && !(view is NSTableView) { return true }
            hit = view.superview
        }
        return false
    }

    static func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            active?.reset()
            active = nil
            guard !hitsNativeControl(event),
                  let source = sources.allObjects.first(where: { $0.claims(event) }) else { return event }
            source.begin(event)
            active = source
            return event
        default:
            guard let source = active, source.window === event.window else { return event }
            let result = source.handle(event)
            if event.type == .leftMouseUp || result == nil { active = nil }
            return result
        }
    }
}
