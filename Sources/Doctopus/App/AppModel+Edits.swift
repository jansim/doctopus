import Foundation

/// A value typed into a field that went away — another document selected, the
/// document leaving the queue — before Return committed it. `save` still knows
/// which document it belongs to, so it can be written after the field is gone.
struct UnsavedEdit: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let save: @MainActor () -> Void
}

extension AppModel {
    /// Asks, rather than drops: a half-typed title is the user's work too.
    func holdUnsavedEdit(_ edit: UnsavedEdit) {
        unsavedEdits.append(edit)
    }

    func saveUnsavedEdits() {
        let edits = unsavedEdits
        unsavedEdits = []
        for edit in edits { edit.save() }
    }

    func discardUnsavedEdits() {
        unsavedEdits = []
    }

    var unsavedEditsQuestion: String {
        let labels = unsavedEdits.map(\.label)
        let joined = ListFormatter.localizedString(byJoining: labels)
        return labels.count == 1 ? "Save the change to \(joined)?" : "Save the changes to \(joined)?"
    }

    var unsavedEditsExplanation: String {
        let typed = unsavedEdits.map { "\($0.label): “\($0.value)”" }.joined(separator: "\n")
        return typed + (unsavedEdits.count == 1 ? "\n\nThis was typed but not saved with Return."
                                                : "\n\nThese were typed but not saved with Return.")
    }
}
