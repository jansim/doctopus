import Foundation

/// Fields, the values documents carry in them, and the notes kept beside them.
extension SelfTest {
    static func fieldValues(store: Store, rows: [DocumentRow]) async -> [Field] {
        print("\nFIELDS")
        let fields = (try? await store.fields()) ?? []
        for field in fields {
            let count = ((try? await store.facets(field: field)) ?? []).count
            print("  \(field.name.padded(16)) key=\(field.key.padded(14)) "
                  + "\(field.isBuiltin ? "built-in" : "custom  ") "
                  + "sidebar=\(field.showInSidebar ? "y" : "n") list=\(field.showInList ? "y" : "n") "
                  + "values=\(count)")
        }

        if let subject = rows.first,
           let amount = fields.first(where: { $0.builtinColumn == "amount" }),
           let intent = fields.first(where: { $0.builtinColumn == "intent" }) {
            try? await store.setFieldValue(docID: subject.doc, field: amount, value: "€49,90")
            try? await store.setFieldValue(docID: subject.doc, field: intent, value: "pay")
            let listed = ((try? await store.listDocuments(
                selection: .all, query: SearchQuery(""), sort: .added, ascending: false)) ?? [])
                .first { $0.doc == subject.doc }
            let inspected = try? await store.detail(subject.doc)
            print("  in the list             \(listed?.values["amount"] ?? "—") / \(listed?.values["intent"] ?? "—")")
            Check.that("a built-in field's value reaches the list, not only the inspector",
                       listed?.values["amount"] == "€49,90" && listed?.values["intent"] == "pay",
                       "\(listed?.values["amount"] ?? "—"), \(listed?.values["intent"] ?? "—")")
            let disagreed = fields.filter { $0.isBuiltin }
                .filter { listed?.values[$0.key] != inspected?.row.values[$0.key] }
            Check.that("…and the two agree about every built-in field",
                       disagreed.isEmpty, disagreed.map(\.key).joined(separator: ", "))
            try? await store.setFieldValue(docID: subject.doc, field: amount, value: nil)
            try? await store.setFieldValue(docID: subject.doc, field: intent, value: nil)
        }
        return fields
    }

    static func savedViews(store: Store) async {
        print("\nSAVED VIEWS (SMART FOLDERS)")
        let sv = SavedView(id: 0, name: "Invoices 2026", icon: "doc.text",
                           query: "type:Invoice date:2026", sortKey: "docDate", ascending: false,
                           viewMode: "List", position: 0)
        let savedVID = (try? await store.upsertSavedView(sv)) ?? 0
        let svList = (try? await store.savedViews()) ?? []
        Check.that("saved view is persisted", svList.contains { $0.id == savedVID && $0.name == "Invoices 2026" })
        if let foundSV = svList.first(where: { $0.id == savedVID }) {
            let hits = (try? await store.listDocuments(selection: .savedView(id: foundSV.id, query: foundSV.query),
                                                       query: SearchQuery(foundSV.query), sort: .added, ascending: false)) ?? []
            Check.that("saved view query returns matching documents", !hits.isEmpty)
        }
        try? await store.deleteSavedView(savedVID)
        let svAfter = (try? await store.savedViews()) ?? []
        Check.that("saved view can be deleted", !svAfter.contains { $0.id == savedVID })
    }

