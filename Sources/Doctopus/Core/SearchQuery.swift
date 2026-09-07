import Foundation

/// Parses the center-pane search field into FTS5 terms plus structured token
/// filters (`tag:`, `from:`, `type:`, `lang:`, `in:`, `ext:`, `is:`).
struct SearchQuery: Sendable, Equatable {
    var terms: [String] = []
    var tags: [String] = []
    var correspondents: [String] = []
    var docTypes: [String] = []
    var languages: [String] = []
    var folders: [String] = []
    var exts: [String] = []
    var flags: Set<String> = []

    var isEmpty: Bool {
        terms.isEmpty && tags.isEmpty && correspondents.isEmpty && docTypes.isEmpty
            && languages.isEmpty && folders.isEmpty && exts.isEmpty && flags.isEmpty
    }
    var hasText: Bool { !terms.isEmpty }

    static let tokenPrefixes = ["tag:", "from:", "type:", "lang:", "in:", "ext:", "is:"]

    init(_ raw: String) {
        for token in SearchQuery.split(raw) {
            let lower = token.lowercased()
            func value(_ p: String) -> String {
                String(token.dropFirst(p.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            switch true {
            case lower.hasPrefix("tag:"):   tags.append(value("tag:"))
            case lower.hasPrefix("from:"):  correspondents.append(value("from:"))
            case lower.hasPrefix("type:"):  docTypes.append(value("type:"))
            case lower.hasPrefix("lang:"):  languages.append(value("lang:"))
            case lower.hasPrefix("in:"):    folders.append(value("in:"))
            case lower.hasPrefix("ext:"):   exts.append(value("ext:").lowercased())
            case lower.hasPrefix("is:"):    flags.insert(value("is:").lowercased())
            default:
                let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !t.isEmpty { terms.append(t) }
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
            // Strip characters FTS5 treats as syntax; quoting handles the rest.
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
