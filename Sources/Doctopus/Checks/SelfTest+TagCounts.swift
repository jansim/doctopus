import Foundation

extension SelfTest {
    /// A tag's number in the sidebar is how many documents clicking it lists,
    /// and stays so through every edit that changes either.
    static func tagCounts(store: Store) async {
        print("\nTAG COUNTS")
        impliedTagMigration()
        let live = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: true)) ?? []
        guard live.count >= 3 else {
            Check.that("three documents to count tags on", false, "\(live.count)"); return
        }
        let (a, b, c) = (live[0].doc, live[1].doc, live[2].doc)

        func counted(_ tag: Int64) async -> Int {
            ((try? await store.tags()) ?? []).first { $0.tagID == tag }?.count ?? -1
        }
        func listed(_ tag: Int64) async -> Int {
            ((try? await store.listDocuments(selection: .tag(tag), query: SearchQuery(""), sort: .added,
                                             ascending: true, limit: 100_000)) ?? []).count
        }
        /// Every tag in the library, not just the ones made here.
        func agree(_ after: String) async {
            var off: [String] = []
            for tag in (try? await store.tags()) ?? [] {
                let shown = await listed(tag.tagID)
                if shown != tag.count { off.append("\(tag.name) says \(tag.count), lists \(shown)") }
            }
            Check.that("every tag's count is what it lists \(after)", off.isEmpty,
                       off.joined(separator: "; "))
        }

        let parent = (try? await store.tagID(named: "Counted")) ?? 0
        let child = (try? await store.tagID(named: "Counted/Counted Child")) ?? 0
        let other = (try? await store.tagID(named: "Counted Other")) ?? 0
        try? await store.assign(tag: child, to: a)
        try? await store.assign(tag: child, to: b)
        try? await store.assign(tag: parent, to: c)
        try? await store.assign(tag: other, to: a)
        var parentCount = await counted(parent)
        var childCount = await counted(child)
        Check.that("a parent counts its own documents and its children's",
                   parentCount == 3 && childCount == 2, "parent \(parentCount), child \(childCount)")
        await agree("after tagging")

        try? await store.unassign(tag: child, from: b)
        parentCount = await counted(parent)
        let carried = (try? await store.tags(for: b)) ?? []
        Check.that("taking the child off takes the parent it implied off too",
                   parentCount == 2 && !carried.contains { $0.tagID == parent },
                   "parent \(parentCount), still on it: \(carried.map(\.name))")
        await agree("after untagging")

        try? await store.softDelete(a, trashPath: nil)
        parentCount = await counted(parent)
        childCount = await counted(child)
        Check.that("a document in Recently Deleted is not counted",
                   parentCount == 1 && childCount == 0, "parent \(parentCount), child \(childCount)")
        await agree("with a document deleted")
        try? await store.restore(a)
        await agree("once it is put back")

        _ = try? await store.setTagParent(child, to: nil)
        parentCount = await counted(parent)
        Check.that("moving a child out leaves its documents out of the old parent",
                   parentCount == 1, "parent \(parentCount)")
        await agree("after moving a tag out")
        _ = try? await store.setTagParent(child, to: parent)
        parentCount = await counted(parent)
        Check.that("…and moving it back brings them in again", parentCount == 2, "parent \(parentCount)")

        try? await store.assign(tag: other, to: b)
        _ = try? await store.renameTag(other, to: "Counted Child")
        parentCount = await counted(parent)
        childCount = await counted(child)
        Check.that("merging a tag into a child counts its documents under the parent",
                   childCount == 2 && parentCount == 3, "parent \(parentCount), child \(childCount)")
        await agree("after a merge")

        try? await store.deleteTag(child)
        parentCount = await counted(parent)
        Check.that("deleting a child keeps the documents it tagged under the parent",
                   parentCount == 3, "parent \(parentCount)")
        await agree("after deleting a tag")

        try? await store.deleteTag(parent)
        await agree("at the end")
    }

    /// Before v27 an ancestor attached by its child was only marked automatic,
    /// the same as a tag a rule or the model added.
    private static func impliedTagMigration() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-tags-v26-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = try? Database(path: path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        try? db.exec("""
        CREATE TABLE documents (id INTEGER PRIMARY KEY);
        INSERT INTO documents(id) VALUES (1), (2);
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL DEFAULT 0,
                           parent_id INTEGER REFERENCES tags(id) ON DELETE SET NULL);
        INSERT INTO tags(id, name, parent_id) VALUES (1, 'A', NULL), (2, 'B', 1), (3, 'C', 2), (4, 'Ruled', NULL);
        CREATE TABLE document_tags (
            doc_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            auto INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (doc_id, tag_id)
        );
        INSERT INTO document_tags(doc_id, tag_id, auto)
        VALUES (1, 3, 0), (1, 2, 1), (1, 1, 1), (1, 4, 1), (2, 1, 1);
        PRAGMA user_version=26;
        """)
        do { try Schema.migrate(db) } catch {
            Check.that("an index from before implied tags migrates", false, "\(error)"); return
        }
        let implied = (try? db.map("SELECT doc_id, tag_id FROM document_tags WHERE implied=1 ORDER BY doc_id, tag_id") {
            "\($0.int(0)):\($0.int(1))"
        }) ?? []
        Check.that("only the automatic tags above a document's own become implied",
                   implied == ["1:1", "1:2"], "\(implied)")
    }
}
