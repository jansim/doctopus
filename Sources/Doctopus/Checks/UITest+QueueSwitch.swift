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

            print("  · into Needs Review in the \(viewMode)")
            model.selection = .needsReview
            let listed = await settle({ model.documents.contains { $0.doc == subject.doc } }, timeout: 10)
            try? await Task.sleep(for: .seconds(1))
            Check.that("switching into Needs Review in the \(viewMode) lists what waits there", listed,
                       "\(model.documents.count) documents")

            print("  · selecting in Needs Review in the \(viewMode)")
            model.selectedIDs = [subject.id]
            let reviewing = await settle({ model.detail?.row.id == subject.id }, timeout: 10)
            try? await Task.sleep(for: .seconds(1))
            Check.that("a document selected there opens in the review panel (\(viewMode))", reviewing)
            if let dir = snapshots, let view = window.contentView {
                snapshot(view, to: dir + "/needs-review-switch-\(viewMode).png")
            }

            print("  · back out of Needs Review in the \(viewMode)")
            model.selection = .reviewed
            try? await Task.sleep(for: .seconds(1))
            model.selection = .all
            try? await Task.sleep(for: .seconds(1))
            model.selection = .needsReview
            try? await Task.sleep(for: .seconds(1))
            Check.that("Needs Review can be left and entered again (\(viewMode))", true)
            window.orderOut(nil)
            model.selectedIDs = []
        }
        try? await store.setDocumentApproved(subject.doc, subject.approved)
        model.refreshAll()
        yieldFocus()
    }
}
