import Foundation

/// The month or year headings the gallery puts over a library sorted by date,
/// the way Photos breaks up its grid. Only the headings are decided here: the
/// rows keep the order the store listed them in.
enum Timeline {
    /// Below this many documents a month on average, a library spanning years
    /// is headed by year instead — a heading over every one or two documents
    /// is more heading than gallery.
    static let documentsPerMonth = 3

    struct Key: Hashable, Sendable {
        var year: Int
        /// Nil when the section is a whole year.
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

    /// The sections, or none when the rows are not in the order of a date:
    /// sorted by name or size, ranked by a search, or listed by when they were
    /// queued or trashed.
    static func sections(_ rows: [DocumentRow], sort: SortField, ranked: Bool) -> [Section] {
        let date: (DocumentRow) -> Date
        let calendar: Calendar
        switch sort {
        case .docDate:
            // The store orders by the stored day, which is a UTC midnight; the
            // local calendar would put the first of a month in the last one.
            date = { $0.docDate ?? $0.createdAt }
            calendar = DayDate.calendar
        case .added, .relevance:
            // Relevance only ranks when there is text to rank by; otherwise it is newest added first.
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

    /// Consecutive rows sharing a key. A key coming back after another one means
    /// the rows were never in date order, and headings would only repeat.
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
