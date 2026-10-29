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
}
