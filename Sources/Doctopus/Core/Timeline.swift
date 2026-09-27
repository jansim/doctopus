import Foundation

/// Month or year headings for the date-sorted gallery; rows keep the store's order.
enum Timeline {
    /// Below this monthly average, a library spanning years is headed by year.
    static let documentsPerMonth = 3

    struct Key: Hashable, Sendable {
        var year: Int
        /// Nil for a whole year.
        var month: Int?
    }

    struct Section: Identifiable, Sendable {
        var key: Key
        var rows: [DocumentRow]
        var id: Key { key }

        var title: String {
            guard let month = key.month,
                  let first = DayDate.calendar.date(from: DateComponents(year: key.year, month: month, day: 1))
            else { return String(key.year) }
            return Timeline.monthTitle.string(from: first)
        }
    }

    /// Empty when the rows are not in date order.
    static func sections(_ rows: [DocumentRow], sort: SortField, ranked: Bool) -> [Section] {
        let date: (DocumentRow) -> Date
        let calendar: Calendar
        switch sort {
        case .docDate:
            // Stored days are UTC midnights; the local calendar would shift the 1st into the month before.
            date = { $0.docDate ?? $0.createdAt }
            calendar = DayDate.calendar
        case .added, .relevance:
            // Without search text, relevance is newest added first.
            guard sort == .added || !ranked else { return [] }
            date = { $0.createdAt }
            calendar = .current
        default:
            return []
        }
        guard let months = runs(rows, by: { row in
            let c = calendar.dateComponents([.year, .month], from: date(row))
            return Key(year: c.year ?? 0, month: c.month)
        }) else { return [] }

        let years = Set(months.map(\.key.year))
        guard years.count > 1, rows.count < months.count * documentsPerMonth else { return months }
        return runs(rows, by: { Key(year: calendar.component(.year, from: date($0)), month: nil) }) ?? months
    }

    /// Nil when a key recurs, i.e. the rows are not in date order.
    private static func runs(_ rows: [DocumentRow], by key: (DocumentRow) -> Key) -> [Section]? {
        var sections: [Section] = []
        var seen: Set<Key> = []
        for row in rows {
            let k = key(row)
            if sections.last?.key == k {
                sections[sections.count - 1].rows.append(row)
                continue
            }
            guard seen.insert(k).inserted else { return nil }
            sections.append(Section(key: k, rows: [row]))
        }
        return sections
    }

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.calendar = DayDate.calendar
        f.timeZone = DayDate.calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMMy")
        return f
    }()
}
