import Foundation

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
    static func string(_ bytes: Int64) -> String { formatter.string(fromByteCount: bytes) }
}

extension DateFormatter {
    /// Timestamp formatted safely for filenames (e.g. `2026-01-14 10.22.03`).
    static let filenameSafe: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

extension JSONEncoder {
    /// Small helper for the bits of UI state that live in the settings table.
    static func string<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
