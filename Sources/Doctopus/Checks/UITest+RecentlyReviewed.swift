import SwiftUI
import AppKit

extension UITest {
    /// The review checkbox belongs to Needs Review; what is already reviewed has nothing to tick.
    static func recentlyReviewedHasNoCheckboxes(_ model: AppModel, snapshots: String?) async {
        let before = model.selection, mode = model.viewMode
        defer { model.selection = before; model.viewMode = mode }
        model.viewMode = .list
        guard let store = model.library?.store, let subject = model.documents.first else {
            Check.that("a document to review", false)
            return
        }
        // One document through both panes, so each has something to show.
        try? await store.setDocumentApproved(subject.doc, false)

        var checkboxes: [String: Int] = [:]
        let panes: [(String, Selection)] = [("Needs Review", .needsReview), ("Recently Reviewed", .reviewed)]
        for (name, selection) in panes {
            if selection == .reviewed { try? await store.setDocumentApproved(subject.doc, true) }
            model.selection = selection
            model.refreshAll()
            // Until the list reloads it still shows the last pane's rows.
            let approved = selection == .reviewed
            let listed = await settle({
                model.documents.contains { $0.doc == subject.doc && $0.queue?.approved == approved }
            }, timeout: 10)
            guard listed else { continue }
            let (window, view) = host(DocumentListView().environment(model), size: NSSize(width: 900, height: 660))
            try? await Task.sleep(for: .seconds(2))
            if let dir = snapshots, selection == .reviewed { snapshot(view, to: dir + "/recently-reviewed.png") }
            checkboxes[name] = tables(in: view).reduce(0) { $0 + buttons(in: $1).count }
            window.orderOut(nil)
        }
        try? await store.setDocumentApproved(subject.doc, subject.approved)
        model.refreshAll()
        let said = checkboxes.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        Check.that("Needs Review's documents carry a review checkbox", (checkboxes["Needs Review"] ?? 0) > 0, said)
        Check.that("Recently Reviewed's carry none", checkboxes["Recently Reviewed"] == 0, said)
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap { tables(in: $0) }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }
}
