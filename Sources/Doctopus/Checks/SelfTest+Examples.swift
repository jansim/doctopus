import Foundation

/// Similar documents shown to the model as examples of how the library files
/// things. None of this needs a model: the lookup is the store's and the prompt
/// is plain text, so it is checked the same with the backend off.
extension SelfTest {
    static func filingExamples(store: Store, rows: [DocumentRow]) async {
        print("\nFILING EXAMPLES")
        await onlyReviewedExamples(store: store, rows: rows)

        var withExamples = 0
        var overLimit: [String] = []
        var ownExample: [String] = []
        var notSimilar: [String] = []
        var nothingFiled: [String] = []
        var unreviewed: [String] = []
        for row in rows {
            let examples = (try? await store.filingExamples(for: row.doc)) ?? []
            let similar = Set(((try? await store.similarDocuments(for: row.doc, limit: 6, reviewedOnly: true)) ?? []).map(\.doc))
            if !examples.isEmpty { withExamples += 1 }
            if examples.count > 2 { overLimit.append(row.filename) }
            if examples.contains(where: { $0.docID == row.doc }) { ownExample.append(row.filename) }
            if !examples.allSatisfy({ similar.contains($0.docID) }) { notSimilar.append(row.filename) }
            if !examples.allSatisfy(\.hasFiling) { nothingFiled.append(row.filename) }
            if !examples.allSatisfy(\.reviewed) { unreviewed.append(row.filename) }
        }
        Check.that("similar documents are found to show as examples", withExamples > 0,
                   "\(withExamples)/\(rows.count)")
        Check.that("no more than the asked-for number of examples is shown", overLimit.isEmpty,
                   overLimit.joined(separator: ", "))
        Check.that("a document is never its own example", ownExample.isEmpty,
                   ownExample.joined(separator: ", "))
        Check.that("examples come from the documents most similar by text", notSimilar.isEmpty,
                   notSimilar.joined(separator: ", "))
        Check.that("an example always has something filed to show", nothingFiled.isEmpty,
                   nothingFiled.joined(separator: ", "))
        Check.that("only documents someone reviewed are shown as examples", unreviewed.isEmpty,
                   unreviewed.joined(separator: ", "))
        var none: [FilingExample] = []
        for row in rows { none += (try? await store.filingExamples(for: row.doc, limit: 0)) ?? [] }
        Check.that("asking for no examples finds none", none.isEmpty)

        func example(_ id: Int64) -> FilingExample {
            FilingExample(docID: id, filename: "\(id).pdf", excerpt: "", docType: "Invoice", reviewed: true)
        }

        let text = String(repeating: "Abrechnungszeitraum Verbrauch Arbeitspreis Grundpreis ", count: 400)
        let stromrechnung = FilingExample(
            docID: 1, filename: "strom-2025.pdf", excerpt: text, title: "Stromrechnung",
            summary: "Jahresabrechnung Strom für die Hauptstraße.", correspondent: "Stadtwerke München",
            docType: "Invoice", language: "de", intent: "pay", tags: ["utilities", "energy"])
        var gasrechnung = stromrechnung
        gasrechnung.docID = 2
        gasrechnung.filename = "gas-2025.pdf"
        gasrechnung.title = "Gasrechnung"
        var third = stromrechnung
        third.docID = 3
        third.title = "Wasserrechnung"
        let examples = [stromrechnung, gasrechnung, third]

        let prompt = LLMPrompt.user(text: text, filename: "rechnung.pdf", limit: 6000, examples: examples)
        Check.that("the prompt shows each example's filing",
                   ["Stromrechnung", "Gasrechnung", "Stadtwerke München", "\"Invoice\"",
                    "\"utilities\"", "strom-2025.pdf", "Jahresabrechnung Strom"].allSatisfy { prompt.contains($0) })
        Check.that("the prompt shows every example it is given",
                   prompt.contains("Example 3") && prompt.contains("Wasserrechnung"))
        let exampleAt = prompt.range(of: "Gasrechnung")?.lowerBound
        let documentAt = prompt.range(of: "Document content")?.lowerBound
        Check.that("the examples come before the document they are examples for",
                   exampleAt != nil && documentAt != nil && exampleAt! < documentAt!)
        let tagsOnly = LLMPrompt.user(text: text, filename: "rechnung.pdf", limit: 6000,
                                      examples: examples, fields: [.tags])
        Check.that("an example only shows the fields being asked for",
                   tagsOnly.contains("\"utilities\"") && !tagsOnly.contains("Stromrechnung")
                       && !tagsOnly.contains("\"title\""))
        Check.that("an example with nothing asked for filed is left out",
                   !LLMPrompt.user(text: text, filename: "rechnung.pdf", limit: 6000,
                                   examples: [example(9)], fields: [.tags]).contains("Example 1"))
        Check.that("no examples, no mention of them",
                   !LLMPrompt.user(text: text, filename: "rechnung.pdf", limit: 6000).contains("Similar documents"))

        let plain = LLMPrompt.user(text: text, filename: "rechnung.pdf", limit: 3000)
        let padded = LLMPrompt.user(text: text, filename: "rechnung.pdf", limit: 3000, examples: examples)
        print("  prompt at 3,000 characters: \(plain.count) without examples, \(padded.count) with")
        Check.that("examples come out of the document's share rather than growing the prompt",
                   padded.contains("Example 2") && padded.count <= plain.count + 8)

        for row in rows {
            let shown = (try? await store.filingExamples(for: row.doc)) ?? []
            guard !shown.isEmpty else { continue }
            let real = LLMPrompt.user(text: "Sample Document", filename: row.filename, limit: 6000, examples: shown)
            Check.that("the prompt shows the library's own similar documents",
                       shown.allSatisfy { real.contains("filename: \($0.filename)") })
            break
        }
    }

    /// A similar document nobody has reviewed is never an example; approving
    /// it in review makes it one.
    private static func onlyReviewedExamples(store: Store, rows: [DocumentRow]) async {
        for row in rows {
            let shown = Set(((try? await store.filingExamples(for: row.doc, limit: 6)) ?? []).map(\.docID))
            let reviewed = Set(((try? await store.similarDocuments(for: row.doc, limit: 50, reviewedOnly: true)) ?? []).map(\.doc))
            let similar = (try? await store.similarDocuments(for: row.doc, limit: 6)) ?? []
            guard shown.count < 6,
                  let target = similar.first(where: {
                      !reviewed.contains($0.doc) && !shown.contains($0.doc)
                          && [$0.title, $0.correspondent, $0.docType].contains { $0?.nilIfBlank != nil }
                  })
            else { continue }
            Check.that("a similar document nobody reviewed is not an example", !shown.contains(target.doc),
                       "\(target.filename) for \(row.filename)")
            try? await store.setDocumentApproved(target.doc, true)
            let examples = (try? await store.filingExamples(for: row.doc, limit: 6)) ?? []
            Check.that("once reviewed, a similar document is taken as an example",
                       examples.contains { $0.docID == target.doc },
                       "\(target.filename) for \(row.filename)")
            return
        }
        Check.that("the fixtures have a similar document nobody has reviewed", false)
    }
}
