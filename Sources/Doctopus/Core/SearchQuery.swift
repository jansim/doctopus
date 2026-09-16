import Foundation

/// Parses the center-pane search field into FTS5 terms plus structured token
/// filters (`tag:`, `-tag:`, `finder:`, `in:`, `ext:`, `is:`, `date:`, `created:`,
/// `added:`, `before:`, `after:`, and one token per field — `type:`, `from:`,
/// `lang:` and custom fields).
struct SearchQuery: Sendable, Equatable {
    var terms: [String] = []
    var negatedTerms: [String] = []
    var tags: [String] = []
    var negatedTags: [String] = []
    var finderTags: [String] = []
    var negatedFinderTags: [String] = []
    var folders: [String] = []
    var negatedFolders: [String] = []
    var exts: [String] = []
    var negatedExts: [String] = []
    var flags: Set<String> = []
    var negatedFlags: Set<String> = []
    var fieldFilters: [FieldFilter] = []
    var negatedFieldFilters: [FieldFilter] = []
    var dateFilters: [DateFilter] = []

    struct FieldFilter: Sendable, Equatable, Hashable {
        var key: String
        var value: String
    }

    struct DateFilter: Sendable, Equatable, Hashable {
        var column: String   // "m.doc_date" or "d.created_at"
        var start: Date?
        var end: Date?
        var negated: Bool = false
    }

    /// Shorthands kept stable regardless of how a field is renamed.
    static let aliases: [String: String] = [
        "type": "doc_type", "from": "correspondent", "lang": "language",
        "language": "language", "correspondent": "correspondent", "amount": "amount",
    ]

    static let reserved: Set<String> = [
        "tag", "finder", "in", "ext", "is", "date", "created", "added", "before", "after", "docdate"
    ]

    var isEmpty: Bool {
        terms.isEmpty && negatedTerms.isEmpty && tags.isEmpty && negatedTags.isEmpty
            && finderTags.isEmpty && negatedFinderTags.isEmpty && folders.isEmpty
            && negatedFolders.isEmpty && exts.isEmpty && negatedExts.isEmpty
            && flags.isEmpty && negatedFlags.isEmpty && fieldFilters.isEmpty
            && negatedFieldFilters.isEmpty && dateFilters.isEmpty
    }
    var hasText: Bool { !terms.isEmpty }

