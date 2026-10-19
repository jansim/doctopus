import SwiftUI
import AppKit

extension UITest {
    /// Stepping a date with the keyboard is a draft until Return or the field
    /// losing focus, so a half-typed day never reaches the document.
    static func dateCommitsWhenDone() async {
        var commits: [Date] = []
        let start = DayDate.startOfDay(Date(timeIntervalSince1970: 1_709_510_400))
        let (window, view) = host(DayField(date: start) { commits.append($0) },
                                  size: NSSize(width: 200, height: 40))
        defer { window.orderOut(nil); yieldFocus() }
        NSApp.activate(ignoringOtherApps: true)
        _ = await settle({ NSApp.isActive }, timeout: 2)

        guard let field = await poll(timeout: 5, { dayField(in: view) }, until: { $0 != nil }) else {
            Check.that("the date field is on screen", false); return
        }
        window.makeFirstResponder(field)
        press(.up, in: field)
        press(.up, in: field)
        Check.that("arrow keys step the date", field.dateValue != start, DayDate.text(field.dateValue))
        Check.that("and nothing is saved while the field still has focus", commits.isEmpty,
                   commits.map(DayDate.text).joined(separator: ", "))

        press(.return, in: field)
        Check.that("Return saves the day once",
                   commits == [DayDate.startOfDay(field.dateValue)],
                   commits.map(DayDate.text).joined(separator: ", "))

        press(.up, in: field)
        let stepped = DayDate.startOfDay(field.dateValue)
        window.makeFirstResponder(nil)
        Check.that("leaving the field saves the draft",
                   commits.count == 2 && commits.last == stepped,
                   commits.map(DayDate.text).joined(separator: ", "))
        window.makeFirstResponder(nil)
        Check.that("and leaving it again saves nothing more", commits.count == 2)
    }

    private enum Key {
        case up, `return`

        var code: UInt16 { self == .up ? 126 : 36 }
        /// AppKit's private-use code for the up arrow, NSUpArrowFunctionKey.
        var characters: String { self == .up ? "\u{F700}" : "\r" }
    }

    /// Sent straight to the field rather than posted, so the check does not
    /// depend on the window being key.
    private static func press(_ key: Key, in field: NSView) {
        guard let window = field.window,
              let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: key.characters, charactersIgnoringModifiers: key.characters,
                isARepeat: false, keyCode: key.code)
        else { return }
        field.keyDown(with: event)
    }

    private static func dayField(in view: NSView) -> DayField.Field? {
        (view as? DayField.Field) ?? view.subviews.lazy.compactMap { dayField(in: $0) }.first
    }
}
