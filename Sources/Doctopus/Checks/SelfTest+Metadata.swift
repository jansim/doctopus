import Foundation

/// Library › Metadata's merge, and the values a field's editor suggests.
extension SelfTest {
    static func metadataMerge(store: Store, rows: [DocumentRow]) async {
        print("\nMETADATA MERGE")
        let fields = (try? await store.fields()) ?? []
        guard rows.count >= 3, let corrField = fields.first(where: { $0.key == "correspondent" }) else {
            Check.that("three documents and a correspondent field to merge on", false); return
        }
        let spellings = ["Merge Werke GmbH", "Merge Werke", "MERGE WERKE G.M.B.H."]
        for (row, spelling) in zip(rows.prefix(3), spellings) {
            try? await store.setFieldValue(docID: row.doc, field: corrField, value: spelling)
        }

        let moved = (try? await store.mergeFieldValues(field: corrField, Array(spellings.prefix(2)),
                                                      into: spellings[0])) ?? -1
        var names = ((try? await store.entities(builtin: "correspondent")) ?? []).map(\.name)
        Check.that("merging into one of the chosen moves only the others' documents", moved == 1,
                   "\(moved)")
        Check.that("…and leaves that one standing alone",
                   names.contains(spellings[0]) && !names.contains(spellings[1]))

        let fresh = "Merge Werke AG"
        _ = try? await store.mergeFieldValues(field: corrField, [spellings[0], spellings[2]], into: fresh)
        let entities = (try? await store.entities(builtin: "correspondent")) ?? []
        names = entities.map(\.name)
        let survivor = entities.first { $0.name == fresh }
        Check.that("merging into a new name leaves only that name",
                   survivor?.count == 3 && !spellings.contains { names.contains($0) },
                   "\(survivor?.count ?? -1) documents; \(names.filter { $0.hasPrefix("Merge") || $0.hasPrefix("MERGE") })")
        let listed = (try? await store.listDocuments(selection: .field("correspondent", fresh),
                                                     query: SearchQuery(""), sort: .added,
                                                     ascending: false)) ?? []
        Check.that("…which lists all of them", listed.count == 3, "\(listed.count)")

        for row in rows.prefix(3) {
            try? await store.setFieldValue(docID: row.doc, field: corrField, value: row.correspondent)
        }
        try? await store.deleteFieldValue(field: corrField, value: fresh)

        let a = (try? await store.tagID(named: "Merge Receipts")) ?? 0
        let b = (try? await store.tagID(named: "Merge Receipt")) ?? 0
        let c = (try? await store.tagID(named: "merge-receipts")) ?? 0
        try? await store.assign(tag: a, to: rows[0].doc)
        try? await store.assign(tag: b, to: rows[1].doc)
        try? await store.assign(tag: c, to: rows[2].doc)
        try? await store.assign(tag: c, to: rows[0].doc)
        let kept = try? await store.mergeTags([a, b, c], into: "Merge Receipt")
        let tags = (try? await store.tags()) ?? []
        let left = tags.filter { [a, b, c].contains($0.tagID) }
        Check.that("merging tags keeps the one whose name was picked", kept == b && left.map(\.tagID) == [b],
                   left.map(\.name).joined(separator: ", "))
        Check.that("…with every document any of them was on, once",
                   left.first?.count == 3, "\(left.first?.count ?? -1)")
        try? await store.deleteTag(b)
    }

    static func valueSuggestions() {
        print("\nVALUE SUGGESTIONS")
        let known = ["Stadtwerke München", "Allianz", "Amazon EU", "Techniker Krankenkasse", "Stadt Köln"]
        let typed = ValueSuggestions.matches(known, for: "stadt")
        Check.that("what was typed is matched regardless of case, beginnings first, most used first",
                   typed == ["Stadtwerke München", "Stadt Köln"], "\(typed)")
        let inside = ValueSuggestions.matches(known, for: "kranken")
        Check.that("…and inside a name too", inside == ["Techniker Krankenkasse"], "\(inside)")
        let accents = ValueSuggestions.matches(known, for: "munchen")
        Check.that("…without minding accents", accents == ["Stadtwerke München"], "\(accents)")
        Check.that("nothing is offered for an empty field",
                   ValueSuggestions.matches(known, for: " ").isEmpty)
        Check.that("…nor once the text names one exactly",
                   ValueSuggestions.matches(known, for: "Allianz").isEmpty)
        Check.that("…nor for the value the field already has",
                   ValueSuggestions.matches(known, for: "Am", current: "Am").isEmpty)
        Check.that("a differently cased name is still offered, to fix the spelling",
                   ValueSuggestions.matches(known, for: "allianz") == ["Allianz"])
        let many = (1...20).map { "Firma \($0)" }
        Check.that("the list stops at \(ValueSuggestions.limit)",
                   ValueSuggestions.matches(many, for: "firma").count == ValueSuggestions.limit)
    }
}
