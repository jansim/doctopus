import SwiftUI
import AppKit

extension UITest {
    /// Library › Metadata lists every value of the kind picked above it — not
    /// the sidebar's first fifty — and lists no documents while it is up.
    static func metadataPaneLists(_ model: AppModel, snapshots: String?) async {
        let name = "Listed in Metadata"
        model.createTag(named: name)
        guard await settle({ model.tags.contains { $0.name == name } }) else {
            Check.that("a tag for Metadata to list", false); return
        }

        let before = model.selection
        model.selection = .metadata
        let emptied = await settle({ model.documents.isEmpty }, timeout: 10)
        Check.that("the Metadata view lists no documents", emptied, "\(model.documents.count)")

        let (window, view) = host(MetadataView().environment(model), size: NSSize(width: 640, height: 420))
        for (kind, expected) in [("correspondent", (model.facets["correspondent"] ?? []).count),
                                 (MetadataKind.tags, model.tags.count)] {
            model.metadataKind = kind
            let shown = await settle({ tables(in: view).first?.numberOfRows == expected }, timeout: 10)
            if let dir = snapshots, kind == "correspondent" { snapshot(view, to: dir + "/metadata.png") }
            Check.that("Metadata lists every \(kind == MetadataKind.tags ? "tag" : kind)",
                       shown && expected > 0,
                       "\(tables(in: view).first?.numberOfRows ?? -1) rows of \(expected)")
        }
        window.orderOut(nil)

        // The checks after this one count the documents listed when they
        // start, so the list has to be back before handing over.
        model.metadataKind = MetadataKind.tags
        if let tag = model.tags.first(where: { $0.name == name }) { model.deleteTag(tag) }
        model.selection = before
        _ = await settle({ !model.documents.isEmpty && !model.tags.contains { $0.name == name } },
                         timeout: 10)
    }
}
