import Foundation

/// What a review approved, or a hand set, belongs to the document: reading
/// the file again later only fills in what is still blank.
extension SelfTest {
    static func settledMetadata(store: Store, indexer: Indexer, rows: [DocumentRow]) async {
        print("\nSETTLED METADATA")
        mistakenDateRepair()
        var subjects: [(row: DocumentRow, dateSource: String)] = []
        for row in rows where row.docDate != nil && FileManager.default.fileExists(atPath: row.path) {
            guard let detail = try? await store.detail(row.doc), let source = detail.dateSource,
                  !["manual", "fs"].contains(source) else { continue }
            subjects.append((row, source))
            if subjects.count == 2 { break }
        }
        guard subjects.count == 2 else {
            Check.that("two documents with a date read off them", false, "\(subjects.count)")
            return
        }
        let (edited, editedSource) = subjects[0]
        let approved = subjects[1].row

        // Approved, its date then corrected by hand, and a rule change later
        // sending it back to review, where the file is read again.
        let handSet = DayDate.calendar.date(from: DateComponents(year: 2001, month: 2, day: 3))!
        try? await store.setDocumentApproved(edited.doc, true)
        try? await store.setDocumentDate(edited.doc, handSet)
        try? await store.logProcessing(docID: edited.doc, action: .routed, detail: "Rule update",
                                       rule: "Settled check", from: nil, to: nil, approved: false)
        await indexer.reprocess(ids: [edited.doc])
        let reread = try? await store.detail(edited.doc)
        Check.that("a date set by hand survives the document being read again",
                   reread?.row.docDate == handSet && reread?.dateSource == "manual",
                   "\(reread?.row.docDate.map(DayDate.text) ?? "no date") (\(reread?.dateSource ?? "—"))")

        try? await store.overwriteMetadataField(approved.doc, column: "title", value: "Settled in review")
        try? await store.setDocumentApproved(approved.doc, true)
        Check.that("approving forgets the other dates the extraction offered",
                   ((try? await store.dateCandidates(for: approved.doc)) ?? []).isEmpty)
        try? await store.logProcessing(docID: approved.doc, action: .routed, detail: "Rule update",
                                       rule: "Settled check", from: nil, to: nil, approved: false)
        await indexer.reprocess(ids: [approved.doc])
        let settled = try? await store.detail(approved.doc)
        Check.that("what was approved is not replaced when the document is read again",
                   settled?.row.title == "Settled in review"
                       && settled?.row.docDate == approved.docDate,
                   "\(settled?.row.title ?? "no title"), \(settled?.row.docDate.map(DayDate.text) ?? "no date")")
        Check.that("…nor are the dates it offered brought back",
                   ((try? await store.dateCandidates(for: approved.doc)) ?? []).isEmpty)

        try? await store.discardGeneratedInfo(approved.doc)
        await indexer.reprocess(ids: [approved.doc])
        let refilled = try? await store.detail(approved.doc)
        Check.that("…but what was thrown away is filled in again",
                   refilled?.row.title?.nilIfBlank != nil && refilled?.row.docDate != nil,
                   "\(refilled?.row.title ?? "no title"), \(refilled?.row.docDate.map(DayDate.text) ?? "no date")")

        // Put them back as they were, so later sections see the library they expect.
        try? await store.setDocumentDate(edited.doc, edited.docDate, source: editedSource)
        try? await store.overwriteMetadataField(approved.doc, column: "title", value: approved.title)
        for row in [edited, approved] {
            try? await store.setDocumentApproved(row.doc, row.approved)
        }
    }

    /// The date field once saved 1 January 2001 for every document it showed.
    private static func mistakenDateRepair() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-dates-v29-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let db = try? Database(path: path) else {
            Check.that("a database in the old shape can be opened", false); return
        }
        try? db.exec("""
        CREATE TABLE documents (id INTEGER PRIMARY KEY, created_at REAL NOT NULL, reviewed_at REAL);
        CREATE TABLE metadata (doc_id INTEGER PRIMARY KEY, doc_date REAL, date_source TEXT);
        CREATE TABLE date_candidates (doc_id INTEGER NOT NULL, date REAL NOT NULL, source TEXT NOT NULL,
                                      labelled INTEGER NOT NULL DEFAULT 0, cue TEXT, rank INTEGER NOT NULL,
                                      PRIMARY KEY (doc_id, date));
        CREATE TABLE events (id INTEGER PRIMARY KEY, doc_id INTEGER NOT NULL, at REAL NOT NULL,
                             action TEXT NOT NULL, detail TEXT);
        INSERT INTO documents(id, created_at) VALUES (1, 0), (2, 0), (3, 0), (4, 0);
        INSERT INTO metadata(doc_id, doc_date, date_source) VALUES
            (1, 978307200, 'manual'), (2, 978307200, 'manual'), (3, 1700006400, 'manual'), (4, 978307200, 'ocr');
        INSERT INTO date_candidates(doc_id, date, source, rank) VALUES
            (1, 1699920000, 'ocr', 0), (1, 1600000000, 'filename', 1);
        PRAGMA user_version=29;
        """)
        do { try Schema.migrate(db) } catch {
            Check.that("an index with mistaken dates migrates", false, "\(error)"); return
        }
        let rows = (try? db.map("SELECT doc_id, doc_date, date_source FROM metadata ORDER BY doc_id") {
            "\($0.int(0)):\($0.intOrNil(1).map(String.init) ?? "-"):\($0.stringOrNil(2) ?? "-")"
        }) ?? []
        Check.that("a mistaken 1 Jan 2001 goes back to the date the text gave, or to none",
                   rows.prefix(2) == ["1:1699920000:ocr", "2:-:-"], "\(rows)")
        Check.that("…and any other date, by hand or read off the file, is left alone",
                   rows.suffix(2) == ["3:1700006400:manual", "4:978307200:ocr"], "\(rows)")
        let logged = (try? db.map("SELECT doc_id FROM events WHERE action='edited' ORDER BY doc_id") { $0.int(0) }) ?? []
        Check.that("…and the history says it was put back", logged == [1, 2], "\(logged)")
    }
}
