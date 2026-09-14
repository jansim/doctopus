import Foundation

/// How a rule's pattern is read.
///
/// The router used to work this out from the punctuation: anything containing
/// `^$*+?[]()|\` became a regular expression. That made `Acme (UK) Ltd` a
/// regex nobody asked for, and turned `Betrag: 100€ +` into a regex that fails
/// to compile and silently falls back to word matching. The rule editor's
/// preview was honest about all of it, which is good design covering for a bad
/// default. This is the default being fixed instead.
enum MatchMode: Int64, CaseIterable, Sendable, Codable {
    /// Any of the comma-separated words, matched at the start of a word.
    case anyWord = 0
    /// Every one of them, anywhere in the subject.
    case allWords = 1
    /// The pattern as one phrase, tolerating the line breaks OCR puts in it.
    case exactPhrase = 2
    case regex = 3
    /// Close enough, for OCR noise: `Rechnunq` still matches `Rechnung`.
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

    /// What the router used to guess. Kept for one purpose only: migrating the
    /// rules that were written when guessing was all there was.
    static func inferred(from pattern: String) -> MatchMode {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return .anyWord }
        guard p.rangeOfCharacter(from: CharacterSet(charactersIn: "^$*+?[]()|\\")) != nil else {
            return .anyWord
        }
        return (try? NSRegularExpression(pattern: p, options: [])) != nil ? .regex : .anyWord
    }

    /// How close two strings have to be, as a percentage, for `fuzzy` to call
    /// it a match. Paperless uses rapidfuzz's `partial_ratio >= 90`; the same
    /// number, computed the same way, over an edit distance.
    static let fuzzyThreshold = 0.9
}

/// The matching itself, kept out of `Router` so the rule editor's preview and
/// the router can never disagree about what a pattern does.
enum PatternMatcher {

    /// True when `pattern`, read as `mode`, matches `subject`.
    static func matches(_ pattern: String, mode: MatchMode, insensitive: Bool,
                        in subject: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !subject.isEmpty else { return false }
        let hay = insensitive ? subject.lowercased() : subject

        switch mode {
        case .anyWord:
            return words(in: p, insensitive: insensitive).contains { hay.startsWithWord($0) }
        case .allWords:
            let needles = words(in: p, insensitive: insensitive)
            return !needles.isEmpty && needles.allSatisfy { hay.startsWithWord($0) }
        case .exactPhrase:
            return phraseRegex(p, insensitive: insensitive)?
                .firstMatch(in: subject, range: NSRange(location: 0, length: (subject as NSString).length)) != nil
        case .regex:
            let options: NSRegularExpression.Options = insensitive ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: p, options: options) else { return false }
            return re.firstMatch(in: subject,
                                 range: NSRange(location: 0, length: (subject as NSString).length)) != nil
        case .fuzzy:
            return words(in: p, insensitive: insensitive).contains {
                partialRatio(of: $0, in: hay) >= MatchMode.fuzzyThreshold
            }
        }
    }

    /// Comma-separated terms. Matching is by word, so "acme, globex" behaves
    /// the way anyone writing it expects.
    static func words(in pattern: String, insensitive: Bool = true) -> [String] {
        pattern.split(separator: ",")
            .map { insensitive
                ? $0.trimmingCharacters(in: .whitespaces).lowercased()
                : $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A phrase, with every run of whitespace allowed to be any whitespace.
    /// OCR breaks "amount due" across a line more often than anything else
    /// defeats a literal phrase match.
    static func phraseRegex(_ phrase: String, insensitive: Bool) -> NSRegularExpression? {
        let parts = phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        let options: NSRegularExpression.Options = insensitive ? [.caseInsensitive] : []
        return try? NSRegularExpression(pattern: parts.joined(separator: #"\s+"#), options: options)
    }

    /// How well `needle` matches the best window of `hay` of its own length,
    /// as a fraction. This is rapidfuzz's `partial_ratio` in miniature: slide
    /// the needle along, take the best edit-distance similarity.
    ///
    /// Only worth running against the words of a document, not its whole text,
    /// so the haystack is split first — an edit distance over half a megabyte
    /// of OCR would be its own kind of mistake.
    static func partialRatio(of needle: String, in hay: String) -> Double {
        guard !needle.isEmpty else { return 0 }
        if hay.contains(needle) { return 1 }
        var best = 0.0
        for token in hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            // Only compare against words of a plausible length; "Rechnung" is
            // never a typo for "of".
            guard abs(token.count - needle.count) <= max(2, needle.count / 4) else { continue }
            best = max(best, similarity(needle, String(token)))
            if best >= 1 { break }
        }
        return best
    }

    /// 1 minus the normalised Levenshtein distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(distance(Array(a), Array(b))) / Double(longest)
    }

    /// Levenshtein, two rows at a time.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
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
