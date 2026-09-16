import Foundation

/// `{date}_{correspondent}_{title}.{ext}` style templates with deterministic
/// fallback chains, used by on-demand rename and by scan import.
enum Naming {
    static let defaultTemplate = "{date}_{correspondent}_{title}"

    struct Context: Sendable {
        var date: Date?
        var correspondent: String?
        var title: String?
        var docType: String?
        var language: String?
        var counter: Int?
        var originalStem: String
        var ext: String
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
        return tidy(out, ext: ctx.ext, fallback: ctx.originalStem)
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

    /// Filesystem-safe, collapses the gaps left by empty tokens.
    private static func sanitize(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var out = s.components(separatedBy: illegal).joined(separator: " ")
        out = out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") {
            out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if out == ".." || out == "." { out = "" }
        return String(out.prefix(80))
    }

    private static func tidy(_ s: String, ext: String, fallback: String) -> String {
        var out = s
        // Collapse separators orphaned by missing values: "2026-01-14__Title".
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        // Never allow leading dot, '..', or hidden filenames
        while out.hasPrefix(".") {
            out = String(out.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        }
        if out.isEmpty || out == "." || out == ".." {
            out = sanitize(fallback).trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        }
        if out.isEmpty || out == "." || out == ".." {
            out = "Document"
        }
        // Cap filename stem length to prevent path length overflow (>1024 bytes)
        if out.count > 180 {
            out = String(out.prefix(180)).trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        }
        return ext.isEmpty ? out : "\(out).\(ext)"
    }

    /// Appends ` 2`, ` 3`… the way Finder does, so a rename never clobbers.
    static func uniqueURL(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) && n < 1000 {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        if fm.fileExists(atPath: candidate.path) {
            let suffix = UUID().uuidString.prefix(8)
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
        }
        return candidate
    }
}
