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
        var title: String?
        var correspondent: String?
        var docType: String?
        var amount: String?
        var confidence: Double = 0
    }

    static func analyze(url: URL, text: String, fallbackDate: Date,
                        knownCorrespondents: [String]) -> Findings {
        var f = Findings()

        // Date: OCR text > embedded document metadata > EXIF > filename > filesystem.
        if let d = dateInText(text) { f.date = d; f.dateSource = "ocr" }
        else if let d = embeddedDate(url) { f.date = d; f.dateSource = "pdf" }
        else if let d = exifDate(url) { f.date = d; f.dateSource = "exif" }
        else if let d = dateInText(url.deletingPathExtension().lastPathComponent) {
            f.date = d; f.dateSource = "filename"
        } else { f.date = fallbackDate; f.dateSource = "fs" }

        f.docType = documentType(text)
        f.correspondent = correspondent(text: text, known: knownCorrespondents)
            ?? embeddedAuthor(url)
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

    /// Prefers a date near an explicit label ("Date:", "Datum", "Rechnungsdatum"),
    /// then the earliest plausible date in the first part of the document.
    static func dateInText(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let head = String(text.prefix(4000))
        let now = Date()
        let floor = Calendar.current.date(byAdding: .year, value: -60, to: now)!
        let ceiling = Calendar.current.date(byAdding: .year, value: 2, to: now)!

        var labelled: Date?
        var all: [Date] = []

        if let detector {
            let ns = head as NSString
            detector.enumerateMatches(in: head, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, let d = m.date, d > floor, d < ceiling else { return }
                all.append(d)
                if labelled == nil {
                    let start = max(0, m.range.location - 32)
                    let context = ns.substring(with: NSRange(location: start, length: m.range.location - start)).lowercased()
                    for cue in ["date", "datum", "dated", "issued", "invoice date", "rechnungsdatum",
                                "ausstellungsdatum", "vom", "fecha", "datte"] where context.contains(cue) {
                        labelled = d
                        break
                    }
                }
            }
        }
        if let labelled { return labelled }

        // Compact numeric forms NSDataDetector misses (20260114, 2026-01-14).
        if all.isEmpty, let iso = isoLikeDate(in: head) { return iso }
        return all.first
    }

    private static let isoRegex = try? NSRegularExpression(
        pattern: #"(19|20)\d{2}[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])"#)

    private static func isoLikeDate(in text: String) -> Date? {
        guard let isoRegex else { return nil }
        let ns = text as NSString
        guard let m = isoRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let digits = ns.substring(with: m.range).filter(\.isNumber)
        guard digits.count == 8 else { return nil }
        var c = DateComponents()
        c.year = Int(digits.prefix(4))
        c.month = Int(digits.dropFirst(4).prefix(2))
        c.day = Int(digits.suffix(2))
        return Calendar.current.date(from: c)
    }

    private static func embeddedDate(_ url: URL) -> Date? {
        guard url.pathExtension.lowercased() == "pdf",
              let doc = PDFDocument(url: url),
              let attrs = doc.documentAttributes else { return nil }
        return attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
    }

    private static func embeddedAuthor(_ url: URL) -> String? {
        guard url.pathExtension.lowercased() == "pdf",
              let doc = PDFDocument(url: url),
              let attrs = doc.documentAttributes else { return nil }
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String
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
        if let hit = known.first(where: { !$0.isEmpty && lower.contains($0.lowercased()) }) { return hit }

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
