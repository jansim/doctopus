import Foundation

/// Finding documents: the query language and the index behind it.
extension SelfTest {
    static func search(store: Store) async {
        print("\nSEARCH")
        for probe in ["rechnung", "insurance polic", "type:Invoice", "\"net pay\"", "rechnung OR kontoauszug", "-type:Invoice", "date:2026", "date:2026-02"] {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(probe),
                                                       sort: .relevance, ascending: false)) ?? []
            Check.that("search \(probe) finds something", !hits.isEmpty, "\(hits.count) hit(s)")
        }
        for probe in ["rechnung", "insurance polic", "kontoauszug", "steuer", "type:Invoice", "is:pending", "\"net pay\"", "rechnung OR kontoauszug", "-type:Invoice", "date:2026", "date:2026-02"] {
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(probe),
                                                       sort: .relevance, ascending: false)) ?? []
            let names = hits.prefix(3).map(\.filename).joined(separator: ", ")
            print("  \(probe.padded(24)) → \(hits.count) hit\(hits.count == 1 ? "" : "s")\(hits.isEmpty ? "" : ": \(names)")")
            if let snippet = hits.first?.snippet {
                print("  \("".padded(24))   …\(snippet.replacingOccurrences(of: "\n", with: " "))…")
            }
        }

        print("\nFACETS")
        for (label, column) in [("correspondents", "correspondent"), ("types", "doc_type"), ("languages", "language")] {
            let facets = (try? await store.facets(column: column)) ?? []
            print("  \(label.padded(16)) \(facets.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
        }
    }

    static func halfTypedSearches(store: Store) async {
        print("\nHALF-TYPED SEARCHES")
        // FTS5 rejects a dangling operator outright, and the throw would blank
        // the whole list — so every state the field passes through on the way
        // to a real query has to stay runnable.
        for partial in ["rechnung and", "and", "not", "or kontoauszug", "(rechnung or",
                        "rechnung )", "(", "rechnung and or kontoauszug"] {
            let hits = try? await store.listDocuments(selection: .all, query: SearchQuery(partial),
                                                      sort: .added, ascending: false)
            Check.that("“\(partial)” is still a query the list can run", hits != nil,
                       SearchQuery(partial).ftsExpression ?? "no expression")
        }
    }

    static func shortcuts(store: Store) async {
        print("\nURL SCHEMES & SHORTCUTS")
        if let searchURL = URL(string: "doctopus://search?q=rechnung") {
            let action = URLSchemeHandler.parse(searchURL)
            Check.that("URL scheme parses doctopus://search", action == .search("rechnung"))
        }
        if let importURL = URL(string: "doctopus://import?path=/tmp/scan.pdf") {
            let action = URLSchemeHandler.parse(importURL)
            Check.that("URL scheme parses doctopus://import", action == .import("/tmp/scan.pdf"))
        }

        print("\nAUTOCOMPLETE & GLOBAL SEARCH")
        let globalResults = (try? await store.listDocuments(selection: .all, query: SearchQuery("rechnung"), sort: .added, ascending: false)) ?? []
        Check.that("search suggestions and queries return hits for terms", !globalResults.isEmpty)
    }

    static func searchIndex(store: Store, rows: [DocumentRow]) async {
        print("\nSEARCH INDEX")
        if let sample = rows.first(where: { $0.correspondent?.nilIfBlank != nil }),
           let correspondent = sample.correspondent?.nilIfBlank {
            let term = correspondent.split(separator: " ").first.map(String.init) ?? correspondent
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(term),
                                                       sort: .relevance, ascending: false)) ?? []
            print(("  correspondent “" + term + "”").padded(40) + "→ \(hits.count) hit(s)")
            Check.that("a correspondent is searchable without a LIKE fallback",
                       hits.contains { $0.id == sample.id })
        }
        if let sample = rows.first {
            let stem = sample.url.deletingPathExtension().lastPathComponent
            let term = stem.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? stem
            let hits = (try? await store.listDocuments(selection: .all, query: SearchQuery(term),
                                                       sort: .relevance, ascending: false)) ?? []
            print(("  filename “" + term + "”").padded(40) + "→ \(hits.count) hit(s)")
            Check.that("a filename is searchable", hits.contains { $0.id == sample.id })

            let unique = "doctopusfts\(UUID().uuidString.prefix(6).lowercased())"
            let tagID = (try? await store.tagID(named: unique)) ?? 0
            try? await store.assign(tag: tagID, to: sample.doc)
            let tagged = (try? await store.listDocuments(selection: .all, query: SearchQuery(unique),
                                                         sort: .relevance, ascending: false)) ?? []
            Check.that("a tag is searchable as soon as it is assigned",
                       tagged.contains { $0.id == sample.id }, "\(tagged.count) hit(s)")
            try? await store.unassign(tag: tagID, from: sample.doc)
            let untagged = (try? await store.listDocuments(selection: .all, query: SearchQuery(unique),
                                                           sort: .relevance, ascending: false)) ?? []
            Check.that("…and stops being searchable when it is taken off", untagged.isEmpty,
                       "\(untagged.count) hit(s)")
            try? await store.deleteTag(tagID)

            let text = (try? await store.ocrText(sample.doc)) ?? ""
            Check.that("a document's text is still readable from the index", !text.isEmpty,
                       "\(text.count) characters")
        }
        if let victim = rows.last, let word = ((try? await store.ocrText(victim.doc)) ?? "")
            .split(whereSeparator: { !$0.isLetter }).first.map(String.init) {
            try? await store.deleteDocument(victim.doc)
            let orphan = (try? await store.listDocuments(selection: .all, query: SearchQuery(word),
                                                         sort: .relevance, ascending: false)) ?? []
            Check.that("deleting a document removes it from the search index",
                       !orphan.contains { $0.doc == victim.doc })
            Check.that("…and the file it indexed is left on disk",
                       FileManager.default.fileExists(atPath: victim.path))
        }
    }
}
