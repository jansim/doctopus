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
        let balanced = SearchQuery.balance(parts)
        guard !balanced.isEmpty else { return nil }
        let hasBool = balanced.contains { SearchQuery.isFTSOperator($0) || $0 == "(" || $0 == ")" }
        if !hasBool {
            return balanced.joined(separator: " AND ")
        }
        return balanced.joined(separator: " ")
    }

    private static func isFTSOperator(_ t: String) -> Bool { t == "AND" || t == "OR" || t == "NOT" }

    /// An expression is read while it is still being typed, so it passes
    /// through states like `foo and` or `(foo or`. FTS5 rejects those outright,
    /// and the resulting throw blanks the whole document list — so an operator
    /// with nothing to operate on, and a bracket with no partner, are dropped
    /// here rather than handed to SQLite.
    private static func balance(_ parts: [String]) -> [String] {
        var out: [String] = []
        var depth = 0
        // Whether the next token has to be an operand: true at the start, after
        // an operator, and just inside an opening bracket.
        var expectsOperand = true
        for token in parts {
            if isFTSOperator(token) {
                guard !expectsOperand else { continue }
                out.append(token)
                expectsOperand = true
            } else if token == "(" {
                out.append(token)
                depth += 1
                expectsOperand = true
            } else if token == ")" {
                // Nothing open, or nothing in it yet.
                guard depth > 0, !expectsOperand else { continue }
                out.append(token)
                depth -= 1
                expectsOperand = false
            } else {
                out.append(token)
                expectsOperand = false
            }
        }
        // Whatever the cursor left dangling: a trailing operator, or a bracket
        // opened with nothing after it.
        while let last = out.last, isFTSOperator(last) || last == "(" {
            if last == "(" { depth -= 1 }
            out.removeLast()
        }
        out.append(contentsOf: Array(repeating: ")", count: max(0, depth)))
        return out
    }
}

enum SearchDateParser {
    static func parse(_ raw: String, now: Date = Date()) -> (start: Date?, end: Date?)? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]"))
        let lower = trimmed.lowercased()
        let cal = DayDate.calendar

        // Relative keywords: "today", "yesterday", and "this"/"last" plus a unit.
        if let range = relative(lower, now: now) { return range }

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

    /// The calendar unit each keyword spans. Every relative range is the same
    /// two questions — which unit, and this one or the one before it — so they
    /// are asked once here rather than spelled out per keyword.
    private static let units: [String: Calendar.Component] = [
        "week": .weekOfYear, "month": .month, "quarter": .quarter, "year": .year,
    ]

    private static func relative(_ keyword: String, now: Date) -> (start: Date?, end: Date?)? {
        let unit: Calendar.Component
        let previous: Bool
        switch keyword {
        case "today":
            (unit, previous) = (.day, false)
        case "yesterday":
            (unit, previous) = (.day, true)
        default:
            let words = keyword.split(separator: " ")
            guard words.count == 2, let named = units[String(words[1])] else { return nil }
            switch words[0] {
            case "this": (unit, previous) = (named, false)
            case "last", "previous": (unit, previous) = (named, true)
            default: return nil
            }
        }
        let cal = DayDate.calendar
        guard let current = cal.dateInterval(of: unit, for: now) else { return nil }
        guard previous else { return (current.start, current.end.addingTimeInterval(-1)) }
        guard let start = cal.date(byAdding: unit, value: -1, to: current.start) else { return nil }
        return (start, current.start.addingTimeInterval(-1))
    }
}
