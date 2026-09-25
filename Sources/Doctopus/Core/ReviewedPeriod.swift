import Foundation

/// How long ago a document was approved, as Recently Reviewed groups it. An
/// approval older than the last period has left Recently Reviewed altogether:
/// by then it is simply part of the library.
enum ReviewedPeriod: Int, CaseIterable, Identifiable, Sendable {
    case lastWeek = 7
    case lastMonth = 30

    var id: Int { rawValue }
    var days: Int { rawValue }

    var title: String {
        switch self {
        case .lastWeek: return "Last 7 Days"
        case .lastMonth: return "Last 30 Days"
        }
    }

    /// Counted in whole days back from now rather than calendar days, so the
    /// store's cut-off and the grouping agree to the second.
    func start(before now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// The oldest approval Recently Reviewed still lists.
    static func cutoff(before now: Date) -> Date {
        allCases.last!.start(before: now)
    }

    static func of(_ reviewed: Date, now: Date) -> ReviewedPeriod? {
        allCases.first { reviewed >= $0.start(before: now) }
    }

    struct Group: Identifiable, Sendable {
        var period: ReviewedPeriod
        var rows: [DocumentRow]
        var id: ReviewedPeriod { period }
    }

    /// Recently Reviewed's rows under their periods, in the order they came;
    /// empty periods are left out, and so is a row that aged out since it was listed.
    static func groups(_ rows: [DocumentRow], now: Date) -> [Group] {
        var byPeriod: [ReviewedPeriod: [DocumentRow]] = [:]
        for row in rows {
            guard let at = row.queue?.at, let period = of(at, now: now) else { continue }
            byPeriod[period, default: []].append(row)
        }
        return allCases.compactMap { period in
            byPeriod[period].map { Group(period: period, rows: $0) }
        }
    }
}
