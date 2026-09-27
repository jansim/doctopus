import SwiftUI
import AppKit

extension UITest {
    /// A title typed into the inspector and left without Return is asked
    /// about when another document is selected, rather than dropped, and
    /// saving it then still writes it to the document it was typed for.
    static func unsavedEditsAreAskedAbout(_ model: AppModel) async {
        guard let row = model.documents.first(where: { $0.title?.nilIfBlank != nil }),
              let other = model.documents.first(where: { $0.id != row.id }),
              let title = row.title else {
            Check.that("two documents, one titled, to edit between", false); return
        }
        model.selectedIDs = [row.id]
        guard await settle({ model.detail?.row.id == row.id }) else {
            Check.that("the document to type a title into loads", false); return
        }
        let (window, view) = host(InspectorView().environment(model),
                                  size: NSSize(width: 300, height: 780))
        defer { window.orderOut(nil); yieldFocus() }
        NSApp.activate(ignoringOtherApps: true)
        _ = await settle({ NSApp.isActive }, timeout: 2)

        guard let field = await poll(timeout: 10, { textFields(in: view).first { $0.stringValue == title } },
                                     until: { $0 != nil }) else {
            Check.that("the inspector shows the title in a field", false); return
        }
        let typed = "Typed without Return"
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else {
            Check.that("the title field takes typing", false); return
        }
        editor.selectAll(nil)
        editor.insertText(typed, replacementRange: editor.selectedRange())
        try? await Task.sleep(for: .milliseconds(300))
        Check.that("nothing is asked while the field is still there", model.unsavedEdits.isEmpty)

        model.selectedIDs = [other.id]
        let asked = await settle({ !model.unsavedEdits.isEmpty }, timeout: 10)
        Check.that("selecting another document asks about the uncommitted title",
                   asked && model.unsavedEdits.map(\.label) == ["Title"]
                       && model.unsavedEdits.first?.value == typed,
                   model.unsavedEdits.map { "\($0.label): \($0.value)" }.joined(separator: ", "))

        model.saveUnsavedEdits()
        let saved = await settle({ model.documents.first { $0.id == row.id }?.title == typed }, timeout: 10)
        Check.that("saving writes the title to the document it was typed for", saved,
                   model.documents.first { $0.id == row.id }?.title ?? "no title")
        Check.that("the question goes away once answered", model.unsavedEdits.isEmpty)

        model.editMetadata(row.id, column: "title", value: title)
        _ = await settle { model.documents.first { $0.id == row.id }?.title == title }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? [])
            + view.subviews.flatMap { textFields(in: $0) }
    }
}
