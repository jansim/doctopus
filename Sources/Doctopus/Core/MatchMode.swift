import Foundation

enum MatchMode: Int64, CaseIterable, Sendable, Codable {
    case anyWord = 0
    case allWords = 1
    case exactPhrase = 2
    case regex = 3
    case fuzzy = 4

    var label: String {
        switch self {
        case .anyWord: return "Any of these words"
        case .allWords: return "All of these words"
        case .exactPhrase: return "This exact phrase"
        case .regex: return "Regular expression"
        case .fuzzy: return "Roughly this (for OCR noise)"
        }
    }

    var shortLabel: String {
        switch self {
        case .anyWord: return "Any word"
        case .allWords: return "All words"
        case .exactPhrase: return "Phrase"
        case .regex: return "Regex"
        case .fuzzy: return "Fuzzy"
        }
    }

    static let fuzzyThreshold = 0.9

    /// Edits forgiven outright. A flat 90% ratio rejects one misread letter in an
    /// eight-letter word (`Rechnunq`), exactly the case this mode exists for.
    static func fuzzyEdits(forLength n: Int) -> Int {
        switch n {
        case ..<5: return 0
        case ..<10: return 1
        default: return 2
        }
    }
}

enum PatternMatcher {

    static func matches(_ pattern: String, mode: MatchMode, insensitive: Bool,
                        in subject: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !subject.isEmpty else { return false }
        let hay = insensitive ? subject.lowercased() : subject

        switch mode {
        case .anyWord:
            return terms(in: p, insensitive: insensitive).contains { $0.occurs(in: hay) }
        case .allWords:
            let needles = terms(in: p, insensitive: insensitive)
            return !needles.isEmpty && needles.allSatisfy { $0.occurs(in: hay) }
        case .exactPhrase:
            return phraseRegex(p, insensitive: insensitive)?
                .firstMatch(in: subject, range: NSRange(location: 0, length: (subject as NSString).length)) != nil
        case .regex:
            let options: NSRegularExpression.Options = insensitive ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: p, options: options) else { return false }
            return re.firstMatch(in: subject,
                                 range: NSRange(location: 0, length: (subject as NSString).length)) != nil
        case .fuzzy:
            return terms(in: p, insensitive: insensitive).contains { isNear($0.core, in: hay) }
        }
    }

    /// A whole word, unless a `*` opens a side: `rechnung*`, `*rechnung`, `*rechnung*`.
    struct Term: Equatable {
        var core: String
        var openStart = false
        var openEnd = false

        init(_ raw: String) {
            var t = raw
            if t.hasPrefix("*") { openStart = true; t.removeFirst() }
            if t.hasSuffix("*") { openEnd = true; t.removeLast() }
            core = t.trimmingCharacters(in: .whitespaces)
        }

        func occurs(in hay: String) -> Bool {
            guard !core.isEmpty else { return false }
            var searchStart = hay.startIndex
            while let found = hay.range(of: core, range: searchStart..<hay.endIndex) {
                let startOK = openStart || found.lowerBound == hay.startIndex
                    || !Self.isWordCharacter(hay[hay.index(before: found.lowerBound)])
                let endOK = openEnd || found.upperBound == hay.endIndex
                    || !Self.isWordCharacter(hay[found.upperBound])
                if startOK && endOK { return true }
                searchStart = hay.index(after: found.lowerBound)
            }
            return false
        }

        private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    }

    static func terms(in pattern: String, insensitive: Bool = true) -> [Term] {
        words(in: pattern, insensitive: insensitive).map(Term.init).filter { !$0.core.isEmpty }
    }

    static func words(in pattern: String, insensitive: Bool = true) -> [String] {
        pattern.split(separator: ",")
            .map { insensitive
                ? $0.trimmingCharacters(in: .whitespaces).lowercased()
                : $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func phraseRegex(_ phrase: String, insensitive: Bool) -> NSRegularExpression? {
        let parts = phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        let options: NSRegularExpression.Options = insensitive ? [.caseInsensitive] : []
        return try? NSRegularExpression(pattern: parts.joined(separator: #"\s+"#), options: options)
    }

    /// Only ever run against a document's words, never its whole text: an edit
    /// distance over megabytes of OCR would be far too slow.
    static func isNear(_ needle: String, in hay: String) -> Bool {
        guard !needle.isEmpty else { return false }
        if hay.contains(needle) { return true }
        let allowance = MatchMode.fuzzyEdits(forLength: needle.count)
        guard allowance > 0 else { return false }
        let target = Array(needle)
        for token in hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            guard abs(token.count - needle.count) <= allowance else { continue }
            let edits = distance(target, Array(token))
            if edits <= allowance { return true }
            let longest = max(needle.count, token.count)
            if longest > 0, 1 - Double(edits) / Double(longest) >= MatchMode.fuzzyThreshold {
                return true
            }
        }
        return false
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
