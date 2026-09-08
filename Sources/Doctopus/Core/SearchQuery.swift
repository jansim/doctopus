import Foundation

/// Parses the center-pane search field into FTS5 terms plus structured token
/// filters (`tag:`, `finder:`, `in:`, `ext:`, `is:`, and one token per field —
/// `type:`, `from:`, `lang:` and anything the user adds).
struct SearchQuery: Sendable, Equatable {
    var terms: [String] = []
    var tags: [String] = []
    /// The Finder's tags, searched with `finder:` to keep them distinct from
    /// Doctopus's own `tag:`.
    var finderTags: [String] = []
    var folders: [String] = []
    var exts: [String] = []
    var flags: Set<String> = []
    /// (field key, value) pairs, e.g. ("doc_type", "Invoice").
    var fieldFilters: [FieldFilter] = []

    struct FieldFilter: Sendable, Equatable, Hashable {
        var key: String
        var value: String
    }

    /// Shorthands kept stable regardless of how a field is renamed.
    static let aliases: [String: String] = [
        "type": "doc_type", "from": "correspondent", "lang": "language",
        "language": "language", "correspondent": "correspondent", "amount": "amount",
    ]

    static let reserved: Set<String> = ["tag", "finder", "in", "ext", "is"]

    var isEmpty: Bool {
        terms.isEmpty && tags.isEmpty && finderTags.isEmpty && folders.isEmpty
            && exts.isEmpty && flags.isEmpty && fieldFilters.isEmpty
    }
    var hasText: Bool { !terms.isEmpty }

    /// `fieldKeys` are the currently configured field keys; a `word:` token is
    /// only treated as a filter when it resolves to one, so a stray colon in a
    /// search term still behaves like text.
    init(_ raw: String, fieldKeys: Set<String> = []) {
        for token in SearchQuery.split(raw) {
            let unquoted = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                if !unquoted.isEmpty { terms.append(unquoted) }
                continue
            }
            let prefix = String(token[token.startIndex..<colon]).lowercased()
            let value = String(token[token.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch prefix {
            case "tag": tags.append(value)
            case "finder": finderTags.append(value)
            case "in": folders.append(value)
            case "ext": exts.append(value.lowercased())
            case "is": flags.insert(value.lowercased())
            default:
                let key = SearchQuery.aliases[prefix] ?? prefix
                if fieldKeys.contains(key) || SearchQuery.aliases[prefix] != nil {
                    fieldFilters.append(FieldFilter(key: key, value: value))
                } else if !unquoted.isEmpty {
                    terms.append(unquoted)
                }
            }
        }
    }

    /// Splits on whitespace while honouring double quotes.
    private static func split(_ raw: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in raw {
            if ch == "\"" { quoted.toggle(); cur.append(ch) }
            else if ch.isWhitespace && !quoted {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// FTS5 MATCH expression: each term becomes a quoted prefix query, ANDed.
    var ftsExpression: String? {
        guard !terms.isEmpty else { return nil }
        let parts: [String] = terms.compactMap { term in
            let cleaned = term.replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return nil }
            if cleaned.contains(" ") { return "\"\(cleaned)\"" }
            return "\"\(cleaned)\"*"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    /// Fallback LIKE patterns for matching filenames/titles that never hit OCR.
    var likePatterns: [String] { terms.map { "%\($0)%" } }
}
