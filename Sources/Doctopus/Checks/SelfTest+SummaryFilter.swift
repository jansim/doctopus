import Foundation

/// Finding the documents nothing has described yet.
extension SelfTest {
    static func summaryFilter(store: Store) async {
        print("\nSUMMARY FILTER")
        let rows = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                   sort: .added, ascending: false)) ?? []
        guard let sample = rows.first else {
            Check.that("a document to describe is there", false); return
        }
        func finds(_ query: String) async -> Bool {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(query),
                                                       sort: .added, ascending: false)) ?? []
            return hits.contains { $0.doc == sample.doc }
        }
        try? await store.overwriteMetadataField(sample.doc, column: "summary", value: nil)
        var without = await finds("is:unsummarized"), with = await finds("is:summarized")
        Check.that("a document with no summary is found as unsummarized", without && !with)
        let undescribed = await finds("is:no-description"), negated = await finds("-is:unsummarized")
        Check.that("…also by the names a description goes by", undescribed && !negated)

        try? await store.overwriteMetadataField(sample.doc, column: "summary", value: "   ")
        without = await finds("is:unsummarized")
        Check.that("a blank summary counts as none", without)

        try? await store.overwriteMetadataField(sample.doc, column: "summary", value: "A short description.")
        without = await finds("is:unsummarized"); with = await finds("is:summarized")
        let notWithout = await finds("-is:unsummarized")
        Check.that("one with a summary is not", with && !without && notWithout)

        try? await store.overwriteMetadataField(sample.doc, column: "summary", value: sample.summary)
    }
}