    static func renameAndMerge(store: Store, rows: [DocumentRow], fields: [Field]) async {
        print("\nRENAME + MERGE")
        if let typeField = fields.first(where: { $0.key == "doc_type" }) {
            var n = (try? await store.renameFieldValue(field: typeField, from: "Invoice", to: "Bill")) ?? 0
            print("  Invoice → Bill                        \(n) document(s)")
            n = (try? await store.renameFieldValue(field: typeField, from: "Contract", to: "Bill")) ?? 0
            let after = ((try? await store.facets(field: typeField)) ?? [])
                .first { $0.value == "Bill" }?.count ?? 0
            print("  Contract → Bill (merge)               \(n) document(s); “Bill” now holds \(after)")
            Check.that("renaming two values to one merges them", after >= 2, "“Bill” holds \(after)")
            n = (try? await store.renameFieldValue(field: typeField, from: "Bill", to: "Invoice")) ?? 0
            print("  Bill → Invoice (restore)              \(n) document(s)")
        }

        if let id = try? await store.addCustomField(name: "Project"),
           let project = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }) {
            for (index, row) in rows.prefix(3).enumerated() {
                try? await store.setFieldValue(docID: row.doc, field: project,
                                               value: index == 0 ? "Alpha" : "Beta")
            }
            let before = (try? await store.facets(field: project)) ?? []
            print("  custom “Project” values               \(before.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
            _ = try? await store.renameFieldValue(field: project, from: "Alpha", to: "Beta")
            let merged = (try? await store.facets(field: project)) ?? []
            print("  Alpha → Beta (merge)                  \(merged.map { "\($0.value) (\($0.count))" }.joined(separator: ", "))")
            let filtered = (try? await store.listDocuments(selection: .field("project", "Beta"),
                                                           query: SearchQuery(""), sort: .added,
                                                           ascending: false)) ?? []
            print("  filter project:Beta                   \(filtered.count) hit(s)")
            Check.that("custom field merges and filters", merged.count == 1 && filtered.count == 3,
                       "\(merged.count) value(s), \(filtered.count) hit(s)")
            try? await store.deleteField(id)
        }
    }

    static func valueIcons(store: Store, fields: [Field]) async {
        print("\nVALUE ICONS")
        if let typeField = fields.first(where: { $0.key == "doc_type" }),
           let first = ((try? await store.facets(field: typeField)) ?? []).first {
            try? await store.setValueIcon(field: typeField, value: first.value, icon: "banknote")
            let withIcon = ((try? await store.facets(field: typeField)) ?? [])
                .first { $0.value == first.value }
            print("  \(first.value.padded(20)) icon=\(withIcon?.icon ?? "—") (field default \(typeField.icon))")
            Check.that("a value can carry its own icon", withIcon?.icon == "banknote")

            _ = try? await store.renameFieldValue(field: typeField, from: first.value, to: "Icon Test")
            let renamed = ((try? await store.facets(field: typeField)) ?? []).first { $0.value == "Icon Test" }
            Check.that("the icon follows a renamed value", renamed?.icon == "banknote")
            _ = try? await store.renameFieldValue(field: typeField, from: "Icon Test", to: first.value)
            try? await store.setValueIcon(field: typeField, value: first.value, icon: nil)
        }
    }

    static func entities(store: Store, rows: [DocumentRow]) async {
        print("\nENTITIES")
        if let corrField = ((try? await store.fields()) ?? []).first(where: { $0.key == "correspondent" }) {
            let live = (try? await store.entities(builtin: "correspondent")) ?? []
            let listed: [String] = live.prefix(4).map { "\($0.name) (\($0.count))" }
            print("  correspondents          " + listed.joined(separator: ", "))
            Check.that("every correspondent in use is a row", !live.isEmpty)
            Check.that("…and each one exists exactly once",
                       Set(live.map { $0.name.lowercased() }).count == live.count)

            if rows.count >= 3 {
                let spellingA = "Doctopus Werke GmbH"
                let spellingB = "Doctopus Werke"
                try? await store.setFieldValue(docID: rows[0].doc, field: corrField, value: spellingA)
                try? await store.setFieldValue(docID: rows[1].doc, field: corrField, value: spellingA)
                try? await store.setFieldValue(docID: rows[2].doc, field: corrField, value: spellingB)
                try? await store.setValueIcon(field: corrField, value: spellingA, icon: "building.columns")

                let renamed = (try? await store.renameFieldValue(field: corrField, from: spellingA,
                                                                 to: "Doctopus Werke AG")) ?? 0
                var after = (try? await store.entities(builtin: "correspondent")) ?? []
                let moved = after.first { $0.name == "Doctopus Werke AG" }
                let movedCount: Int = moved?.count ?? 0
                print("  " + spellingA + " → Doctopus Werke AG   "
                      + "\(movedCount) document(s), \(renamed) row(s)")
                Check.that("renaming a correspondent takes every document with it",
                           moved?.count == 2, "\(moved?.count ?? -1)")
                Check.that("…and its icon comes along rather than being orphaned",
                           moved?.icon == "building.columns")
                Check.that("…leaving no trace of the old spelling",
                           !after.contains { $0.name == spellingA })
                let filtered = (try? await store.listDocuments(
                    selection: .field("correspondent", "Doctopus Werke AG"), query: SearchQuery(""),
                    sort: .added, ascending: false)) ?? []
                Check.that("…and the sidebar filter follows it", filtered.count == 2,
                           "\(filtered.count) documents")

                _ = try? await store.renameFieldValue(field: corrField, from: spellingB, to: "Doctopus Werke AG")
                after = (try? await store.entities(builtin: "correspondent")) ?? []
                let survivor = after.first { $0.name == "Doctopus Werke AG" }
                let survivorCount: Int = survivor?.count ?? 0
                print("  " + spellingB + " merged in       \(survivorCount) document(s)")
                Check.that("two spellings merge into one correspondent",
                           survivor?.count == 3 && !after.contains { $0.name == spellingB },
                           "\(survivor?.count ?? -1) of 3")

                let searched = (try? await store.listDocuments(
                    selection: .all, query: SearchQuery("Doctopus Werke AG"), sort: .relevance,
                    ascending: false)) ?? []
                Check.that("…searchable under the surviving name", searched.count >= 3,
                           "\(searched.count) hits")

                for row in rows.prefix(3) {
                    try? await store.setFieldValue(docID: row.doc, field: corrField,
                                                   value: row.correspondent)
                }
                try? await store.deleteFieldValue(field: corrField, value: "Doctopus Werke AG")
            }

            if let subject = rows.first {
                let made = (try? await store.entityID(named: "Selbsterkennung",
                                                      builtin: "correspondent")) ?? nil
                if let made {
                    try? await store.setEntityMatch(made, pattern: "doctopus-iban-de12")
                    let matching = (try? await store.matchingEntities()) ?? []
                    let picked = DocumentAnalyzer.analyze(
                        url: subject.url, text: "Kontoauszug für doctopus-iban-de12 im Januar",
                        fallbackDate: Date(), knownCorrespondents: [],
                        options: DocumentAnalyzer.Options(entityRules: matching)).correspondent
                    print("  identified by its own pattern → \(picked ?? "nothing")")
                    Check.that("a correspondent carrying a pattern identifies itself",
                               picked == "Selbsterkennung")
                    try? await store.deleteEntity(made, column: "correspondent")
                }
            }

            Check.that("a known correspondent only matches on a word boundary",
                       DocumentAnalyzer.correspondent(
                           text: "Gehaltsabrechnung von Northwind\nSehr geehrte Damen",
                           known: ["AG", "rech"]) != "AG")
        }
    }

    static func typedFields(store: Store, rows: [DocumentRow]) async {
        print("\nTYPED FIELDS")
        let amounts: [(String, Double?)] = [
            ("€1.234,56", 1234.56), ("$1,234.56", 1234.56), ("1 234,56 EUR", 1234.56),
            ("90", 90), ("€90", 90), ("-12.50", -12.5), ("not a number", nil),
        ]
        var parsedRight = true
        for (raw, expected) in amounts {
            let got = FieldType.number(from: raw)
            if got != expected { parsedRight = false }
            let shown: String = got.map { "\($0)" } ?? "—"
            print("  " + raw.padded(20) + " → " + shown)
        }
        Check.that("an amount is read as a number however it is written", parsedRight)
        Check.that("yes and Yes and true are one answer",
                   FieldType.boolean(from: "yes") == true && FieldType.boolean(from: "Yes") == true
                       && FieldType.boolean(from: "true") == true && FieldType.boolean(from: "No") == false)

        if let id = try? await store.addCustomField(name: "Paid Amount", type: .monetary),
           let money = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }),
           rows.count >= 3 {
            let written = ["€1.234,56", "$90.00", "€12,00"]
            for (index, row) in rows.prefix(3).enumerated() {
                try? await store.setFieldValue(docID: row.doc, field: money, value: written[index])
            }
            let sorted = (try? await store.listDocuments(
                selection: .all, query: SearchQuery(""), sort: .field(money.key),
                ascending: true)) ?? []
            let order = sorted.compactMap { $0.values[money.key] }
            print("  sorted by amount      \(order.joined(separator: ", "))")
            Check.that("amounts sort by value, not by spelling",
                       Array(order.prefix(3)) == ["€12,00", "$90.00", "€1.234,56"],
                       order.joined(separator: ", "))
            Check.that("…and the currency is kept exactly as it was typed",
                       order.contains("€1.234,56"))

            var asText = money
            asText.type = .string
            try? await store.updateField(asText)
            var back = money
            back.type = .monetary
            try? await store.updateField(back)
            let again = ((try? await store.listDocuments(
                selection: .all, query: SearchQuery(""), sort: .field(money.key),
                ascending: true)) ?? []).compactMap { $0.values[money.key] }
            Check.that("changing a field's type re-reads the values it already holds",
                       Array(again.prefix(3)) == ["€12,00", "$90.00", "€1.234,56"],
                       again.prefix(3).joined(separator: ", "))
            try? await store.deleteField(id)
        }

        if let id = try? await store.addCustomField(name: "Due", type: .date),
           let due = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }),
           let subject = rows.first {
            try? await store.setFieldValue(docID: subject.doc, field: due, value: "2026-03-04")
            let stored = (try? await store.detail(subject.doc))?.row.values[due.key]
            print("  date field            \(stored ?? "—")")
            Check.that("a date field stores a day, in one spelling", stored == "2026-03-04")
            try? await store.deleteField(id)
        }

        if let id = try? await store.addCustomField(name: "Settled", type: .boolean),
           let flag = ((try? await store.fields()) ?? []).first(where: { $0.fieldID == id }),
           let subject = rows.first {
            try? await store.setFieldValue(docID: subject.doc, field: flag, value: "true")
            let first = (try? await store.detail(subject.doc))?.row.values[flag.key]
            try? await store.setFieldValue(docID: subject.doc, field: flag, value: "yes")
            let second = (try? await store.detail(subject.doc))?.row.values[flag.key]
            Check.that("a yes/no field has one spelling of yes",
                       first == "Yes" && second == "Yes", "\(first ?? "—"), \(second ?? "—")")
            try? await store.deleteField(id)
        }
    }

    static func notes(store: Store, rows: [DocumentRow]) async {
        print("\nNOTES")
        if let subject = rows.first {
            let phrase = "cancelled by phone \(UUID().uuidString.prefix(6).lowercased())"
            try? await store.setNote(phrase, for: subject.doc)
            let kept = (try? await store.note(for: subject.doc)) ?? ""
            let found = (try? await store.listDocuments(selection: .all, query: SearchQuery(phrase),
                                                        sort: .relevance, ascending: false)) ?? []
            print("  " + subject.filename.padded(38) + " searchable: \(found.count) hit(s)")
            Check.that("a note is kept with the document", kept == phrase, kept)
            Check.that("…and is searchable straight away", found.contains { $0.id == subject.id })

            try? await store.setNote("the original is in the red folder\n\ncall them back", for: subject.doc)
            let edited = (try? await store.note(for: subject.doc)) ?? ""
            Check.that("a document has one note, which an edit replaces",
                       edited == "the original is in the red folder\n\ncall them back", edited)
            let stale = (try? await store.listDocuments(selection: .all, query: SearchQuery(phrase),
                                                        sort: .relevance, ascending: false)) ?? []
            Check.that("…and the old wording stops matching", stale.isEmpty, "\(stale.count) hit(s)")

            try? await store.setNote("  \n ", for: subject.doc)
            Check.that("a blank note takes it away again",
                       ((try? await store.note(for: subject.doc)) ?? "x").isEmpty)
        }
    }
}
