import Foundation

enum Naming {
    static let defaultTemplate = "{date}_{correspondent}_{title}"

    /// Clean-ups applied to a rendered filename, never to folder names.
    struct Options: Sendable, Equatable {
        var underscoresForSpaces = false
        var asciiOnly = false
    }

    struct Context: Sendable {
        var date: Date?
        var correspondent: String?
        var title: String?
        var docType: String?
        var language: String?
        var counter: Int?
        var originalStem: String
        var ext: String
        var options = Options()
    }

    /// How far the library holds its filenames to its naming template.
    enum Enforcement: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Names change only when someone renames a file.
        case manual
        /// A name the template would not give is pointed out.
        case highlight
        /// Pointed out, and a name the template gave follows the document's
        /// fields when they change. A name someone chose is never touched.
        case followTemplateNames
        /// Every name follows the document's fields, and new arrivals Doctopus
        /// files itself are named by the template.
        case automatic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .manual: return "Only when asked"
            case .highlight: return "Point out names that don’t match"
            case .followTemplateNames: return "Point out, and keep names it gave up to date"
            case .automatic: return "Rename automatically"
            }
        }

        var explanation: String {
            switch self {
            case .manual:
                return "Files are renamed only from Rename… in the context menu."
            case .highlight:
                return "A document whose filename differs from what the template gives it is marked in orange, with Rename and Suppress."
            case .followTemplateNames:
                return "As above, and a file named by the template is renamed again when its title, date or other fields change. A name you gave a file yourself is never changed."
            case .automatic:
                return "Every file is renamed when its fields change, and new arrivals Doctopus files itself are named by the template. Suppress keeps a name for good."
            }
        }

        var highlights: Bool { self != .manual }
        var followsEdits: Bool { self == .followTemplateNames || self == .automatic }
    }

    /// Whether `filename` is `rendered`, or what `uniqueURL` made of it because
    /// that name was taken — which is still the template's name for it, and
    /// must not be renamed again on every look.
    static func isRendering(_ filename: String, of rendered: String) -> Bool {
        if filename == rendered { return true }
        let have = filename as NSString, want = rendered as NSString
        guard have.pathExtension == want.pathExtension else { return false }
        let stem = want.deletingPathExtension, haveStem = have.deletingPathExtension
        for separator in [" ", "_"] where haveStem.hasPrefix(stem + separator) {
            let suffix = haveStem.dropFirst(stem.count + separator.count)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return true }
            if suffix.count == 8, suffix.allSatisfy(\.isHexDigit) { return true }
        }
        return false
    }

    /// A document date is a day, stored as the UTC start of it, so every token
    /// that renders one reads it back in UTC. Rendering in the local timezone
    /// is how `{year}` ends up filing a document issued on 1 January into the
    /// previous year on a Mac three hours west of where it was scanned.
    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Whether `template` puts the document date anywhere.
    static func usesDate(_ template: String) -> Bool {
        var token = ""
        var inToken = false
        for ch in template {
            if ch == "{" { inToken = true; token = "" }
            else if ch == "}" && inToken {
                inToken = false
                let name = token.split(separator: "|", maxSplits: 1).first
                    .flatMap { $0.split(separator: ":", maxSplits: 1).first }
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                if ["date", "created", "year", "month", "day"].contains(name) { return true }
            } else if inToken { token.append(ch) }
        }
        return false
    }

    static func render(_ template: String, _ ctx: Context) -> String {
        var out = ""
        var token = ""
        var inToken = false
        for ch in template {
            if ch == "{" { inToken = true; token = "" }
            else if ch == "}" && inToken {
                inToken = false
                out += resolveToken(token, ctx)
            } else if inToken { token.append(ch) }
            else { out.append(ch) }
        }
        return tidy(out, ext: ctx.ext, fallback: ctx.originalStem, options: ctx.options)
    }

    private static func resolveToken(_ token: String, _ ctx: Context) -> String {
        let orParts = token.split(separator: "|", maxSplits: 1).map(String.init)
        let mainToken = orParts[0].trimmingCharacters(in: .whitespaces)
        let defaultValue = orParts.count > 1 ? orParts[1].trimmingCharacters(in: .whitespaces) : ""
        let val = value(for: mainToken, ctx)
        if val.isEmpty {
            return sanitize(defaultValue)
        }
        return val
    }

    private static func value(for token: String, _ ctx: Context) -> String {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0].lowercased()
        let arg = parts.count > 1 ? parts[1] : nil

        switch name {
        case "date", "created":
            guard let d = ctx.date else { return "" }
            if let arg {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 0)
                f.dateFormat = arg
                return f.string(from: d)
            }
            return isoDay.string(from: d)
        case "year":  return ctx.date.map { String(DayDate.calendar.component(.year, from: $0)) } ?? ""
        case "month": return ctx.date.map { String(format: "%02d", DayDate.calendar.component(.month, from: $0)) } ?? ""
        case "day":   return ctx.date.map { String(format: "%02d", DayDate.calendar.component(.day, from: $0)) } ?? ""
        case "correspondent", "from": return sanitize(ctx.correspondent ?? "")
        case "title":  return sanitize(ctx.title ?? ctx.originalStem)
        case "type":   return sanitize(ctx.docType ?? "")
        case "lang", "language": return ctx.language ?? ""
        case "ext":    return ctx.ext
        case "original", "stem": return sanitize(ctx.originalStem)
        case "n", "counter": return ctx.counter.map { String(format: "%03d", $0) } ?? ""
        default: return ""
        }
    }

    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")

    private static func sanitize(_ s: String) -> String {
        var out = s.components(separatedBy: illegal).joined(separator: " ")
        out = out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") {
            out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if out == ".." || out == "." { out = "" }
        return String(out.prefix(80))
    }

    /// German umlauts spell out their vowel; `Latin-ASCII` alone would drop it.
    private static let spelledOut: [Character: String] = [
        "ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss",
    ]

    /// ä → ae, å → a, á → a, æ → ae, ø → o; anything with no ASCII spelling is dropped.
    static func asciiFolded(_ s: String) -> String {
        // Character comparison is canonical, so a decomposed "a\u{308}" from
        // a filename matches "ä" here too.
        var out = ""
        for ch in s {
            if let spelled = spelledOut[ch] { out += spelled } else { out.append(ch) }
        }
        out = out.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? out
        out = String(String.UnicodeScalarView(out.unicodeScalars.filter(\.isASCII)))
        // Latin-ASCII spells ½ as "1/2", which must not become a folder.
        return out.components(separatedBy: illegal).joined(separator: " ")
    }

    private static func applying(_ options: Options, to s: String) -> String {
        var out = s
        if options.asciiOnly {
            out = asciiFolded(out)
            while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        }
        if options.underscoresForSpaces {
            out = out.components(separatedBy: .whitespaces).joined(separator: "_")
        }
        return out
    }

    private static func tidy(_ s: String, ext: String, fallback: String, options: Options) -> String {
        var out = applying(options, to: s)
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        // Never allow leading dot, '..', or hidden filenames
        while out.hasPrefix(".") {
            out = String(out.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        }
        if out.isEmpty || out == "." || out == ".." {
            out = applying(options, to: sanitize(fallback)).trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        }
        if out.isEmpty || out == "." || out == ".." {
            out = "Document"
        }
        if out.count > 180 {
            out = String(out.prefix(180)).trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        }
        return ext.isEmpty ? out : "\(out).\(ext)"
    }

    static func renderPath(_ template: String, _ ctx: Context) -> [String] {
        template.split(separator: "/")
            .map { render(String($0), ctx) }
            .filter { !$0.isEmpty && $0 != ctx.originalStem }
    }

    /// `separator` goes between the stem and the number that tells a copy apart.
    static func uniqueURL(in directory: URL, filename: String, separator: String = " ") -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) && n < 1000 {
            let name = ext.isEmpty ? "\(stem)\(separator)\(n)" : "\(stem)\(separator)\(n).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        if fm.fileExists(atPath: candidate.path) {
            let suffix = UUID().uuidString.prefix(8)
            let name = ext.isEmpty ? "\(stem)\(separator)\(suffix)" : "\(stem)\(separator)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
        }
        return candidate
    }
}

extension Naming.Context {
    /// A document as the index has it, for the one name the template gives it.
    /// Undated documents go by when they were added, as Rename… does.
    init(_ row: DocumentRow, options: Naming.Options) {
        let url = row.url
        self.init(date: row.docDate ?? row.createdAt, correspondent: row.correspondent,
                  title: row.title, docType: row.docType, language: row.language, counter: nil,
                  originalStem: url.deletingPathExtension().lastPathComponent,
                  ext: url.pathExtension, options: options)
    }
}
