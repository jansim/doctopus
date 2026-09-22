import Foundation
import AppKit
import SwiftUI

/// The xattr is read and written directly: `URLResourceValues.tagNames` carries
/// names only, and writing through it strips the colour off every other tag.
enum FinderTags {
    struct Entry: Hashable, Sendable {
        var name: String
        var label: Int

        init(name: String, label: Int = 0) {
            self.name = name
            self.label = label
        }

        init?(stored: String) {
            let parts = stored.components(separatedBy: "\n")
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty
            else { return nil }
            self.name = name
            self.label = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        }

        var stored: String { "\(name)\n\(label)" }
    }

    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    static func entries(_ url: URL) -> [Entry] {
        guard let data = attributeData(url),
              let raw = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
        else {
            return names(url).map { Entry(name: $0, label: label(for: $0)) }
        }
        let parsed = raw.compactMap(Entry.init(stored:))
        Registry.shared.learn(parsed)
        return parsed
    }

    private static func names(_ url: URL) -> [String] {
        ((try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
    }

    private static func attributeData(_ url: URL) -> Data? {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, attribute, &buffer, size, 0, 0) == size else { return nil }
        return Data(buffer)
    }

    @discardableResult
    static func write(_ entries: [Entry], to url: URL) -> Bool {
        Registry.shared.learn(entries)
        guard !entries.isEmpty else {
            removexattr(url.path, attribute, 0)
            return true
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: entries.map(\.stored) as NSArray, format: .binary, options: 0)
        else { return false }
        return data.withUnsafeBytes {
            setxattr(url.path, attribute, $0.baseAddress, data.count, 0, 0) == 0
        }
    }

    @discardableResult
    static func add(_ name: String, to url: URL) -> Bool {
        var entries = entries(url)
        guard !entries.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return true }
        entries.append(Entry(name: name, label: label(for: name)))
        return write(entries, to: url)
    }

    @discardableResult
    static func remove(_ name: String, from url: URL) -> Bool {
        let kept = entries(url).filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        return write(kept, to: url)
    }

    static let labelColors: [Color?] = [nil, .gray, .green, .purple, .blue, .yellow, .red, .orange]

    static func color(label: Int) -> Color? {
        labelColors.indices.contains(label) ? labelColors[label] : nil
    }

    static func color(for name: String) -> Color? { color(label: label(for: name)) }

    static func label(for name: String) -> Int {
        Registry.shared.label(for: name) ?? systemLabels[name.lowercased()] ?? 0
    }

    private static let systemLabels: [String: Int] = [
        "gray": 1, "grey": 1, "green": 2, "purple": 3,
        "blue": 4, "yellow": 5, "red": 6, "orange": 7,
    ]

    static func learn(_ labels: [String: Int]) { Registry.shared.learn(labels) }

    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var labels: [String: Int] = [:]

        /// Only colours are learned: a file carrying the tag without one says
        /// nothing about the tag, and would otherwise erase what is known.
        func learn(_ entries: [Entry]) {
            learn(Dictionary(entries.map { ($0.name, $0.label) }, uniquingKeysWith: max))
        }

        func learn(_ pairs: [String: Int]) {
            lock.lock(); defer { lock.unlock() }
            for (name, label) in pairs where label != 0 {
                labels[name.lowercased()] = label
            }
        }

        func label(for name: String) -> Int? {
            lock.lock(); defer { lock.unlock() }
            return labels[name.lowercased()]
        }
    }
}
