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

    /// `_` and `%` in a folder name are characters, not wildcards, and `in:`
    /// names a whole folder. Index rows only: nothing here needs the files.
    static func folderMatching(store: Store) async {
        print("\nFOLDER MATCHING")
        let tag = UUID().uuidString.prefix(6).lowercased()
        let root = store.root.path
        let paths = ["Pct_\(tag)/a.pdf", "Pct_\(tag)/Sub/b.pdf", "Pct-\(tag)/c.pdf", "XPct_\(tag)/d.pdf"]
        var made: [String: Int64] = [:]
        for rel in paths {
            let facts = Store.FileFacts(path: root + "/" + rel, size: 1, mtime: .now, created: .now)
            made[rel] = try? await store.upsertDocument(facts, origin: .inLibrary).id
        }
        let ids = made
        func found(_ selection: Selection, _ query: String) async -> Set<String> {
            let hits = (try? await store.listDocuments(selection: selection, query: SearchQuery(query),
                                                       sort: .added, ascending: false)) ?? []
            let hitIDs = Set(hits.map(\.doc))
            return Set(ids.filter { hitIDs.contains($0.value) }.map(\.key))
        }

        let folder = await found(.folder(root + "/Pct_\(tag)"), "")
        Check.that("a folder with _ in its name lists only its own documents",
                   folder == ["Pct_\(tag)/a.pdf", "Pct_\(tag)/Sub/b.pdf"], folder.sorted().joined(separator: ", "))
        let named = await found(.all, "in:Pct_\(tag)")
        Check.that("in: matches a whole folder name, and what is below it",
                   named == ["Pct_\(tag)/a.pdf", "Pct_\(tag)/Sub/b.pdf"], named.sorted().joined(separator: ", "))
        let nested = await found(.all, "in:Sub")
        Check.that("in: matches a folder at any depth", nested.contains("Pct_\(tag)/Sub/b.pdf"),
                   nested.sorted().joined(separator: ", "))
        let fragment = await found(.all, "in:ct_\(tag)")
        Check.that("in: does not match part of a folder name", fragment.isEmpty,
                   fragment.sorted().joined(separator: ", "))
        let negated = await found(.all, "-in:Pct_\(tag)")
        Check.that("-in: leaves out only that folder",
                   negated == ["Pct-\(tag)/c.pdf", "XPct_\(tag)/d.pdf"], negated.sorted().joined(separator: ", "))

        for id in ids.values { try? await store.deleteDocument(id) }
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

    /// Advanced Search takes the field's query apart into rows and writes it
    /// back, and what it writes has to mean what was typed.
    static func advancedSearch() {
        print("\nADVANCED SEARCH")
        typealias Condition = SearchCriteria.Condition
        let keys: Set<String> = ["doc_type", "correspondent", "language", "amount", "iban"]
        let typed = "rechnung OR kontoauszug \"net pay\" -entwurf -\"old draft\" tag:\"Home Office\" -tag:Archiv "
            + "finder:Red in:Taxes -ext:png is:review -is:duplicate type:Invoice -from:ACME iban:DE12 "
            + "date:\"this year\" -added:2025 analyzed:\"last month\" before:2026-03 after:2025 foo:bar"
        let criteria = SearchCriteria(typed, fieldKeys: keys)
        Check.that("the words stay as typed, a prefix that is no filter among them",
                   criteria.words == "rechnung OR kontoauszug \"net pay\" foo:bar", criteria.words)
        Check.that("words with a minus are the ones left out, a phrase still a phrase",
                   criteria.excluded == "entwurf \"old draft\"", criteria.excluded)
        let read = criteria.conditions.map { "\($0.attribute) \($0.relation) \($0.value)" }
        Check.that("every filter is a condition of its own", criteria.conditions.count == 15,
                   read.joined(separator: " · "))
        Check.that("a field is read under its alias",
                   criteria.conditions.contains { $0.attribute == .field("doc_type") && $0.value == "Invoice" }
                       && criteria.conditions.contains {
                           $0.attribute == .field("correspondent") && $0.relation == .isNot && $0.value == "ACME"
                       })
        Check.that("before: and after: are the document date's",
                   criteria.conditions.contains { $0.attribute == .documentDate && $0.relation == .before }
                       && criteria.conditions.contains { $0.attribute == .documentDate && $0.relation == .after })
        Check.that("put back together it is the same query",
                   SearchQuery(criteria.query, fieldKeys: keys) == SearchQuery(typed, fieldKeys: keys),
                   criteria.query)

        let notBefore = SearchCriteria("-before:2024")
        Check.that("a filter with no row to show it stays among the words",
                   notBefore.conditions.isEmpty && notBefore.words == "-before:2024", notBefore.words)

        var built = SearchCriteria()
        built.words = "miete"
        built.excluded = "entwurf -alt"
        built.conditions = [
            Condition(attribute: .tag, value: "Home Office"),
            Condition(attribute: .field("doc_type"), relation: .isNot, value: "Invoice"),
            Condition(attribute: .documentDate, relation: .after, value: "last month"),
            Condition(attribute: .tag),
        ]
        Check.that("rows are written in the field's syntax, one still empty left out",
                   built.query == "miete -entwurf -alt tag:\"Home Office\" -type:Invoice after:\"last month\"",
                   built.query)
        built.words = "\"net pay"
        let unclosed = SearchQuery(built.query)
        Check.that("a quote left open in the words does not swallow the conditions",
                   unclosed.terms == ["net pay"] && unclosed.tags == ["Home Office"], built.query)
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
