import Foundation
import AppKit

extension AppModel {

    /// Every change to the library, newest first.
    func changeLog(limit: Int) async -> [HistoryEvent] {
        guard let lib = library else { return [] }
        do { return try await lib.store.changeLog(limit: limit) }
        catch { report(error, "read the history"); return [] }
    }

    /// Takes one change back, from a document's history or the library's.
    /// The revert is a change of its own, so it can be taken back in turn.
    /// One whose result has been changed again since is asked about first:
    /// reverting it would quietly take that later change back as well.
    func revert(_ event: HistoryEvent) async {
        guard let lib = library else { return }
        if (try? await lib.store.changedSince(event.id)) == true,
           !Self.confirmRevert(event) { return }
        do { try await lib.indexer.revert(event.id) }
        catch { report(error, "revert “\(event.summary)”"); return }
        notify("Reverted “\(event.summary)”.")
        refreshAll()
        reloadDetail()
        refreshRuleMatches()
    }

    /// Replaced by the headless checks, which cannot answer an alert.
    static var confirmRevert: @MainActor (HistoryEvent) -> Bool = defaultConfirmRevert

    static let defaultConfirmRevert: @MainActor (HistoryEvent) -> Bool = { event in
        let alert = NSAlert()
        alert.messageText = "Revert “\(event.summary)”?"
        alert.informativeText = "Some of what this change did has been changed again since. "
            + "Reverting it puts back how things were before it, and so takes those later changes back too. "
            + "The revert can itself be reverted."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
