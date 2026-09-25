import Foundation

extension SelfTest {
    /// A tag's icon lives on its row, so it has to come through everything
    /// that keeps the row: a rename, a move to another parent, and a merge.
    static func tagIcons(store: Store) async {
        print("\nTAG ICONS")
        tagIconMigration()

        func icon(_ id: Int64) async -> String? {
            ((try? await store.tags()) ?? []).first { $0.tagID == id }?.icon
        }
        let parent = (try? await store.tagID(named: "Iconic Parent")) ?? 0
        let tag = (try? await store.tagID(named: "Iconic")) ?? 0
        let fresh = await icon(tag)
        Check.that("a new tag has no icon of its own", fresh == nil)

        try? await store.setTagIcon(tag, "star")
        let picked = await icon(tag)
        Check.that("a picked icon is stored on the tag", picked == "star")

        _ = try? await store.renameTag(tag, to: "Iconic Renamed")
        let renamed = await icon(tag)
        Check.that("renaming a tag keeps its icon", renamed == "star")

        _ = try? await store.setTagParent(tag, to: parent)
        let nested = ((try? await store.tags()) ?? []).first { $0.tagID == tag }
        Check.that("moving a tag under another keeps its icon",
                   nested?.parentID == parent && nested?.icon == "star")

        let live = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: true, limit: 1)) ?? []
        if let doc = live.first?.doc {
            try? await store.assign(tag: tag, to: doc)
            let carried = (try? await store.tags(for: doc)) ?? []
            let batched = (try? await store.tags(forDocuments: [doc]))?.own[doc] ?? []
            Check.that("a document's tags carry their icons, for the pills",
                       carried.first { $0.tagID == tag }?.icon == "star"
                           && batched.first { $0.tagID == tag }?.icon == "star",
                       carried.map { "\($0.name)=\($0.icon ?? "-")" }.joined(separator: ", "))
            try? await store.unassign(tag: tag, from: doc)
        }

        let other = (try? await store.tagID(named: "Iconic Other")) ?? 0
        try? await store.setTagIcon(other, "flag")
        let survivor = (try? await store.renameTag(other, to: "Iconic Renamed")) ?? 0
        let kept = await icon(tag)
        Check.that("merging into a tag with an icon keeps the survivor's",
                   survivor == tag && kept == "star", kept ?? "none")

        let plain = (try? await store.tagID(named: "Iconic Plain")) ?? 0
        let donor = (try? await store.tagID(named: "Iconic Donor")) ?? 0
        try? await store.setTagIcon(donor, "leaf")
        _ = try? await store.renameTag(donor, to: "Iconic Plain")
        let taken = await icon(plain)
        Check.that("merging into a tag without one takes the merged tag's icon",
                   taken == "leaf", taken ?? "none")

        try? await store.setTagIcon(tag, "  ")
        let cleared = await icon(tag)
        Check.that("a blank icon goes back to the default", cleared == nil)

        for id in [plain, tag, parent] { try? await store.deleteTag(id) }
    }

    private static func tagIconMigration() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-tags-v26-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = try? Database(path: path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        try? db.exec("""
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL DEFAULT 0,
                           parent_id INTEGER REFERENCES tags(id) ON DELETE SET NULL);
        INSERT INTO tags(id, name, color) VALUES (1, 'Kept', 3);
        PRAGMA user_version=26;
        """)
        do { try Schema.migrate(db) } catch {
            Check.that("an index from before tag icons migrates", false, "\(error)"); return
        }
        let rows = (try? db.map("SELECT name, color, icon FROM tags") {
            "\($0.string(0)) \($0.int(1)) \($0.stringOrNil(2) ?? "default")"
        }) ?? []
        Check.that("existing tags keep what they had and start on the default icon",
                   rows == ["Kept 3 default"], "\(rows)")
    }
}
