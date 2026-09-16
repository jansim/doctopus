import Foundation
import ImageIO
import PDFKit

/// Deterministic, offline metadata extraction. This always runs; the on-device
/// LLM (when present) refines the result rather than replacing it, so the app
/// behaves identically on machines without Apple Intelligence.
enum DocumentAnalyzer {

    struct Findings: Sendable {
        var date: Date?
        var dateSource: String?
        /// Every plausible date found, best first. The review offers them as
        /// chips: one wrong guess out of three good candidates is a click to
        /// fix, where a single wrong answer is a retype.
        var dates: [DateCandidate] = []
        var title: String?
        var correspondent: String?
        var docType: String?
        var amount: String?
        var confidence: Double = 0
    }

    /// What the analyzer needs to know that is the library's business rather
    /// than the document's: how to read an ambiguous numeric date, and which
    /// dates never count.
    struct Options: Sendable {
        var dateOrder: DateOrder = .automatic
        /// Days that are never a document date — the date printed in a
        /// letterhead, a form's revision date — as `yyyy-MM-dd`.
        var ignoredDays: Set<String> = []
        /// The library's dominant language, which is what `.automatic` reads
        /// the date order from. The *system* locale would mean the same library
        /// giving different answers on two Macs.
        var language: String?
        /// Correspondents and document types that carry a pattern identifying
        /// them. "Anything mentioning DE12 3456 is from this bank" is the
        /// cheapest classification there is: no model, no network, and right
        /// every time the pattern is.
        var entityRules: [Entity] = []

        static let `default` = Options()

        func rules(for fieldKey: String) -> [Entity] {
            entityRules.filter { $0.fieldKey == fieldKey }
        }
    }

    static func analyze(url: URL, text: String, fallbackDate: Date,
                        knownCorrespondents: [String],
                        options: Options = .default) -> Findings {
        var f = Findings()

        let pdfInfo = pdfAttributes(url)

        // Date: OCR text > embedded document metadata > EXIF > filename > filesystem.
        var candidates = datesInText(text, source: "ocr", options: options)
        if let d = embeddedDate(pdfInfo) {
            candidates += [DateCandidate(date: DayDate.startOfDay(d), source: "pdf", labelled: false)]
        }
        if let d = exifDate(url) {
            candidates += [DateCandidate(date: DayDate.startOfDay(d), source: "exif", labelled: false)]
        }
        candidates += datesInText(url.deletingPathExtension().lastPathComponent,
                                  source: "filename", options: options)
        candidates = rank(candidates, options: options)

        if let best = candidates.first {
            f.date = best.date
            f.dateSource = best.source
        } else {
            // The filesystem is the last resort and is never offered as a
            // choice: it says when the file arrived, not when it was issued.
            f.date = DayDate.startOfDay(fallbackDate)
            f.dateSource = "fs"
        }
        f.dates = candidates

        f.docType = matchingEntity(in: text, rules: options.rules(for: "doc_type"))
            ?? documentType(text)
        f.correspondent = matchingEntity(in: text, rules: options.rules(for: "correspondent"))
            ?? correspondent(text: text, known: knownCorrespondents)
            ?? embeddedAuthor(pdfInfo)
        f.amount = amount(in: text)
        f.title = title(url: url, text: text, type: f.docType, correspondent: f.correspondent)

        var score = 0.35
        if f.dateSource == "ocr" || f.dateSource == "pdf" { score += 0.2 }
        if f.correspondent != nil { score += 0.2 }
        if f.docType != nil { score += 0.15 }
        if !text.isEmpty { score += 0.05 }
        f.confidence = min(score, 0.95)
        return f
    }

