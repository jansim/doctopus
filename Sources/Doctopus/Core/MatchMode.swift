import Foundation

/// How a rule's pattern is read.
///
/// The router used to work this out from the punctuation: anything containing
/// `^$*+?[]()|\` became a regular expression. That made `Acme (UK) Ltd` a regex
/// nobody asked for — a valid one, which is worse, because it matched something
/// subtly different rather than failing — and made `inv(oice` a regex that does
/// not compile and silently falls back to word matching. The rule editor's
/// preview was honest about all of it, which is good design covering for a bad
/// default. This is the default being fixed instead.
enum MatchMode: Int64, CaseIterable, Sendable, Codable {
    /// Any of the comma-separated words, each matched as a whole word unless
    /// a `*` widens it.
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

    /// How close two strings have to be, as a fraction, for `fuzzy` to call it
    /// a match. Paperless uses rapidfuzz's `partial_ratio >= 90`.
    static let fuzzyThreshold = 0.9

    /// …and how many edits are forgiven outright, which is what a ratio alone
    /// gets wrong on short words: one misread letter in an eight-letter word is
    /// 87.5% similar, so a flat 90% rejects `Rechnunq` for `Rechnung` — exactly
    /// the case this mode exists for. Anything under five letters is too short
    /// to guess at.
    static func fuzzyEdits(forLength n: Int) -> Int {
        switch n {
        case ..<5: return 0
        case ..<10: return 1
        default: return 2
        }
    }
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

    /// One comma-separated term. A whole word unless a `*` opens a side:
    /// `rechnung*` also catches "Rechnungsnummer", `*rechnung` catches
    /// "Gehaltsabrechnung", and `*rechnung*` catches both.
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

    /// What the word modes used to do — match at the start of a word — spelled
    /// in today's syntax, for migrating patterns written before `*` existed.
    static func openingEnds(_ pattern: String) -> String {
        pattern.split(separator: ",", omittingEmptySubsequences: false)
            .map { part -> String in
                let t = part.trimmingCharacters(in: .whitespaces)
                return t.isEmpty || t.hasSuffix("*") ? t : t + "*"
            }
            .joined(separator: ", ")
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

    /// Whether any word of `hay` is close enough to `needle` — either within
    /// the forgiven number of edits, or similar enough by ratio, whichever is
    /// kinder. The two together are what makes short words work as well as
    /// long ones.
    ///
    /// Only ever run against the *words* of a document, never its whole text:
    /// an edit distance over half a megabyte of OCR would be its own kind of
    /// mistake.
    static func isNear(_ needle: String, in hay: String) -> Bool {
        guard !needle.isEmpty else { return false }
        if hay.contains(needle) { return true }
        let allowance = MatchMode.fuzzyEdits(forLength: needle.count)
        guard allowance > 0 else { return false }
        let target = Array(needle)
        for token in hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            // Only compare against words of a plausible length; "Rechnung" is
            // never a misreading of "of".
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

    /// Levenshtein, two rows at a time.
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
