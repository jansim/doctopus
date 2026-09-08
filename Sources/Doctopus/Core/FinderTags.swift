import Foundation
import AppKit
import SwiftUI

/// The Finder's own tags, which live on the file in extended attributes rather
/// than in this app's index. Reading them is cheap; writing one is a deliberate
/// change to the user's file and only ever happens on an explicit action.
///
/// The attribute is read and written directly rather than through
/// `URLResourceValues.tagNames`, which carries names only: it cannot express a
/// colour on the way in, and on the way out it strips the colour off every
/// other tag on the file. A tag is stored as `"Name\nLabel"`, where the label
/// is one of the seven colours the Finder offers, or 0 for none.
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

    // MARK: - Reading

    /// One file's tags, with their colours.
    static func entries(_ url: URL) -> [Entry] {
        guard let data = attributeData(url),
              let raw = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
        else {
            // Volumes that do not expose the attribute still answer the
            // resource key, and there is nothing but names to be had there.
            return names(url).map { Entry(name: $0, label: label(for: $0)) }
        }
        let parsed = raw.compactMap(Entry.init(stored:))
        Registry.shared.learn(parsed)
        return parsed
    }

    static func read(_ url: URL) -> [String] { entries(url).map(\.name) }

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

    // MARK: - Writing

    @discardableResult
    static func write(_ entries: [Entry], to url: URL) -> Bool {
        Registry.shared.learn(entries)
        guard !entries.isEmpty else {
            // A file with no tags carries no attribute at all, which is what
            // the Finder leaves behind when the last one is removed.
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

    // MARK: - Colours

    /// The Finder's colours, in the order macOS numbers its labels. Index 0 is
    /// "no colour", which the Finder draws as an empty ring.
    static let labelColors: [Color?] = [nil, .gray, .green, .purple, .blue, .yellow, .red, .orange]

    static func color(label: Int) -> Color? {
        labelColors.indices.contains(label) ? labelColors[label] : nil
    }

    /// The colour this tag is drawn in, taken from the label macOS actually
    /// stored on the files carrying it.
    static func color(for name: String) -> Color? { color(label: label(for: name)) }

    /// The label to draw, or to give a tag that is about to be created. What
    /// has been seen on disk wins; the seven tags macOS ships with are named
    /// after their colours, which is all there is to go on for a tag no
    /// indexed file carries yet.
    static func label(for name: String) -> Int {
        Registry.shared.label(for: name) ?? systemLabels[name.lowercased()] ?? 0
    }

    private static let systemLabels: [String: Int] = [
        "gray": 1, "grey": 1, "green": 2, "purple": 3,
        "blue": 4, "yellow": 5, "red": 6, "orange": 7,
    ]

    /// Seeds the colours from the index, so the sidebar is right at launch
    /// without re-reading every file.
    static func learn(_ labels: [String: Int]) { Registry.shared.learn(labels) }

    /// Name → colour label, learned from every file whose tags are read and
    /// from the index. Shared by the whole process because the views ask for a
    /// colour by name alone, wherever a tag happens to be drawn.
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
