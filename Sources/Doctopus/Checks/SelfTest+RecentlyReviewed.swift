import Foundation

/// Recently Reviewed keeps a month of approvals, the last week apart from the rest.
extension SelfTest {
    static func recentlyReviewedPeriods(store: Store) async {
        print("\nRECENTLY REVIEWED (last 7 days, last 30 days)")
        let day: TimeInterval = 86_400
        let now = Date()
        Check.that("an approval under a week old is in the last 7 days",
                   ReviewedPeriod.of(now.addingTimeInterval(-7 * day + 60), now: now) == .lastWeek)
        Check.that("one just over a week old is in the last 30 days",
                   ReviewedPeriod.of(now.addingTimeInterval(-7 * day - 60), now: now) == .lastMonth)
        Check.that("one over 30 days old is in neither",
                   ReviewedPeriod.of(now.addingTimeInterval(-30 * day - 60), now: now) == nil)

        let current = (try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                      sort: .added, ascending: false)) ?? []
        guard current.count >= 3 else {
            Check.that("three documents to approve at different times", false, "\(current.count)")
            return
        }
        let week = current[0], month = current[1], older = current[2]
        try? await store.setDocumentApproved(week.doc, true, at: now.addingTimeInterval(-2 * day))
        try? await store.setDocumentApproved(month.doc, true, at: now.addingTimeInterval(-12 * day))
        try? await store.setDocumentApproved(older.doc, true, at: now.addingTimeInterval(-45 * day))

        let listed = (try? await store.listDocuments(selection: .reviewed, query: SearchQuery(""),
                                                     sort: .added, ascending: false)) ?? []
        let ids = listed.map(\.doc)
        Check.that("an approval from the last 30 days stays in Recently Reviewed",
                   ids.contains(week.doc) && ids.contains(month.doc))
        Check.that("one older than 30 days has left it", !ids.contains(older.doc))

        let groups = ReviewedPeriod.groups(listed, now: .now)
        let inWeek = groups.first { $0.period == .lastWeek }?.rows.map(\.doc) ?? []
        let inMonth = groups.first { $0.period == .lastMonth }?.rows.map(\.doc) ?? []
        Check.that("Recently Reviewed groups the last 7 days apart from the last 30",
                   groups.map(\.period) == [.lastWeek, .lastMonth]
                       && inWeek.contains(week.doc) && !inWeek.contains(month.doc)
                       && inMonth.contains(month.doc) && !inMonth.contains(week.doc),
                   groups.map { "\($0.period.title): \($0.rows.count)" }.joined(separator: ", "))
        Check.that("each group keeps the newest approval first",
                   groups.flatMap(\.rows).map(\.doc) == ids)

        // Put them back as they were, so later sections see the library they expect.
        for row in [week, month, older] {
            try? await store.setDocumentApproved(row.doc, row.approved)
        }
    }
}
