import SwiftUI
import AppKit

/// Getting about the library without losing what is being looked at.
extension UITest {
    static func showInAllDocumentsKeepsTheSelection(_ model: AppModel) async {
        guard let row = model.documents.first(where: { !$0.isAliasHere && !$0.missing }) else {
            return Check.that("a document to show in all documents", false)
        }
        model.selection = .folder(row.directory)
        _ = await settle { model.documents.contains { $0.id == row.id } }
        model.selectedIDs = [row.id]
        model.showInAllDocuments([row])
        let shown = await settle {
            model.selection == .all && model.searchText.isEmpty
                && model.selectedIDs == [row.id] && model.documents.contains { $0.id == row.id }
        }
        Check.that("Show in All Documents leaves the folder and keeps the document selected",
                   shown, "selection \(model.selection), selected \(model.selectedIDs)")
        model.selectedIDs = []
    }

    static func creatingAFolderKeepsTheView(_ model: AppModel) async {
        guard let library = model.library else {
            return Check.that("a library to create a folder in", false)
        }
        model.selection = .all
        let name = "Created-\(UUID().uuidString.prefix(6))"
        let created = library.root.appendingPathComponent(name, isDirectory: true)
        model.createFolder(named: name, in: library.root)
        let exists = await settle { FileManager.default.fileExists(atPath: created.path) }
        Check.that("creating a folder leaves the current view selected",
                   exists && model.selection == .all, "selection \(model.selection)")
        try? FileManager.default.removeItem(at: created)
    }

    /// A filter carried into a folder it leaves empty is offered to be
    /// cleared there; a smart folder's query is the folder, so it is not.
    static func emptyFilteredFolderOffersToClear(_ model: AppModel, snapshots: String?) async {
        guard let row = model.documents.first(where: { !$0.isAliasHere && !$0.missing }) else {
            return Check.that("a document whose folder to filter", false)
        }
        let window = libraryWindow(model)
        defer { window.orderOut(nil) }
        model.selection = .folder(row.directory)
        // Until the folder's own list arrives, the one showing is All
        // Documents', which holds the row too; only a folder's list marks
        // what is merely aliased there.
        func folderListed() -> Bool {
            model.documents.contains { $0.id == row.id }
                && model.documents.allSatisfy { $0.directory == row.directory
                    || $0.directory.hasPrefix(row.directory + "/") || $0.isAliasHere }
        }
        _ = await settle(folderListed)
        let listed = model.documents.count
        model.searchText = "nothing-matches-\(UUID().uuidString.prefix(8))"
        let emptied = await settle { model.documents.isEmpty }
        try? await Task.sleep(for: .seconds(1))
        if let dir = snapshots, let view = window.contentView {
            snapshot(view, to: dir + "/empty-filtered-folder.png")
        }
        Check.that("a filter that leaves a folder empty can be cleared there",
                   emptied && model.canClearFilter, "\(model.documents.count) listed")

        model.clearFilter()
        let back = await settle { model.searchText.isEmpty && folderListed() && model.documents.count == listed }
        Check.that("clearing it lists the folder again, still in that folder",
                   back && model.selection == .folder(row.directory),
                   "\(model.documents.count) of \(listed), selection \(model.selection)")

        model.selection = .savedView(id: -1, query: "nothing-matches")
        Check.that("a smart folder's query is not offered to be cleared", !model.canClearFilter)
        model.selection = .all
        _ = await settle { model.searchText.isEmpty && !model.documents.isEmpty }
        yieldFocus()
    }
}
