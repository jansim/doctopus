import SwiftUI
import AppKit

/// The search field in a library window's toolbar, which only exists once
/// the whole window is on screen with its toolbar.
extension UITest {
    /// Asks `ToolbarSearch` rather than posting a keystroke: a local monitor
    /// only sees events the run loop takes off the queue itself.
    static func searchFieldTakesAndGivesUpFocus(_ model: AppModel) async {
        Check.that("⌘F is taken for the search field",
                   ToolbarSearch.focuses(characters: "f", modifiers: .command))
        Check.that("and ⌘⇧F, ⌥F and a plain F are left alone",
                   !ToolbarSearch.focuses(characters: "f", modifiers: [.command, .shift])
                       && !ToolbarSearch.focuses(characters: "f", modifiers: .option)
                       && !ToolbarSearch.focuses(characters: "f", modifiers: []))

        let window = libraryWindow(model)
        defer { window.orderOut(nil) }
        let found = await settle({ ToolbarSearch.field(in: window) != nil }, timeout: 5)
        Check.that("the library window's search field is found in its toolbar", found,
                   (window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? ["no toolbar"])
                       .joined(separator: ", "))
        guard found else { return }

        ToolbarSearch.focus(in: window)
        let focused = await settle({ ToolbarSearch.field(in: window)?.currentEditor() != nil }, timeout: 3)
        Check.that("⌘F puts the cursor in it", focused,
                   String(describing: window.firstResponder))
        guard focused, let field = ToolbarSearch.field(in: window) else { return }

        let onField = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        if field.window === window {
            ToolbarSearch.clicked(window, at: onField)
            Check.that("a click on the search field leaves the cursor there", field.currentEditor() != nil)
        }
        let layout = window.contentLayoutRect
        ToolbarSearch.clicked(window, at: NSPoint(x: layout.midX, y: layout.midY))
        Check.that("a click on a result takes the cursor out of the search field",
                   field.currentEditor() == nil, String(describing: window.firstResponder))
        window.makeFirstResponder(nil)
    }

    /// The whole window, toolbar and all, as the app shows it.
    static func libraryWindow(_ model: AppModel) -> NSWindow {
        let host = NSHostingView(rootView: RootView().environment(model))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1100, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
