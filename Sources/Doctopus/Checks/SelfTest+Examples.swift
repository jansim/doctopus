import Foundation

/// Similar documents shown to the model as examples of how the library files
/// things. None of this needs a model: the lookup is the store's and the prompt
/// is plain text, so it is checked the same with the backend off.
extension SelfTest {
    static func filingExamples(store: Store, rows: [DocumentRow]) async {
        print("\nFILING EXAMPLES")
        var withExamples = 0
        var overLimit: [String] = []
        var ownExample: [String] = []
        var notSimilar: [String] = []
        var nothingFiled: [String] = []
        for row in rows {
            let examples = (try? await store.filingExamples(for: row.doc)) ?? []
            let similar = Set(((try? await store.similarDocuments(for: row.doc, limit: 6)) ?? []).map(\.doc))
            if !examples.isEmpty { withExamples += 1 }
            if examples.count > 2 { overLimit.append(row.filename) }
            if examples.contains(where: { $0.docID == row.doc }) { ownExample.append(row.filename) }
            if !examples.allSatisfy({ similar.contains($0.docID) }) { notSimilar.append(row.filename) }
            if !examples.allSatisfy(\.hasFiling) { nothingFiled.append(row.filename) }
        }
        Check.that("similar documents are found to show as examples", withExamples > 0,
                   "\(withExamples)/\(rows.count)")
        Check.that("no more than two examples are shown", overLimit.isEmpty,
                   overLimit.joined(separator: ", "))
        Check.that("a document is never its own example", ownExample.isEmpty,
                   ownExample.joined(separator: ", "))
        Check.that("examples come from the documents most similar by text", notSimilar.isEmpty,
                   notSimilar.joined(separator: ", "))
        Check.that("an example always has something filed to show", nothingFiled.isEmpty,
                   nothingFiled.joined(separator: ", "))

        func example(_ id: Int64, reviewed: Bool = false, approved: Bool = true,
                     filed: Bool = true) -> FilingExample {
            FilingExample(docID: id, filename: "\(id).pdf", excerpt: "",
                          docType: filed ? "Invoice" : nil, reviewed: reviewed, approved: approved)
        }
        let ranked = FilingExample.preferred(
            [example(1), example(2, filed: false), example(3, reviewed: true),
             example(4, approved: false), example(5, reviewed: true)], limit: 2)
        Check.that("a reviewed filing is preferred over a closer unreviewed one",
                   ranked.map(\.docID) == [3, 5], "\(ranked.map(\.docID))")
        Check.that("otherwise the more similar document comes first, and one awaiting review last",
                   FilingExample.preferred([example(1), example(2)], limit: 2).map(\.docID) == [1, 2]
                       && FilingExample.preferred([example(4, approved: false), example(1)], limit: 2)
                           .map(\.docID) == [1, 4])
        await reviewedExampleWins(store: store, rows: rows)

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
        Check.that("the prompt shows no more than two examples",
                   prompt.contains("Example 2") && !prompt.contains("Example 3")
                       && !prompt.contains("Wasserrechnung"))
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

    /// Marking a less similar candidate as reviewed brings it into the examples.
    private static func reviewedExampleWins(store: Store, rows: [DocumentRow]) async {
        let queued = Set((try? await store.reviewDocumentIDs()) ?? [])
        for row in rows {
            let candidates = (try? await store.filingExamples(for: row.doc, limit: 6)) ?? []
            guard candidates.filter(\.reviewed).count < 2,
                  let target = candidates.dropFirst(2).last(where: {
                      $0.approved && !$0.reviewed && !queued.contains($0.docID)
                  })
            else { continue }
            try? await store.setDocumentApproved(target.docID, true)
            let examples = (try? await store.filingExamples(for: row.doc)) ?? []
            Check.that("a document someone reviewed is taken as an example over a closer one",
                       examples.contains { $0.docID == target.docID },
                       "\(target.filename) for \(row.filename)")
            return
        }
        Check.that("the fixtures have a less similar document to review", false)
    }
}
