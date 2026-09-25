import Foundation

/// Tags, the library's own and the Finder's.
extension SelfTest {
    static func finderTags(store: Store, rows: [DocumentRow]) async {
        print("\nFINDER TAGS (written to the files themselves)")
        if let sample = rows.first {
            let before = FinderTags.entries(sample.url)
            _ = FinderTags.add("Doctopus Test", to: sample.url)
            let entries = FinderTags.entries(sample.url)
            let onDisk = entries.map(\.name)
            try? await store.indexFinderTags(docID: sample.doc, entries: entries)
            let listed = (try? await store.finderTags()) ?? []
            let filtered = (try? await store.listDocuments(selection: .finderTag("Doctopus Test"),
                                                           query: SearchQuery(""), sort: .added,
                                                           ascending: false)) ?? []
            print("  \(sample.filename) → \(onDisk.joined(separator: ", "))")
            print("  library-wide            \(listed.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
            Check.that("a Finder tag is written to the file and indexed",
                       onDisk.contains("Doctopus Test")
                           && listed.contains { $0.value == "Doctopus Test" }
                           && filtered.contains { $0.id == sample.id })
            let searched = (try? await store.listDocuments(selection: .all,
                                                           query: SearchQuery("finder:\"Doctopus Test\""),
                                                           sort: .added, ascending: false)) ?? []
            Check.that("finder: searches the Finder's tags", searched.contains { $0.id == sample.id })

            _ = FinderTags.add("Blue", to: sample.url)
            _ = FinderTags.add("Doctopus Colour", to: sample.url)
            let coloured = FinderTags.entries(sample.url)
            print("  colours                 " + coloured.map { "\($0.name)=\($0.label)" }.joined(separator: ", "))
            Check.that("a Finder colour tag keeps macOS's own label",
                       coloured.contains { $0.name == "Blue" && $0.label == 4 },
                       coloured.map { "\($0.name)=\($0.label)" }.joined(separator: ", "))
            Check.that("adding a tag preserves the colours already on the file",
                       coloured.first { $0.name == "Blue" }?.label == 4)

            _ = FinderTags.write(before, to: sample.url)
            Check.that("removing them leaves the file as it was",
                       FinderTags.entries(sample.url) == before)
            try? await store.indexFinderTags(docID: sample.doc, entries: FinderTags.entries(sample.url))
        }
    }

    static func tagMerge(store: Store, rows: [DocumentRow]) async {
        print("\nTAG MERGE")
        let invoiceTag = (try? await store.tagID(named: "invoice")) ?? 0
        let billTag = (try? await store.tagID(named: "bills")) ?? 0
        for row in rows.prefix(2) { try? await store.assign(tag: invoiceTag, to: row.doc) }
        for row in rows.prefix(3) { try? await store.assign(tag: billTag, to: row.doc) }
        try? await store.setTagColor(billTag, 3)
        let before = (try? await store.tags()) ?? []
        print("  before  \(before.map { "\($0.name) (\($0.count), colour \($0.color))" }.joined(separator: ", "))")
        _ = try? await store.renameTag(invoiceTag, to: "bills")
        let after = (try? await store.tags()) ?? []
        print("  after   \(after.map { "\($0.name) (\($0.count), colour \($0.color))" }.joined(separator: ", "))")
        Check.that("merged tag keeps the target's colour and documents",
                   after.count == 1 && after[0].name == "bills" && after[0].count == 3 && after[0].color == 3)
    }

    static func nestedTags(store: Store, rows: [DocumentRow]) async {
        print("\nNESTED TAGS")
        let finances = (try? await store.tagID(named: "Finances")) ?? 0
        let invoices = (try? await store.tagID(named: "Finances Invoices")) ?? 0
        let statements = (try? await store.tagID(named: "Finances Statements")) ?? 0
        _ = try? await store.setTagParent(invoices, to: finances)
        _ = try? await store.setTagParent(statements, to: finances)
        if let subject = rows.first {
            try? await store.assign(tag: invoices, to: subject.doc)
            let carried = (try? await store.tags(for: subject.doc)) ?? []
            print("  tagged with Invoices → \(carried.map(\.name).joined(separator: ", "))")
            Check.that("assigning a child attaches its parent too",
                       carried.contains { $0.tagID == finances })
            let byParent = (try? await store.listDocuments(selection: .tag(finances),
                                                           query: SearchQuery(""), sort: .added,
                                                           ascending: false)) ?? []
            Check.that("…so filtering by the parent finds it",
                       byParent.contains { $0.doc == subject.doc })
        }
        let shaped = (try? await store.tags()) ?? []
        for tag in shaped where tag.name.hasPrefix("Finances") {
            print("  \(String(repeating: "  ", count: tag.depth))\(tag.name) (\(tag.count))")
        }
        Check.that("children are drawn under their parent, one level in",
                   shaped.first { $0.tagID == invoices }?.depth == 1
                       && shaped.first { $0.tagID == finances }?.depth == 0)

        Check.that("a tag cannot be its own parent",
                   (try? await store.setTagParent(finances, to: finances)) == false)
        Check.that("a descendant cannot become the parent",
                   (try? await store.setTagParent(finances, to: invoices)) == false)

        let deep = (try? await store.tagID(named: "Household")) ?? 0
        if let subject = rows.first {
            _ = try? await store.setTagParent(finances, to: deep)
            let after = (try? await store.tags(for: subject.doc)) ?? []
            Check.that("re-parenting gives the documents the new ancestor",
                       after.contains { $0.tagID == deep },
                       after.map(\.name).joined(separator: ", "))
            _ = try? await store.setTagParent(finances, to: nil)
        }

        var chain: [Int64] = []
        for level in 1...6 {
            let id = (try? await store.tagID(named: "Level \(level)")) ?? 0
            chain.append(id)
            if level > 1 { _ = try? await store.setTagParent(id, to: chain[level - 2]) }
        }
        let levels = (try? await store.tags()) ?? []
        let deepest = levels.filter { $0.name.hasPrefix("Level ") }.map(\.depth).max() ?? 0
        print("  deepest nesting reached \(deepest + 1) level(s)")
        Check.that("tags nest no deeper than the cap", deepest < Tag.maxDepth,
                   "depth \(deepest)")
        for id in chain.reversed() { try? await store.deleteTag(id) }
        for id in [invoices, statements, finances, deep] { try? await store.deleteTag(id) }

        let taxYear = (try? await store.tagID(named: "tax/2025")) ?? 0
        let taxRoot = (try? await store.tagID(named: "tax")) ?? 0
        let taxShaped = (try? await store.tags()) ?? []
        let taxYearTag = taxShaped.first { $0.tagID == taxYear }
        Check.that("a slash in the name nests the tag it makes",
                   taxYearTag?.parentID == taxRoot && taxYearTag?.name == "2025",
                   taxShaped.map(\.name).joined(separator: ", "))
        let taxYearAgain = (try? await store.tagID(named: "tax/2025")) ?? -1
        Check.that("typing the same nested path twice doesn't duplicate it",
                   taxYearAgain == taxYear)
        if let subject = rows.first {
            try? await store.assign(tag: taxYear, to: subject.doc)
            let carried = (try? await store.tags(for: subject.doc)) ?? []
            let pills = Tag.visible(in: carried)
            Check.that("the pill for a nested tag spells out its whole path",
                       pills.contains { $0.tag.tagID == taxYear && $0.path == "tax/2025" }
                           && !pills.contains { $0.tag.tagID == taxRoot },
                       pills.map(\.path).joined(separator: ", "))
        }
        try? await store.deleteTag(taxYear)
        try? await store.deleteTag(taxRoot)
    }
}
