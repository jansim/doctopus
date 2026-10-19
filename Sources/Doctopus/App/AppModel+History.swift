import Foundation

extension AppModel {

    /// Every change to the library, newest first.
    func changeLog(limit: Int) async -> [HistoryEvent] {
        guard let lib = library else { return [] }
        do { return try await lib.store.changeLog(limit: limit) }
        catch { report(error, "read the history"); return [] }
    }

    /// Takes one change back, from a document's history or the library's.
    /// The revert is a change of its own, so it can be taken back in turn.
    func revert(_ event: HistoryEvent) async {
        guard let lib = library else { return }
        do { try await lib.indexer.revert(event.id) }
        catch { report(error, "revert “\(event.summary)”"); return }
        notify("Reverted “\(event.summary)”.")
        refreshAll()
        reloadDetail()
        refreshRuleMatches()
    }
}
