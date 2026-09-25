import SwiftUI
import AppKit

extension UITest {
    /// The review checkbox belongs to Needs Review; what is already reviewed has nothing to tick.
    static func recentlyReviewedHasNoCheckboxes(_ model: AppModel, snapshots: String?) async {
        let before = model.selection, mode = model.viewMode
        defer { model.selection = before; model.viewMode = mode }
        model.viewMode = .list

        var checkboxes: [String: Int] = [:]
        let panes: [(String, Selection)] = [("Needs Review", .needsReview), ("Recently Reviewed", .reviewed)]
        for (name, selection) in panes {
            model.selection = selection
            // Until the list reloads it still shows the last pane's rows.
            let listed = await settle({
                let rows = model.documents
                guard !rows.isEmpty, rows.allSatisfy({ $0.queue != nil }) else { return false }
                return selection == .reviewed ? rows.allSatisfy { $0.queue?.approved == true }
                                              : rows.contains { $0.queue?.approved == false }
            }, timeout: 10)
            guard listed else { continue }
            let (window, view) = host(DocumentListView().environment(model), size: NSSize(width: 900, height: 660))
            try? await Task.sleep(for: .seconds(2))
            if let dir = snapshots, selection == .reviewed { snapshot(view, to: dir + "/recently-reviewed.png") }
            checkboxes[name] = tables(in: view).reduce(0) { $0 + buttons(in: $1).count }
            window.orderOut(nil)
        }
        let said = checkboxes.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        Check.that("Recently Reviewed lists its documents", checkboxes["Recently Reviewed"] != nil, said)
        // Needs Review may have been worked through by now; when it has not, it shows what a checkbox is.
        Check.that("its documents carry no review checkbox, as Needs Review's do",
                   checkboxes["Recently Reviewed"] == 0 && (checkboxes["Needs Review"].map { $0 > 0 } ?? true),
                   said)
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap { tables(in: $0) }
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }
}
