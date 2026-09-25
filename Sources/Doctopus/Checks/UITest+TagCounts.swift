import Foundation

extension UITest {
    /// The sidebar's number next to a tag follows hand edits, and is what
    /// clicking the tag lists.
    static func tagCountsFollowEdits(_ model: AppModel) async {
        let rows = Array(model.documents.prefix(2))
        guard rows.count == 2 else { Check.that("two documents to tag", false); return }
        let before = model.selection
        defer { model.selection = before }

        model.addTag("Sidebar Count/Sidebar Count Child", to: rows)
        func count(_ name: String) -> Int? { model.tags.first { $0.name == name }?.count }
        func shown() -> String {
            "parent \(count("Sidebar Count").map { "\($0)" } ?? "none"), "
                + "child \(count("Sidebar Count Child").map { "\($0)" } ?? "none")"
        }
        let tagged = await settle { count("Sidebar Count Child") == 2 && count("Sidebar Count") == 2 }
        Check.that("tagging two documents with a nested tag counts two on it and its parent",
                   tagged, shown())

        guard let parent = model.tags.first(where: { $0.name == "Sidebar Count" }),
              let child = model.tags.first(where: { $0.name == "Sidebar Count Child" }) else { return }
        model.selection = .tag(parent.id)
        let wanted = Set(rows.map(\.id))
        let listed = await settle { Set(model.documents.map(\.id)) == wanted }
        Check.that("clicking the parent lists the documents it counts", listed,
                   "\(model.documents.count) listed")

        model.removeTag(child, from: [rows[0]])
        let followed = await settle {
            count("Sidebar Count") == 1 && count("Sidebar Count Child") == 1
                && model.documents.map(\.id) == [rows[1].id]
        }
        Check.that("taking the child off one document takes one off both counts, and the list",
                   followed, shown() + ", \(model.documents.count) listed")

        model.deleteTag(child)
        model.deleteTag(parent)
        _ = await settle { count("Sidebar Count") == nil }
    }
}
