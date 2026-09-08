import Foundation
import AppKit
import SwiftUI

/// The Finder's own tags, which live on the file in extended attributes rather
/// than in this app's index. Reading them is cheap; writing one is a deliberate
/// change to the user's file and only ever happens on an explicit action.
enum FinderTags {
    static func read(_ url: URL) -> [String] {
        ((try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
    }

    @discardableResult
    static func write(_ names: [String], to url: URL) -> Bool {
        // NSURL rather than URL: the Swift bridge for tagNames is read-only.
        do {
            try (url as NSURL).setResourceValue(names as NSArray, forKey: .tagNamesKey)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func add(_ name: String, to url: URL) -> Bool {
        var names = read(url)
        guard !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return true }
        names.append(name)
        return write(names, to: url)
    }

    @discardableResult
    static func remove(_ name: String, from url: URL) -> Bool {
        let names = read(url).filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        return write(names, to: url)
    }

    /// The seven tags macOS ships with are colours; anything else the user has
    /// made is shown neutrally, since the Finder keeps that mapping to itself.
    static func color(for name: String) -> Color? {
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "gray", "grey": return .gray
        default: return nil
        }
    }
}
