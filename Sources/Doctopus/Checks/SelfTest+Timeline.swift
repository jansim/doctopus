import Foundation

/// The gallery heads a date-sorted library by month, or by year once months get sparse.
extension SelfTest {
    static func timeline(rows: [DocumentRow]) {
        print("\nTIMELINE (gallery headings)")
        guard let template = rows.first else {
            Check.that("a document to date", false)
            return
        }
        func dated(_ year: Int, _ month: Int, _ day: Int = 15) -> DocumentRow {
            var row = template
            row.doc = Int64(year * 10_000 + month * 100 + day)
            row.docDate = DayDate.calendar.date(from: DateComponents(year: year, month: month, day: day))
            return row
        }

        // Newest first, as the store lists them; three a month keeps months.
        let dense = [dated(2026, 9, 20), dated(2026, 9, 10), dated(2026, 9, 1),
                     dated(2026, 8, 30), dated(2026, 8, 12), dated(2026, 8, 2),
                     dated(2025, 12, 31), dated(2025, 12, 5), dated(2025, 12, 1)]
        let months = Timeline.sections(dense, sort: .docDate, ranked: false)
        Check.that("a well-filled library is headed by month",
                   months.map(\.key) == [.init(year: 2026, month: 9), .init(year: 2026, month: 8),
                                         .init(year: 2025, month: 12)],
                   months.map(\.title).joined(separator: ", "))
        Check.that("the headings keep the rows in the store's order",
                   months.flatMap(\.rows).map(\.doc) == dense.map(\.doc))
        Check.that("the first of a month is in that month, not the one before",
                   months.first?.rows.contains { $0.doc == dated(2026, 9, 1).doc } == true)
        Check.that("a month's title names its year",
                   months.first?.title.contains("2026") == true, months.first?.title ?? "none")

        let sparse = [dated(2026, 9, 1), dated(2025, 6, 1), dated(2025, 2, 1), dated(2023, 11, 1)]
        let years = Timeline.sections(sparse, sort: .docDate, ranked: false)
        Check.that("a sparse library spanning years is headed by year",
                   years.map(\.title) == ["2026", "2025", "2023"],
                   years.map(\.title).joined(separator: ", "))

        let oneYear = [dated(2026, 9, 1), dated(2026, 3, 1)]
        Check.that("but a sparse one within a year still by month",
                   Timeline.sections(oneYear, sort: .docDate, ranked: false).count == 2)

        Check.that("no headings when sorted by name",
                   Timeline.sections(dense, sort: .name, ranked: false).isEmpty)
        Check.that("nor when ranked by a search",
                   Timeline.sections(dense, sort: .relevance, ranked: true).isEmpty)
        Check.that("nor when the rows are not in date order",
                   Timeline.sections([dated(2026, 9, 1), dated(2025, 1, 1), dated(2026, 9, 2)],
                                     sort: .docDate, ranked: false).isEmpty)
    }
}
