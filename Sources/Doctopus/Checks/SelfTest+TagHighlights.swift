import Foundation

extension SelfTest {
    /// Whether a tag shows on thumbnails lives on its row, like its icon, so
    /// it reaches the document rows the gallery draws and survives a merge.
    static func tagHighlights(store: Store) async {
        print("\nTAG HIGHLIGHTS")
        tagHighlightMigration()

        func highlighted(_ id: Int64) async -> Bool? {
            ((try? await store.tags()) ?? []).first { $0.tagID == id }?.highlighted
        }
        let tag = (try? await store.tagID(named: "Highlit")) ?? 0
        let fresh = await highlighted(tag)
        Check.that("a new tag is not highlighted", fresh == false)

        try? await store.setTagHighlighted(tag, true)
        let picked = await highlighted(tag)
        Check.that("highlighting a tag is stored on it", picked == true)

        let live = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: true, limit: 1)) ?? []
        if let doc = live.first?.doc {
            try? await store.assign(tag: tag, to: doc)
            let carried = (try? await store.tags(for: doc)) ?? []
            let batched = (try? await store.tags(forDocuments: [doc]))?.own[doc] ?? []
            Check.that("a document's tags say which are highlighted, for the thumbnails",
                       Tag.highlighted(in: carried).contains { $0.tagID == tag }
                           && Tag.highlighted(in: batched).contains { $0.tagID == tag })
            try? await store.unassign(tag: tag, from: doc)
        }

        let other = (try? await store.tagID(named: "Highlit Other")) ?? 0
        let survivor = (try? await store.renameTag(other, to: "Highlit")) ?? 0
        let kept = await highlighted(tag)
        Check.that("merging into a highlighted tag keeps it highlighted",
                   survivor == tag && kept == true)

        let plain = (try? await store.tagID(named: "Highlit Plain")) ?? 0
        let donor = (try? await store.tagID(named: "Highlit Donor")) ?? 0
        try? await store.setTagHighlighted(donor, true)
        _ = try? await store.renameTag(donor, to: "Highlit Plain")
        let taken = await highlighted(plain)
        Check.that("merging a highlighted tag into another highlights the survivor", taken == true)

        try? await store.setTagHighlighted(tag, false)
        let cleared = await highlighted(tag)
        Check.that("a highlight can be taken off again", cleared == false)

        for id in [plain, tag] { try? await store.deleteTag(id) }
    }

    private static func tagHighlightMigration() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-tags-v31-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = try? Database(path: path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        try? db.exec("""
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL DEFAULT 0,
                           parent_id INTEGER REFERENCES tags(id) ON DELETE SET NULL, icon TEXT);
        INSERT INTO tags(id, name, color, icon) VALUES (1, 'Kept', 3, 'star');
        PRAGMA user_version=31;
        """)
        do { try Schema.migrate(db) } catch {
            Check.that("an index from before tag highlights migrates", false, "\(error)"); return
        }
        let rows = (try? db.map("SELECT name, color, icon, highlighted FROM tags") {
            "\($0.string(0)) \($0.int(1)) \($0.stringOrNil(2) ?? "default") \($0.int(3))"
        }) ?? []
        Check.that("existing tags keep what they had and start not highlighted",
                   rows == ["Kept 3 star 0"], "\(rows)")
    }
}
