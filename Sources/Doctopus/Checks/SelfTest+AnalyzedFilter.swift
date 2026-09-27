import Foundation

/// Finding documents by whether, and when, a model analyzed them.
extension SelfTest {
    static func analyzedFilter(store: Store) async {
        print("\nANALYZED FILTER")
        analyzedMigration()

        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        guard let sample = rows.first else {
            Check.that("a document to analyze is there", false); return
        }
        func finds(_ query: String) async -> Bool {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(query),
                                                       sort: .added, ascending: false)) ?? []
            return hits.contains { $0.doc == sample.doc }
        }

        try? await store.discardGeneratedInfo(sample.doc)
        var analyzed = await finds("is:analyzed"), unanalyzed = await finds("is:unanalyzed")
        Check.that("a document no model answered for is unanalyzed", unanalyzed && !analyzed)
        try? await store.storeMetadata(Store.MetadataPatch(docID: sample.doc, source: "heuristic"))
        unanalyzed = await finds("is:unanalyzed")
        Check.that("what heuristics read off it does not count as analyzed", unanalyzed)

        try? await store.storeMetadata(Store.MetadataPatch(
            docID: sample.doc, title: sample.title, source: "remote:test-model:v\(MetadataSource.promptVersion)"))
        analyzed = await finds("is:analyzed")
        unanalyzed = await finds("is:unanalyzed")
        let notAnalyzed = await finds("-is:analyzed")
        Check.that("a model's answer makes it analyzed", analyzed && !unanalyzed && !notAnalyzed)
        let today = await finds("analyzed:today"), yesterday = await finds("analyzed:yesterday")
        let notToday = await finds("-analyzed:today")
        Check.that("it is found by the day it was analyzed", today && !yesterday && !notToday)

        try? await store.storeMetadata(Store.MetadataPatch(docID: sample.doc, correspondent: sample.correspondent,
                                                           source: "rule"))
        analyzed = await finds("is:analyzed")
        Check.that("a rule setting a field later keeps it analyzed", analyzed)

        try? await store.discardGeneratedInfo(sample.doc)
        unanalyzed = await finds("is:unanalyzed")
        let stillToday = await finds("analyzed:today")
        Check.that("discarding what was worked out makes it unanalyzed again", unanalyzed && !stillToday)
    }

    private static func analyzedMigration() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-analyzed-v28-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = try? Database(path: path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        try? db.exec("""
        CREATE TABLE documents (id INTEGER PRIMARY KEY, created_at REAL NOT NULL);
        CREATE TABLE metadata (doc_id INTEGER PRIMARY KEY, source TEXT);
        CREATE TABLE events (id INTEGER PRIMARY KEY, doc_id INTEGER NOT NULL, at REAL NOT NULL, action TEXT NOT NULL);
        INSERT INTO documents(id, created_at) VALUES (1, 100), (2, 200), (3, 300), (4, 400);
        INSERT INTO metadata(doc_id, source) VALUES (1, 'rule'), (2, 'llm:v5'), (3, 'heuristic'), (4, 'vlm:qwen:v5');
        INSERT INTO events(doc_id, at, action) VALUES (1, 150, 'analyzed'), (1, 160, 'renamed'), (4, 450, 'indexed');
        PRAGMA user_version=28;
        """)
        do { try Schema.migrate(db) } catch {
            Check.that("an index from before analysis dates migrates", false, "\(error)"); return
        }
        let rows = (try? db.map("SELECT doc_id, analyzed_at FROM metadata ORDER BY doc_id") {
            "\($0.int(0)):\($0.intOrNil(1).map(String.init) ?? "-")"
        }) ?? []
        Check.that("earlier analyses are dated by their event, else by indexing or when added",
                   rows == ["1:150", "2:200", "3:-", "4:450"], "\(rows)")
    }
}
