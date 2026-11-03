import SwiftUI
import AppKit

/// Going into Needs Review from another pane while the window is on screen,
/// which turns the browser into a split with the review panel under it and
/// adds the queue's columns to a table that is already showing.
extension UITest {
    static func switchingIntoNeedsReviewDraws(_ model: AppModel, snapshots: String?) async {
        let before = model.selection, mode = model.viewMode, columns = model.listColumns
        defer { model.selection = before; model.viewMode = mode; model.listColumns = columns }
        guard let store = model.library?.store, let subject = model.documents.first else {
            return Check.that("a document to wait in Needs Review", false)
        }
        try? await store.setDocumentApproved(subject.doc, false)

        for viewMode in [ViewMode.list, .gallery] {
            model.viewMode = viewMode
            model.selection = .all
            model.selectedIDs = []
            model.refreshAll()
            let window = libraryWindow(model)
            try? await Task.sleep(for: .seconds(2))

            if viewMode == .list {
                print("  · rearranging the columns of All Documents")
                rearrangeColumns(in: window)
                try? await Task.sleep(for: .seconds(1))
            }

            print("  · into Needs Review in the \(viewMode), from the sidebar")
            let clicked = await clickSidebar(window, model, to: .needsReview)
            let listed = await settle({ model.documents.contains { $0.doc == subject.doc } }, timeout: 10)
            try? await Task.sleep(for: .seconds(1))
            Check.that("a click on Needs Review in the sidebar opens it (\(viewMode))", clicked,
                       "selection \(model.selection)")
            Check.that("switching into Needs Review in the \(viewMode) lists what waits there", listed,
                       "\(model.documents.count) documents")

            if viewMode == .list {
                print("  · rearranging the columns of Needs Review")
                rearrangeColumns(in: window)
                try? await Task.sleep(for: .seconds(1))
            }

            print("  · selecting in Needs Review in the \(viewMode)")
            model.selectedIDs = [subject.id]
            let reviewing = await settle({ model.detail?.row.id == subject.id }, timeout: 10)
            try? await Task.sleep(for: .seconds(1))
            Check.that("a document selected there opens in the review panel (\(viewMode))", reviewing)
            if let dir = snapshots, let view = window.contentView {
                snapshot(view, to: dir + "/needs-review-switch-\(viewMode).png")
            }

            let others: [Selection] = [.reviewed, .all, .metadata, .folder(subject.directory), .untagged]
            for other in others {
                print("  · from \(other) back into Needs Review in the \(viewMode)")
                model.selection = other
                try? await Task.sleep(for: .seconds(1))
                _ = await clickSidebar(window, model, to: .needsReview)
                try? await Task.sleep(for: .seconds(1))
            }
            Check.that("Needs Review can be left and entered again (\(viewMode))", model.selection == .needsReview,
                       "selection \(model.selection)")
            window.orderOut(nil)
            model.selectedIDs = []
        }
        try? await store.setDocumentApproved(subject.doc, subject.approved)
        model.refreshAll()
        yieldFocus()
    }

    /// Clicks the sidebar row for Needs Review, the second under Library.
    private static func clickSidebar(_ window: NSWindow, _ model: AppModel, to target: Selection) async -> Bool {
        guard let outline = outlines(in: window.contentView).first else {
            model.selection = target
            return false
        }
        // Row 0 is the Library heading, then All Documents, then Needs Review.
        let rect = outline.rect(ofRow: 2)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let clicked = await click(window, at: point, attempts: 3, settling: 2, activating: true) {
            model.selection == target
        }
        if !clicked { model.selection = target }
        return clicked
    }

    /// What a person does to the table over time: a column dragged elsewhere, another resized.
    private static func rearrangeColumns(in window: NSWindow) {
        guard let table = tables(in: window.contentView ?? NSView()).max(by: { $0.numberOfColumns < $1.numberOfColumns }),
              table.numberOfColumns >= 3 else { return }
        table.moveColumn(table.numberOfColumns - 2, toColumn: 1)
        let column = table.tableColumns[table.numberOfColumns - 1]
        column.width = max(column.minWidth, column.width + 30)
        if table.numberOfColumns > 2 {
            let second = table.tableColumns[2]
            second.width = max(second.minWidth, second.width + 40)
        }
    }

    private static func outlines(in view: NSView?) -> [NSOutlineView] {
        guard let view else { return [] }
        return ((view as? NSOutlineView).map { [$0] } ?? []) + view.subviews.flatMap { outlines(in: $0) }
    }
}
