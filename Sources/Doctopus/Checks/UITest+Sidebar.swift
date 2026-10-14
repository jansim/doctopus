import SwiftUI
import AppKit

/// The sidebar: both tag systems, and the folders ⌥ lights up.
extension UITest {
    static func sidebarShowsBothTagSystems(_ model: AppModel, snapshots: String?) async {
        guard let row = model.documents.first else { return }
        let originalFinderTags = FinderTags.entries(row.url)

        model.addTag("Receipts", to: [row])
        model.addFinderTag("Blue", to: [row])
        if let type = model.fields.first(where: { $0.key == "doc_type" }),
           let value = row.values["doc_type"] {
            model.setValueIcon(type, value: value, icon: "banknote")
        }
        let indexed = await settle {
            model.finderTags.contains { $0.value == "Blue" } && model.tags.contains { $0.name == "Receipts" }
        }
        Check.that("both tag systems reach the sidebar", indexed,
                   "own: \(model.tags.map(\.name)), finder: \(model.finderTags.map(\.value))")

        let (sidebarWindow, sidebar) = host(SidebarView().environment(model),
                                            size: NSSize(width: 260, height: 700))
        defer { sidebarWindow.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(sidebar, to: dir + "/sidebar.png") }
        Check.that("sidebar draws its sections", inkedRows(sidebar) > 20)

        model.listColumns[visibility: "tags"] = .visible
        model.listColumns[visibility: "finderTags"] = .visible
        let (listWindow, listHost) = host(DocumentListView().environment(model),
                                          size: NSSize(width: 900, height: 300))
        defer { listWindow.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(listHost, to: dir + "/list-tags.png") }

        FinderTags.write(originalFinderTags, to: row.url)
    }

    /// Driven through `revealingFolders`, which is what the ⌥ monitor sets:
    /// the checks have no keyboard to hold.
    static func optionRevealsFolders(_ model: AppModel) async {
        let rows = Array(model.documents.prefix(2))
        guard !rows.isEmpty else { return }
        defer { model.revealingFolders = false; model.selectedIDs = [] }

        model.selectedIDs = Set(rows.map(\.id))
        Check.that("nothing is pointed out before ⌥ is held", model.revealedFolders.isEmpty)
        model.revealingFolders = true
        let expected = Set(rows.map(\.directory))
        let lit = await settle { expected.isSubset(of: model.revealedFolders) }
        Check.that("⌥ points out every selected document's folder", lit,
                   "expected \(expected), got \(model.revealedFolders)")

        model.selectedIDs = []
        Check.that("and follows the selection while it is held", model.revealedFolders.isEmpty,
                   "\(model.revealedFolders)")
        model.selectedIDs = [rows[0].id]
        let back = await settle { model.revealedFolders.contains(rows[0].directory) }
        Check.that("including back onto a document", back)

        model.revealingFolders = false
        Check.that("letting go of ⌥ clears it", model.revealedFolders.isEmpty)
    }
}
