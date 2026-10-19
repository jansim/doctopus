import AppKit

/// The search field `.searchable` puts in a library window's toolbar. SwiftUI
/// gives no handle on it, so this finds it in the window to give it the
/// keyboard on ⌘F, and to take the keyboard back from it on a click anywhere
/// else.
@MainActor
enum ToolbarSearch {
    /// Takes ⌘F ahead of the menu, whose Find… goes to a find bar the window
    /// does not have.
    static func install() {
        // The gallery's cells answer a click without becoming first responder,
        // so picking a result there left the cursor in the field, and Space
        // typed into it rather than opening Quick Look.
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            let point = event.locationInWindow
            let number = event.windowNumber
            MainActor.assumeIsolated {
                if let window = NSApp.window(withWindowNumber: number) { clicked(window, at: point) }
            }
            return event
        }
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let number = event.windowNumber
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard focuses(characters: characters, modifiers: modifiers),
                      let window = NSApp.window(withWindowNumber: number) ?? NSApp.keyWindow
                else { return false }
                return focus(in: window)
            }
            return taken ? nil : event
        }
    }

    static func focuses(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard characters?.lowercased() == "f" else { return false }
        let held = modifiers.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        return held == .command
    }

    /// Puts the cursor in the window's search field, if it has one, and says
    /// whether it did.
    @discardableResult
    static func focus(in window: NSWindow) -> Bool {
        if let item = searchItem(in: window) {
            item.beginSearchInteraction()
            return true
        }
        guard let field = field(in: window), let host = field.window else { return false }
        return host.makeFirstResponder(field)
    }

    /// Ends editing in the window's search field unless the click, at a point
    /// in the window's coordinates, landed on the field itself.
    static func clicked(_ window: NSWindow, at point: NSPoint) {
        guard let field = field(in: window), field.currentEditor() != nil else { return }
        // In full screen the toolbar lives in a window of its own.
        if field.window === window, field.bounds.contains(field.convert(point, from: nil)) { return }
        field.window?.makeFirstResponder(nil)
    }

    static func field(in window: NSWindow) -> NSSearchField? {
        if let item = searchItem(in: window) { return item.searchField }
        return window.toolbar?.items.lazy.compactMap { $0.view.flatMap(firstSearchField) }.first
    }

    private static func searchItem(in window: NSWindow) -> NSSearchToolbarItem? {
        window.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap(firstSearchField).first
    }
}
