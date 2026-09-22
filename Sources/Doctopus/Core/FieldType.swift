import Foundation

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

    var storageColumn: String? {
        switch self {
        case .integer, .float, .monetary: return "value_num"
        case .date: return "value_date"
        case .boolean: return "value_bool"
        case .string, .longtext, .url, .select: return nil
        }
    }

    var sortsTyped: Bool { storageColumn != nil }
}

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
        let negative = digits.hasPrefix("-")
        digits = digits.replacingOccurrences(of: "-", with: "")
        guard let value = Double(digits) else { return nil }
        return negative ? -value : value
    }

    static func day(from raw: String) -> Date? {
        if let iso = dayFormatter.date(from: raw) { return iso }
        // A field's date may well be in the future — a due date usually is —
        // so this deliberately does not go through the issue-date reader.
        if let found = DocumentAnalyzer.anyDate(in: raw) { return DayDate.startOfDay(found) }
        return nil
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// `doc_date` is stored as the UTC start of its day, and every reading of it
/// goes through here, so the same library reads the same in every timezone.
enum DayDate {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    static func text(_ date: Date) -> String {
        FieldType.dayFormatter.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        FieldType.dayFormatter.date(from: text)
    }

    static let display: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func display(_ date: Date) -> String { display.string(from: date) }
}

enum DateOrder: String, CaseIterable, Sendable, Codable {
    case automatic, dmy, mdy, ymd

    var label: String {
        switch self {
        case .automatic: return "From the library's language"
        case .dmy: return "Day / Month / Year"
        case .mdy: return "Month / Day / Year"
        case .ymd: return "Year / Month / Day"
        }
    }

    private static let monthFirst: Set<String> = ["en-us", "en_us"]
    private static let yearFirst: Set<String> = ["ja", "zh", "ko", "hu", "lt"]

    func resolved(language: String?) -> DateOrder {
        guard self == .automatic else { return self }
        guard let code = language?.lowercased().nilIfBlank else { return .dmy }
        if DateOrder.yearFirst.contains(String(code.prefix(2))) { return .ymd }
        if DateOrder.monthFirst.contains(code) { return .mdy }
        return .dmy
    }
}

struct DateCandidate: Identifiable, Hashable, Sendable {
    var date: Date
    var source: String
    var labelled: Bool
    var cue: String?

    var id: String { "\(DayDate.text(date))#\(source)" }

    var sourceLabel: String {
        switch source {
        case "ocr": return "in the text"
        case "pdf": return "from the PDF"
        case "exif": return "from EXIF"
        case "filename": return "from the name"
        default: return source
        }
    }
}