    /// `fieldKeys` are the currently configured field keys; a `word:` token is
    /// only treated as a filter when it resolves to one, so a stray colon in a
    /// search term still behaves like text.
    init(_ raw: String, fieldKeys: Set<String> = []) {
        for token in SearchQuery.split(raw) {
            let unquoted = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                if unquoted.hasPrefix("-") && unquoted.count > 1 {
                    negatedTerms.append(String(unquoted.dropFirst()))
                } else if !unquoted.isEmpty {
                    terms.append(unquoted)
                }
                continue
            }
            var prefix = String(token[token.startIndex..<colon]).lowercased()
            let isNegated = prefix.hasPrefix("-")
            if isNegated { prefix = String(prefix.dropFirst()) }
            let value = String(token[token.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch prefix {
            case "tag":
                if isNegated { negatedTags.append(value) } else { tags.append(value) }
            case "finder":
                if isNegated { negatedFinderTags.append(value) } else { finderTags.append(value) }
            case "in":
                if isNegated { negatedFolders.append(value) } else { folders.append(value) }
            case "ext":
                let v = value.lowercased()
                if isNegated { negatedExts.append(v) } else { exts.append(v) }
            case "is":
                let f = value.lowercased()
                if isNegated { negatedFlags.insert(f) } else { flags.insert(f) }
            case "date", "docdate", "doc_date":
                if let range = SearchDateParser.parse(value) {
                    dateFilters.append(DateFilter(column: "COALESCE(m.doc_date, d.created_at)", start: range.start, end: range.end, negated: isNegated))
                }
            case "created", "added":
                if let range = SearchDateParser.parse(value) {
                    dateFilters.append(DateFilter(column: "d.created_at", start: range.start, end: range.end, negated: isNegated))
                }
            case "before":
                if let range = SearchDateParser.parse(value), let cutoff = range.start ?? range.end {
                    dateFilters.append(DateFilter(column: "COALESCE(m.doc_date, d.created_at)", start: nil, end: cutoff.addingTimeInterval(-1), negated: isNegated))
                }
            case "after":
                if let range = SearchDateParser.parse(value), let cutoff = range.end ?? range.start {
                    dateFilters.append(DateFilter(column: "COALESCE(m.doc_date, d.created_at)", start: cutoff.addingTimeInterval(1), end: nil, negated: isNegated))
                }
            default:
                let key = SearchQuery.aliases[prefix] ?? prefix
                if fieldKeys.contains(key) || SearchQuery.aliases[prefix] != nil {
                    let filter = FieldFilter(key: key, value: value)
                    if isNegated { negatedFieldFilters.append(filter) } else { fieldFilters.append(filter) }
                } else if !unquoted.isEmpty {
                    terms.append(unquoted)
                }
            }
        }
    }

    /// Splits on whitespace while honouring double quotes and brackets.
    private static func split(_ raw: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var inBracket = false
        for ch in raw {
            if ch == "\"" { quoted.toggle(); cur.append(ch) }
            else if ch == "[" && !quoted { inBracket = true; cur.append(ch) }
            else if ch == "]" && !quoted { inBracket = false; cur.append(ch) }
            else if ch.isWhitespace && !quoted && !inBracket {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// FTS5 MATCH expression: each term becomes a prefix query, supporting boolean operators.
    /// Negated terms are excluded, not included here — FTS5's `NOT` is a binary
    /// exclusion operator with no valid standalone form, so `negatedTerms` are
    /// applied separately as `NOT IN` subqueries against `doc_fts`.
    var ftsExpression: String? {
        guard !terms.isEmpty else { return nil }
        var parts: [String] = []
        for term in terms {
            let cleaned = term.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            let upper = cleaned.uppercased()
            if upper == "AND" || upper == "OR" || upper == "NOT" {
                parts.append(upper)
            } else if cleaned == "(" || cleaned == ")" {
                parts.append(cleaned)
            } else if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
                parts.append(cleaned)
            } else {
                let unquoted = cleaned.replacingOccurrences(of: "\"", with: "")
                if unquoted.contains(" ") {
                    parts.append("\"\(unquoted)\"")
                } else {
                    parts.append("\"\(unquoted)\"*")
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        let hasBool = parts.contains { $0 == "AND" || $0 == "OR" || $0 == "NOT" || $0 == "(" || $0 == ")" }
        if !hasBool {
            return parts.joined(separator: " AND ")
        }
        return parts.joined(separator: " ")
    }
}

enum SearchDateParser {
    static func parse(_ raw: String, now: Date = Date()) -> (start: Date?, end: Date?)? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]"))
        let lower = trimmed.lowercased()
        let cal = DayDate.calendar

        // Relative keywords
        if lower == "today" {
            let start = DayDate.startOfDay(now)
            let end = cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1)
            return (start, end)
        }
        if lower == "yesterday" {
            guard let start = cal.date(byAdding: .day, value: -1, to: DayDate.startOfDay(now)) else { return nil }
            let end = cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1)
            return (start, end)
        }
        if lower == "this week" {
            guard let interval = cal.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return (interval.start, interval.end.addingTimeInterval(-1))
        }
        if lower == "last week" || lower == "previous week" {
            guard let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start,
                  let prevStart = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) else { return nil }
            let end = thisWeekStart.addingTimeInterval(-1)
            return (prevStart, end)
        }
        if lower == "this month" {
            guard let interval = cal.dateInterval(of: .month, for: now) else { return nil }
            return (interval.start, interval.end.addingTimeInterval(-1))
        }
        if lower == "last month" || lower == "previous month" {
            guard let thisMonthStart = cal.dateInterval(of: .month, for: now)?.start,
                  let prevStart = cal.date(byAdding: .month, value: -1, to: thisMonthStart) else { return nil }
            let end = thisMonthStart.addingTimeInterval(-1)
            return (prevStart, end)
        }
        if lower == "this year" {
            guard let interval = cal.dateInterval(of: .year, for: now) else { return nil }
            return (interval.start, interval.end.addingTimeInterval(-1))
        }
        if lower == "last year" || lower == "previous year" {
            guard let thisYearStart = cal.dateInterval(of: .year, for: now)?.start,
                  let prevStart = cal.date(byAdding: .year, value: -1, to: thisYearStart) else { return nil }
            let end = thisYearStart.addingTimeInterval(-1)
            return (prevStart, end)
        }
        if lower == "this quarter" {
            guard let interval = cal.dateInterval(of: .quarter, for: now) else { return nil }
            return (interval.start, interval.end.addingTimeInterval(-1))
        }
        if lower == "last quarter" || lower == "previous quarter" {
            guard let thisQStart = cal.dateInterval(of: .quarter, for: now)?.start,
                  let prevStart = cal.date(byAdding: .quarter, value: -1, to: thisQStart) else { return nil }
            let end = thisQStart.addingTimeInterval(-1)
            return (prevStart, end)
        }

        // Range syntax: "A to B" or "A..B"
        let parts: [String]
        if trimmed.contains(" to ") {
            parts = trimmed.components(separatedBy: " to ")
        } else if trimmed.contains("..") {
            parts = trimmed.components(separatedBy: "..")
        } else {
            parts = []
        }
        if parts.count == 2 {
            let s = parse(parts[0], now: now)?.start
            let e = parse(parts[1], now: now)?.end
            return (s, e)
        }

        // Specific Year: "2026"
        if let year = Int(trimmed), year >= 1900 && year <= 2100 {
            var comps = DateComponents()
            comps.year = year
            comps.month = 1
            comps.day = 1
            guard let start = cal.date(from: comps) else { return nil }
            guard let end = cal.date(byAdding: .year, value: 1, to: start)?.addingTimeInterval(-1) else { return nil }
            return (start, end)
        }

        // Year-Month: "2026-03"
        let ymParts = trimmed.split(separator: "-")
        if ymParts.count == 2, let y = Int(ymParts[0]), let m = Int(ymParts[1]), m >= 1 && m <= 12 {
            var comps = DateComponents()
            comps.year = y
            comps.month = m
            comps.day = 1
            guard let start = cal.date(from: comps) else { return nil }
            guard let end = cal.date(byAdding: .month, value: 1, to: start)?.addingTimeInterval(-1) else { return nil }
            return (start, end)
        }

        // ISO Day: "2026-03-04"
        if let dayDate = DayDate.parse(trimmed) {
            let start = DayDate.startOfDay(dayDate)
            let end = cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1)
            return (start, end)
        }

        return nil
    }
}