    // MARK: - Dates

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// `12/03/2026`, `2026-03-12`, `12.3.26` — the forms whose meaning depends
    /// on where you are, which is exactly why the reading is configured rather
    /// than taken from whatever Mac this happens to be.
    private static let numericDate = try? NSRegularExpression(
        pattern: #"(?<![\d/.\-])(\d{1,4})[./\-](\d{1,2})[./\-](\d{2,4})(?![\d/.\-])"#)

    /// Compact forms with no separators at all: `20260114`.
    private static let compactDate = try? NSRegularExpression(
        pattern: #"(?<!\d)(19|20)(\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?!\d)"#)

    /// Words that mark the date *of* the document, as opposed to a due date, a
    /// print date or the year a form was revised.
    private static let dateCues = ["date", "datum", "dated", "issued", "invoice date",
                                   "rechnungsdatum", "ausstellungsdatum", "vom", "fecha", "datte"]

    /// Every plausible date in a piece of text, in the order they appear.
    ///
    /// Three rules Paperless learned the hard way, all of them here: a year
    /// before 1900 is not a date, **a document is never issued in the future**,
    /// and an ambiguous numeric date is read according to a configured order
    /// rather than the machine's locale.
    ///
    /// `allowFuture` is for the callers that are not reading a document date: a
    /// due date is routinely in the future, and only the issue date cannot be.
    static func datesInText(_ text: String, source: String,
                            options: Options = .default,
                            allowFuture: Bool = false) -> [DateCandidate] {
        guard !text.isEmpty else { return [] }
        let head = String(text.prefix(4000))
        let ns = head as NSString
        let full = NSRange(location: 0, length: ns.length)
        let order = options.dateOrder.resolved(language: options.language)

        var found: [(range: NSRange, date: Date)] = []
        // Every span a numeric pattern spoke for, whether or not it turned out
        // to be a real date. `31/02/2024` is not a date, and the system
        // detector rounding it to 2 March is not an improvement.
        var claimed: [NSRange] = []

        if let numericDate {
            for m in numericDate.matches(in: head, range: full) {
                claimed.append(m.range)
                let parts = (1...3).map { Int(ns.substring(with: m.range(at: $0))) ?? 0 }
                let widths = (1...3).map { m.range(at: $0).length }
                if let date = assemble(parts, widths: widths, order: order) {
                    found.append((m.range, date))
                }
            }
        }
        if let compactDate {
            for m in compactDate.matches(in: head, range: full) {
                claimed.append(m.range)
                let digits = ns.substring(with: m.range)
                if let date = day(year: Int(digits.prefix(4)) ?? 0,
                                  month: Int(digits.dropFirst(4).prefix(2)) ?? 0,
                                  day: Int(digits.suffix(2)) ?? 0) {
                    found.append((m.range, date))
                }
            }
        }
        // The system detector is what reads "14 January 2026", which no simple
        // pattern should try to. Numeric forms are left to the reading above:
        // the detector resolves those by the system locale, and it also turns
        // an impossible one into a plausible one instead of rejecting it.
        if let detector {
            for m in detector.matches(in: head, range: full) {
                guard let d = m.date else { continue }
                if claimed.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                found.append((m.range, DayDate.startOfDay(d)))
            }
        }

        let today = DayDate.startOfDay(Date())
        let floor = DayDate.calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? .distantPast

        var out: [DateCandidate] = []
        var seen = Set<Date>()
        for (range, date) in found.sorted(by: { $0.range.location < $1.range.location }) {
            guard date > floor, allowFuture || date <= today else { continue }
            guard !options.ignoredDays.contains(DayDate.text(date)) else { continue }
            guard seen.insert(date).inserted else { continue }
            let start = max(0, range.location - 32)
            let before = ns.substring(with: NSRange(location: start, length: range.location - start))
                .lowercased()
            let cue = dateCues.first { before.contains($0) }
            out.append(DateCandidate(date: date, source: source, labelled: cue != nil, cue: cue))
        }
        return out
    }

    /// Best first: a date next to an explicit label beats one that is merely
    /// present, and text beats the filename. At most a handful are kept — the
    /// point is to offer a choice, not a list.
    static func rank(_ candidates: [DateCandidate], options: Options = .default,
                     limit: Int = 3) -> [DateCandidate] {
        func weight(_ c: DateCandidate) -> Int {
            var score = c.labelled ? 100 : 0
            switch c.source {
            case "ocr": score += 20
            case "pdf": score += 12
            case "exif": score += 10
            case "filename": score += 5
            default: break
            }
            return score
        }
        var seen = Set<Date>()
        return candidates
            .enumerated()
            .sorted { a, b in
                let (wa, wb) = (weight(a.element), weight(b.element))
                return wa == wb ? a.offset < b.offset : wa > wb
            }
            .map(\.element)
            .filter { seen.insert($0.date).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// The single best date in a piece of text, for callers that only want one.
    static func dateInText(_ text: String, options: Options = .default) -> Date? {
        rank(datesInText(text, source: "ocr", options: options), options: options).first?.date
    }

    /// Any date at all, future ones included — what a field holding a due date
    /// needs, and exactly what a document's issue date must not accept.
    static func anyDate(in text: String, options: Options = .default) -> Date? {
        datesInText(text, source: "ocr", options: options, allowFuture: true).first?.date
    }

    /// Turns three numbers into a day, given how the ambiguous ones are read.
    private static func assemble(_ parts: [Int], widths: [Int], order: DateOrder) -> Date? {
        guard parts.count == 3 else { return nil }
        let (a, b, c) = (parts[0], parts[1], parts[2])
        // A four-digit first number can only be a year.
        if widths[0] == 4 { return day(year: a, month: b, day: c) }
        // One of the two leading numbers being over twelve settles it whatever
        // the configured order says — nobody writes a thirteenth month.
        if a > 12, b <= 12 { return day(year: expand(c), month: b, day: a) }
        if b > 12, a <= 12 { return day(year: expand(c), month: a, day: b) }
        switch order {
        case .ymd: return day(year: expand(a), month: b, day: c)
        case .mdy: return day(year: expand(c), month: a, day: b)
        case .dmy, .automatic: return day(year: expand(c), month: b, day: a)
        }
    }

    /// A two-digit year, by the POSIX convention: 69–99 is last century.
    private static func expand(_ year: Int) -> Int {
        guard year < 100 else { return year }
        return year >= 69 ? 1900 + year : 2000 + year
    }

    private static func day(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), year > 0 else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        guard let date = DayDate.calendar.date(from: c) else { return nil }
        // Reject a day the month does not have: 31 February is a misread.
        let back = DayDate.calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    private static func pdfAttributes(_ url: URL) -> [AnyHashable: Any]? {
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        return PDFDocument(url: url)?.documentAttributes
    }

    private static func embeddedDate(_ attributes: [AnyHashable: Any]?) -> Date? {
        attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date
    }

    private static func embeddedAuthor(_ attributes: [AnyHashable: Any]?) -> String? {
        let author = attributes?[PDFDocumentAttribute.authorAttribute] as? String
        return author?.nilIfBlank.flatMap { $0.count < 60 ? $0 : nil }
    }

    private static func exifDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = (exif[kCGImagePropertyExifDateTimeOriginal]
                         ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return fmt.date(from: raw)
    }

    // MARK: - Type

    private static let typeKeywords: [(String, [String])] = [
        ("Invoice",       ["invoice", "rechnung", "facture", "factura", "fattura", "amount due", "betrag", "vat id", "ust-id"]),
        ("Receipt",       ["receipt", "quittung", "kassenbon", "beleg", "thank you for your purchase", "subtotal"]),
        ("Contract",      ["contract", "vertrag", "agreement", "terms and conditions", "hereby agree"]),
        ("Bank Statement",["statement", "kontoauszug", "account summary", "closing balance", "iban", "opening balance"]),
        ("Tax",           ["tax", "steuer", "finanzamt", "hmrc", "irs", "steuerbescheid", "tax return"]),
        ("Insurance",     ["insurance", "versicherung", "policy number", "police", "versicherungsschein"]),
        ("Payslip",       ["payslip", "gehaltsabrechnung", "lohnabrechnung", "net pay", "gross pay", "salary"]),
        ("Medical",       ["diagnosis", "patient", "arztbrief", "befund", "prescription", "rezept"]),
        ("Certificate",   ["certificate", "zeugnis", "urkunde", "bescheinigung", "diploma"]),
        ("Letter",        ["dear sir", "sehr geehrte", "yours sincerely", "mit freundlichen grüßen"]),
    ]

    static func documentType(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let hay = text.prefix(6000).lowercased()
        var best: (String, Int)?
        for (type, keys) in typeKeywords {
            let hits = keys.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            if hits > 0, hits > (best?.1 ?? 0) { best = (type, hits) }
        }
        return best?.0
    }

    // MARK: - Values that identify themselves

    /// The first value whose own pattern matches the document. A correspondent
    /// carrying its IBAN, a document type carrying the form number it always
    /// prints — these beat every heuristic below, because somebody wrote them
    /// down on purpose.
    static func matchingEntity(in text: String, rules: [Entity]) -> String? {
        guard !text.isEmpty else { return nil }
        let head = String(text.prefix(6000))
        for entity in rules {
            guard let pattern = entity.match?.nilIfBlank else { continue }
            if PatternMatcher.matches(pattern, mode: entity.matchMode,
                                      insensitive: entity.matchInsensitive, in: head) {
                return entity.name
            }
        }
        return nil
    }

    // MARK: - Correspondent

    private static let noiseWords: Set<String> = [
        "invoice", "rechnung", "receipt", "statement", "page", "seite", "date", "datum",
        "customer", "kunde", "total", "summary", "document", "copy", "original",
    ]

    /// Known names win (keeps a library's vocabulary stable); otherwise the first
    /// header line that reads like an organisation is used.
    static func correspondent(text: String, known: [String]) -> String? {
        guard !text.isEmpty else { return nil }
        let head = String(text.prefix(2500))
        let lower = head.lowercased()
        // A known name wins, but only on a word boundary and only if it is long
        // enough to mean something: a correspondent called "AG" or "Post"
        // matched as a plain substring fires on almost every document there is.
        if let hit = known.first(where: { candidate in
            let needle = candidate.lowercased()
            return needle.count >= 4 && lower.startsWithWord(needle)
        }) { return hit }

        for raw in head.split(separator: "\n").prefix(12) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 3, line.count <= 48 else { continue }
            let words = line.split(separator: " ")
            guard words.count <= 6 else { continue }
            let l = line.lowercased()
            if noiseWords.contains(where: { l.contains($0) }) { continue }
            if line.rangeOfCharacter(from: .letters) == nil { continue }
            // Digit-heavy lines are addresses, order numbers or dates.
            let digits = line.filter(\.isNumber).count
            if Double(digits) / Double(line.count) > 0.2 { continue }
            // Legal-form suffixes are a strong signal; otherwise require title case.
            let forms = ["gmbh", "ag", "ltd", "llc", "inc", "b.v.", "s.a.", "kg", "e.v.", "plc", "co."]
            if forms.contains(where: { l.hasSuffix($0) || l.contains(" \($0)") }) { return line }
            let capitalized = words.filter { $0.first?.isUppercase == true }.count
            if capitalized >= max(1, words.count - 1) { return line }
        }
        return nil
    }

    // MARK: - Amount

    private static let amountRegex = try? NSRegularExpression(
        pattern: #"(?:(?:total|amount due|gesamt|summe|betrag|zu zahlen|balance)\D{0,20})([€$£]\s?\d[\d.,]{1,12}|\d[\d.,]{1,12}\s?(?:EUR|USD|GBP|CHF|€|\$|£))"#,
        options: [.caseInsensitive])

    static func amount(in text: String) -> String? {
        guard let amountRegex, !text.isEmpty else { return nil }
        let head = String(text.prefix(8000))
        let ns = head as NSString
        guard let m = amountRegex.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Title

    static func title(url: URL, text: String, type: String?, correspondent: String?) -> String? {
        // A filename that is not machine noise is the best title we have.
        let stem = url.deletingPathExtension().lastPathComponent
        if !looksGenerated(stem) {
            return stem.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        // Otherwise build one from what we understood.
        if let correspondent, let type { return "\(type) — \(correspondent)" }
        let lines = text.components(separatedBy: "\n")
        if let heading = lines.first(where: { $0.count > 6 && $0.count < 70 }) {
            return heading.trimmingCharacters(in: .whitespaces)
        }
        return type
    }

    /// `IMG_4821`, `Scan 2026-01-14 at 10.22`, `document(3)` — camera and scanner noise.
    private static func looksGenerated(_ stem: String) -> Bool {
        let l = stem.lowercased()
        let prefixes = ["img_", "img-", "image", "scan", "scanned", "photo", "dsc", "doc", "document", "untitled", "unbenannt", "pdf"]
        if prefixes.contains(where: { l.hasPrefix($0) }) { return true }
        let digits = stem.filter(\.isNumber).count
        return Double(digits) / Double(max(stem.count, 1)) > 0.55
    }
}
