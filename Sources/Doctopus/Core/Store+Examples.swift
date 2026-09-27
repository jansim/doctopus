import Foundation

/// How a document already in the library was filed, shown to the model as a
/// worked example when it is asked about a similar one.
struct FilingExample: Sendable, Equatable {
    var docID: Int64
    var filename: String
    var excerpt: String
    var title: String?
    var summary: String?
    var correspondent: String?
    var docType: String?
    var language: String?
    var intent: String?
    var tags: [String] = []
    /// Someone looked at it and approved it, so its filing is what the user wants.
    var reviewed = false

    var hasFiling: Bool {
        [title, summary, correspondent, docType].contains { $0?.nilIfBlank != nil } || !tags.isEmpty
    }
}

extension Store {

    /// The most similar documents by text that someone has approved in review,
    /// excluding `docID` itself. Only a reviewed filing is shown: an example the
    /// model copies from should not be a guess it made last time. A wider pool
    /// than `limit` is looked at so one with nothing filed can be passed over.
    func filingExamples(for docID: Int64, limit: Int = 2, pool: Int = 6,
                        excerpt: Int = 300) throws -> [FilingExample] {
        guard limit > 0 else { return [] }
        let similar = try similarDocuments(for: docID, limit: max(pool, limit), reviewedOnly: true)
            .filter { $0.doc != docID }
        var chosen: [FilingExample] = []
        for row in similar where chosen.count < limit {
            let (reviewed, intent) = try db.first("""
                SELECT d.reviewed_at IS NOT NULL, m.intent FROM documents d
                LEFT JOIN metadata m ON m.doc_id = d.id WHERE d.id=?
                """, [.int(row.doc)], { ($0.bool(0), $0.stringOrNil(1)) }) ?? (false, nil)
            let tagNames = try self.tags(for: row.doc).filter { !$0.implied }.map(\.name)
            var example = FilingExample(
                docID: row.doc, filename: row.filename, excerpt: "",
                title: row.title, summary: row.summary, correspondent: row.correspondent,
                docType: row.docType, language: row.language, intent: intent,
                tags: tagNames, reviewed: reviewed)
            guard example.hasFiling else { continue }
            // Only the ones that made it are worth reading the text of.
            let text = (try? ocrText(row.doc)) ?? ""
            example.excerpt = String(text.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").prefix(excerpt))
            chosen.append(example)
        }
        return chosen
    }
}
