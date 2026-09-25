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
    /// Not waiting in the review queue, so nobody has objected to it yet either.
    var approved = true

    var hasFiling: Bool {
        [title, summary, correspondent, docType].contains { $0?.nilIfBlank != nil } || !tags.isEmpty
    }

    /// Among documents about as similar as each other, a filing someone has
    /// confirmed is worth more than one nobody has looked at — an example the
    /// model copies from should not be the guess it made last time.
    static func preferred(_ candidates: [FilingExample], limit: Int) -> [FilingExample] {
        func tier(_ e: FilingExample) -> Int { e.reviewed ? 0 : e.approved ? 1 : 2 }
        return candidates.enumerated()
            .filter { $0.element.hasFiling }
            .sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }
            .prefix(limit)
            .map { $0.element }
    }
}

extension Store {

    /// The most similar documents by text, excluding `docID` itself. A wider
    /// pool than `limit` is looked at so a reviewed document a little further
    /// down can win over an unreviewed one at the top.
    func filingExamples(for docID: Int64, limit: Int = 2, pool: Int = 6,
                        excerpt: Int = 300) throws -> [FilingExample] {
        guard limit > 0 else { return [] }
        let similar = try similarDocuments(for: docID, limit: max(pool, limit))
            .filter { $0.doc != docID }
        var candidates: [FilingExample] = []
        for row in similar {
            let (reviewed, intent) = try db.first("""
                SELECT d.reviewed_at IS NOT NULL, m.intent FROM documents d
                LEFT JOIN metadata m ON m.doc_id = d.id WHERE d.id=?
                """, [.int(row.doc)], { ($0.bool(0), $0.stringOrNil(1)) }) ?? (false, nil)
            let tagNames = try self.tags(for: row.doc).filter { !$0.implied }.map(\.name)
            candidates.append(FilingExample(
                docID: row.doc, filename: row.filename, excerpt: "",
                title: row.title, summary: row.summary, correspondent: row.correspondent,
                docType: row.docType, language: row.language, intent: intent,
                tags: tagNames, reviewed: reviewed, approved: row.approved))
        }
        var chosen = FilingExample.preferred(candidates, limit: limit)
        // Only the ones that made it are worth reading the text of.
        for i in chosen.indices {
            let text = (try? ocrText(chosen[i].docID)) ?? ""
            chosen[i].excerpt = String(text.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").prefix(excerpt))
        }
        return chosen
    }
}
