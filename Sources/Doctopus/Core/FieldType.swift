import Foundation

/// What a field holds. The value is always kept as text — that is what gets
/// shown, and for `monetary` it is the only place the currency lives — but a
/// declared type gives it a second, typed column that sorting and comparison
/// can actually use. Without one, "€90" sorts after "€1,200", a date cannot be
/// put in order, and a "paid?" field is a string that says "yes" or "Yes"
/// depending on who filled it in.
enum FieldType: String, CaseIterable, Sendable, Codable {
    case string, longtext, url, date, boolean, integer, float, monetary, select

    var label: String {
        switch self {
        case .string: return "Text"
        case .longtext: return "Long Text"
        case .url: return "Link"
        case .date: return "Date"
        case .boolean: return "Yes / No"
        case .integer: return "Whole Number"
        case .float: return "Number"
        case .monetary: return "Amount"
        case .select: return "One Of…"
        }
    }

    var icon: String {
        switch self {
        case .string: return "textformat"
        case .longtext: return "text.alignleft"
        case .url: return "link"
        case .date: return "calendar"
        case .boolean: return "checkmark.square"
        case .integer, .float: return "number"
        case .monetary: return "eurosign.circle"
        case .select: return "list.bullet"
        }
    }

    /// Which column of `field_values` carries the comparable form.
    var storageColumn: String? {
        switch self {
        case .integer, .float, .monetary: return "value_num"
        case .date: return "value_date"
        case .boolean: return "value_bool"
        case .string, .longtext, .url, .select: return nil
        }
    }

    /// True when a value of this type sorts by its number or date rather than
    /// by how it is spelled.
    var sortsTyped: Bool { storageColumn != nil }
}

/// One field value, in both the form a person reads and the form the database
/// can order. `Parsed.text` is nil only when the input was blank, which means
/// "clear this value".
struct FieldValue: Sendable, Equatable {
    var text: String?
    var number: Double?
    var date: Date?
    var boolean: Bool?

    static let empty = FieldValue()
}

extension FieldType {

    /// Reads whatever was typed into a display string plus a comparable form.
    /// A value that cannot be parsed keeps its text and simply has no typed
    /// column, so nothing a person wrote is ever thrown away by the parser
    /// failing to understand it.
    func parse(_ raw: String?) -> FieldValue {
        guard let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return .empty
        }
        switch self {
        case .string, .longtext, .url, .select:
            return FieldValue(text: clean)

        case .boolean:
            guard let flag = FieldType.boolean(from: clean) else { return FieldValue(text: clean) }
            // Stored in one spelling, so "yes", "Yes" and "true" stop being
            // three different values of the same field.
            return FieldValue(text: flag ? "Yes" : "No", boolean: flag)

        case .integer:
            guard let n = FieldType.number(from: clean) else { return FieldValue(text: clean) }
            let whole = n.rounded()
            return FieldValue(text: String(Int64(whole)), number: whole)

        case .float:
            guard let n = FieldType.number(from: clean) else { return FieldValue(text: clean) }
            return FieldValue(text: clean, number: n)

        case .monetary:
            guard let n = FieldType.number(from: clean) else { return FieldValue(text: clean) }
            // The text keeps the currency exactly as it was written; the number
            // is what sorts and sums.
            return FieldValue(text: clean, number: n)

        case .date:
            guard let d = FieldType.day(from: clean) else { return FieldValue(text: clean) }
            return FieldValue(text: FieldType.dayFormatter.string(from: d), date: d)
        }
    }

    static func boolean(from raw: String) -> Bool? {
        switch raw.lowercased() {
        case "y", "yes", "true", "1", "on", "ja", "oui", "sí", "si": return true
        case "n", "no", "false", "0", "off", "nein", "non": return false
        default: return nil
        }
    }

    /// Pulls a number out of text that may carry a currency symbol, a code, and
    /// either convention for grouping and decimals. "€1.234,56" and "$1,234.56"
    /// both come back as 1234.56 — which is the whole point of storing the
    /// number separately from what was typed.
    static func number(from raw: String) -> Double? {
        var digits = raw.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        guard digits.contains(where: \.isNumber) else { return nil }

        let lastDot = digits.lastIndex(of: ".")
        let lastComma = digits.lastIndex(of: ",")
        // Whichever separator comes last is the decimal point — but only if it
        // is followed by one or two digits. "1.234" is a thousand, "1.23" is
        // one and a bit, and a group separator never has fewer than three.
        let decimal: Character?
        switch (lastDot, lastComma) {
        case (nil, nil): decimal = nil
        case (let d?, nil): decimal = digits.distance(from: d, to: digits.endIndex) <= 3 ? "." : nil
        case (nil, let c?): decimal = digits.distance(from: c, to: digits.endIndex) <= 3 ? "," : nil
        case (let d?, let c?): decimal = d > c ? "." : ","
        }

        if let decimal {
            digits = String(digits.map { $0 == decimal ? "." : ($0 == "." || $0 == ",") ? "\u{0}" : $0 })
                .replacingOccurrences(of: "\u{0}", with: "")
        } else {
            digits = digits.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: "")
        }
        // A stray minus anywhere but the front is punctuation, not a sign.
        let negative = digits.hasPrefix("-")
        digits = digits.replacingOccurrences(of: "-", with: "")
        guard let value = Double(digits) else { return nil }
        return negative ? -value : value
    }

    /// A day, from an ISO date or anything `NSDataDetector` recognises. Times
    /// are dropped: a field holding a date holds a day.
    static func day(from raw: String) -> Date? {
        if let iso = dayFormatter.date(from: raw) { return iso }
        if let found = DocumentAnalyzer.dateInText(raw) { return DayDate.startOfDay(found) }
        return nil
    }

    nonisolated(unsafe) static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Days, handled as days.
///
/// A document is issued on a day, not at an instant, and half the off-by-one
/// bugs in an archive come from round-tripping that through a timestamp in a
/// timezone nobody recorded. Everything here works in UTC so the same library
/// reads the same on two Macs.
enum DayDate {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}
