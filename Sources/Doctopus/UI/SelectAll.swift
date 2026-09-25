import AppKit

/// ⌘A selects every document in the pane, wherever focus is in the library
/// window — the sidebar, the gallery's grid, a toolbar button — except while
/// text is being edited, where it keeps selecting the text. Taken ahead of the
/// menu because nothing but the list's table answers `selectAll:`, so from
/// anywhere else the Edit menu's item did nothing.
@MainActor
enum SelectAllDocuments {
    private static var select: @MainActor (NSWindow?) -> Bool = { _ in false }

    /// `select` is handed the key window and says whether it took the keystroke.
    static func install(_ select: @escaping @MainActor (NSWindow?) -> Bool) {
        self.select = select
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard applies(characters: characters, modifiers: modifiers,
                              editingText: NSApp.keyWindow?.firstResponder is NSText)
                else { return false }
                return Self.select(NSApp.keyWindow)
            }
            return taken ? nil : event
        }
    }

    static func applies(characters: String?, modifiers: NSEvent.ModifierFlags,
                        editingText: Bool) -> Bool {
        guard characters?.lowercased() == "a" else { return false }
        let held = modifiers.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        return held == .command && !editingText
    }
}
