import Foundation

/// What is read off a document: its dates, and the name it is filed under.
extension SelfTest {
    static func renamePreview(rows: [DocumentRow]) {
        print("\nRENAME PREVIEW (\(Naming.defaultTemplate))")
        for row in rows.prefix(4) {
            let ctx = Naming.Context(date: row.docDate ?? row.createdAt, correspondent: row.correspondent,
                                     title: row.title, docType: row.docType, language: row.language,
                                     counter: 1, originalStem: row.url.deletingPathExtension().lastPathComponent,
                                     ext: row.url.pathExtension)
            print("  \(row.filename.padded(38)) → \(Naming.render(Naming.defaultTemplate, ctx))")
        }
        let fallbackCtx = Naming.Context(date: nil, correspondent: nil, title: "..", docType: nil,
                                         language: nil, counter: nil, originalStem: ".hidden", ext: "pdf")
        let renderedDefault = Naming.render("{correspondent|Unknown}_{title}", fallbackCtx)
        Check.that("template conditional fallback renders default", renderedDefault.hasPrefix("Unknown"))
        Check.that("path safety cleans invalid or hidden stems", !renderedDefault.hasPrefix(".") && !renderedDefault.contains(".."))
        var foldCtx = Naming.Context(date: DayDate.calendar.date(from: DateComponents(year: 2026, month: 3, day: 14)),
                                     correspondent: "Mu\u{308}ller Straße GmbH", title: "Café Ångström ½",
                                     docType: nil, language: nil, counter: nil, originalStem: "scan", ext: "pdf")
        let unfolded = Naming.render(Naming.defaultTemplate, foldCtx)
        Check.that("filenames keep spaces and accents unless asked", unfolded == "2026-03-14_Mu\u{308}ller Straße GmbH_Café Ångström ½.pdf", unfolded)
        foldCtx.options = Naming.Options(underscoresForSpaces: true, asciiOnly: true)
        let folded = Naming.render(Naming.defaultTemplate, foldCtx)
        Check.that("filenames can be folded to ASCII with underscores",
                   folded == "2026-03-14_Mueller_Strasse_GmbH_Cafe_Angstroem_1_2.pdf", folded)
    }

    static func dates(store: Store, rows: [DocumentRow]) async {
        print("\nDATES")
        let ambiguous = "Rechnungsdatum: 03/04/2026"
        let asDMY = DocumentAnalyzer.dateInText(ambiguous,
            options: DocumentAnalyzer.Options(dateOrder: .dmy))
        let asMDY = DocumentAnalyzer.dateInText(ambiguous,
            options: DocumentAnalyzer.Options(dateOrder: .mdy))
        print("  03/04/2026 as D/M/Y    \(asDMY.map(DayDate.text) ?? "—")")
        print("  03/04/2026 as M/D/Y    \(asMDY.map(DayDate.text) ?? "—")")
        Check.that("an ambiguous date is read the way the library says",
                   asDMY.map(DayDate.text) == "2026-04-03" && asMDY.map(DayDate.text) == "2026-03-04")
        Check.that("automatic takes the order from the language, not from this Mac",
                   DateOrder.automatic.resolved(language: "en-US") == .mdy
                       && DateOrder.automatic.resolved(language: "de") == .dmy
                       && DateOrder.automatic.resolved(language: "ja") == .ymd)
        Check.that("a number over twelve settles the order whatever it is set to",
                   DocumentAnalyzer.dateInText("dated 25/12/2025",
                       options: DocumentAnalyzer.Options(dateOrder: .mdy)).map(DayDate.text)
                       == "2025-12-25")

        let nextYear = DayDate.calendar.date(byAdding: .year, value: 1, to: Date())!
        let yetToCome = "Datum: \(DayDate.text(nextYear))"
        Check.that("a document is never issued in the future",
                   DocumentAnalyzer.dateInText(yetToCome) == nil,
                   DocumentAnalyzer.dateInText(yetToCome).map(DayDate.text) ?? "none")
        Check.that("…but a field holding a due date may still be",
                   DocumentAnalyzer.anyDate(in: yetToCome).map(DayDate.text) == DayDate.text(nextYear))

        let letterhead = "Formular Stand: 12/01/2019 · Rechnungsdatum: 14/02/2024"
        let ignoring = DocumentAnalyzer.Options(dateOrder: .dmy, ignoredDays: ["2019-01-12"])
        Check.that("an ignored day is never taken as the document's date",
                   DocumentAnalyzer.datesInText(letterhead, source: "ocr", options: ignoring)
                       .allSatisfy { DayDate.text($0.date) != "2019-01-12" })

        let several = "Printed 01/02/2020. Rechnungsdatum: 14/02/2024. Paid 20/02/2024."
        let candidates = DocumentAnalyzer.rank(
            DocumentAnalyzer.datesInText(several, source: "ocr",
                                         options: DocumentAnalyzer.Options(dateOrder: .dmy)))
        let shownCandidates: [String] = candidates.map {
            DayDate.text($0.date) + ($0.labelled ? "*" : "")
        }
        print("  candidates             " + shownCandidates.joined(separator: ", "))
        Check.that("every plausible date is kept, the labelled one first",
                   candidates.count > 1 && candidates.first?.labelled == true
                       && candidates.first.map { DayDate.text($0.date) } == "2024-02-14",
                   "\(candidates.count) candidates")
        Check.that("a day the month does not have is a misread, not a date",
                   DocumentAnalyzer.dateInText("31/02/2024",
                       options: DocumentAnalyzer.Options(dateOrder: .dmy)) == nil)

        let stored = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                      sort: .added, ascending: false)) ?? [])
            .compactMap(\.docDate)
        Check.that("every stored date is the start of a day",
                   stored.allSatisfy { $0 == DayDate.startOfDay($0) },
                   "\(stored.count) dates")

        if let subject = rows.first {
            let kept = (try? await store.dateCandidates(for: subject.doc)) ?? []
            print("  \(subject.filename.padded(38)) \(kept.count) candidate(s) kept")
            Check.that("the dates a document offered are kept for the review",
                       !kept.isEmpty || subject.docDate == nil)
        }
    }
}
