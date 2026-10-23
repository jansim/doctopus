import Foundation

/// A query taken apart for Advanced Search: its words, and a condition for each
/// filter in it. `query` puts it back together in the syntax the search field
/// takes, so a search can be carried on in either.
///
/// A token is a condition here exactly when `SearchQuery` reads it as a filter.
/// Anything else stays among the words as it was typed, so nothing a query says
/// is lost on the way through.
struct SearchCriteria: Equatable, Sendable {
    /// The full-text part, phrases and operators included.
    var words = ""
    /// What a document must not contain, without the minus each carries in the field.
    var excluded = ""
    var conditions: [Condition] = []

    struct Condition: Identifiable, Equatable, Sendable {
        var id = UUID()
        var attribute: Attribute
        var relation: Relation = .is
        var value = ""

        /// Nil until there is a value: `tag:` on its own would match nothing.
        var token: String? {
            let value = self.value.replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            let quoted = value.contains { $0.isWhitespace || $0 == "[" || $0 == "]" }
            return attribute.prefix(relation) + ":" + (quoted ? "\"\(value)\"" : value)
        }
    }

    enum Attribute: Hashable, Sendable {
        case tag, finderTag, folder, fileType, status
        case field(String)
        case documentDate, added, analyzed

        var isDate: Bool { self == .documentDate || self == .added || self == .analyzed }
        var hasFixedValues: Bool { self == .status || self == .fileType }

        /// Only the document date has `before:` and `after:`.
        var relations: [Relation] {
            self == .documentDate ? [.is, .isNot, .before, .after] : [.is, .isNot]
        }

        /// What a condition starts on, for those picked from a list rather than typed.
        var initialValue: String {
            switch self {
            case .status: return SearchQuery.flagPredicates[0].names[0]
            case .fileType: return SearchCriteria.fileTypes[0]
            default: return ""
            }
        }

        func prefix(_ relation: Relation) -> String {
            let name: String
            switch self {
            case .tag: name = "tag"
            case .finderTag: name = "finder"
            case .folder: name = "in"
            case .fileType: name = "ext"
            case .status: name = "is"
            case .field(let key): name = SearchCriteria.fieldPrefixes[key] ?? key
            case .documentDate:
                if relation == .before { return "before" }
                if relation == .after { return "after" }
                name = "date"
            case .added: name = "added"
            case .analyzed: name = "analyzed"
            }
            return relation == .isNot ? "-" + name : name
        }
    }

    enum Relation: Hashable, Sendable {
        case `is`, isNot, before, after
    }

    static let fileTypes = ["pdf", "png", "jpg", "jpeg"]

    /// The alias a built-in field is typed with, so the query reads as it would
    /// have been written.
    private static let fieldPrefixes = ["doc_type": "type", "correspondent": "from", "language": "lang"]

    init() {}

    /// `fieldKeys` as the list hands them to `SearchQuery`, which decides by
    /// them whether a prefix is a field or just a word with a colon in it.
    init(_ raw: String, fieldKeys: Set<String> = []) {
        var words: [String] = [], excluded: [String] = []
        for token in SearchQuery.split(raw) {
            if let condition = Self.condition(token, fieldKeys: fieldKeys) {
                conditions.append(condition)
            } else if let left = Self.excludedWord(token) {
                excluded.append(left)
            } else {
                words.append(token)
            }
        }
        self.words = words.joined(separator: " ")
        self.excluded = excluded.joined(separator: " ")
    }

    var query: String {
        var tokens = SearchQuery.split(Self.closed(words))
        tokens += SearchQuery.split(Self.closed(excluded)).map { $0.hasPrefix("-") ? $0 : "-" + $0 }
        tokens += conditions.compactMap(\.token)
        return tokens.joined(separator: " ")
    }

    private static let quotes = CharacterSet(charactersIn: "\"'")

    /// Follows `SearchQuery.init`, which is what decides what a token means.
    private static func condition(_ token: String, fieldKeys: Set<String>) -> Condition? {
        guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else { return nil }
        var prefix = String(token[..<colon]).lowercased()
        let negated = prefix.hasPrefix("-")
        if negated { prefix.removeFirst() }
        let value = String(token[token.index(after: colon)...]).trimmingCharacters(in: quotes)
        var relation: Relation = negated ? .isNot : .is
        let attribute: Attribute
        switch prefix {
        case "tag": attribute = .tag
        case "finder": attribute = .finderTag
        case "in": attribute = .folder
        case "ext": attribute = .fileType
        case "is": attribute = .status
        case "date", "docdate", "doc_date": attribute = .documentDate
        case "created", "added": attribute = .added
        case "analyzed": attribute = .analyzed
        case "before", "after":
            // "Not before" has no relation of its own, so it stays a word.
            guard !negated else { return nil }
            attribute = .documentDate
            relation = prefix == "before" ? .before : .after
        default:
            let key = SearchQuery.aliases[prefix] ?? prefix
            guard fieldKeys.contains(key) || SearchQuery.aliases[prefix] != nil else { return nil }
            attribute = .field(key)
        }
        return Condition(attribute: attribute, relation: relation, value: value)
    }

    /// A word with a minus, without it. `-"net pay"` keeps its quotes, which
    /// come after the minus, so the phrase is still one when it goes back.
    private static func excludedWord(_ token: String) -> String? {
        if let colon = token.firstIndex(of: ":"), colon != token.startIndex { return nil }
        let unquoted = token.trimmingCharacters(in: quotes)
        guard unquoted.hasPrefix("-"), unquoted.count > 1 else { return nil }
        return token.hasPrefix("-") ? String(token.dropFirst()) : String(unquoted.dropFirst())
    }

    /// Closes a quote or bracket left open, which `split` would otherwise
    /// carry on into the conditions after it and swallow them.
    private static func closed(_ text: String) -> String {
        var quoted = false, bracketed = false
        for ch in text {
            if ch == "\"" { quoted.toggle() }
            else if ch == "[" && !quoted { bracketed = true }
            else if ch == "]" && !quoted { bracketed = false }
        }
        return text + (quoted ? "\"" : "") + (bracketed ? "]" : "")
    }
}
