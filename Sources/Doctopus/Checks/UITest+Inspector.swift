import SwiftUI
import AppKit

/// The inspector, and what it keeps of a document’s history.
extension UITest {
    static func inspectorDraws(_ model: AppModel, snapshots: String?) async {
        guard let first = model.documents.first else { return }
        model.selectedIDs = [first.id]
        guard await settle({ model.detail != nil }) else {
            Check.that("inspector loads the selected document", false)
            return
        }
        let (window, host) = host(InspectorView().environment(model),
                                  size: NSSize(width: 300, height: 780))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/inspector.png") }
        Check.that("inspector draws its content", inkedRows(host) > 20, "\(inkedRows(host)) rows with ink")
    }

    static func handEditsReachTheHistory(_ model: AppModel) async {
        guard let row = model.documents.first else { return }
        model.selectedIDs = [row.id]
        guard await settle({ model.detail?.row.id == row.id }) else {
            Check.that("the document a hand edit is made on loads", false)
            return
        }
        let before = model.detail?.history.count ?? 0
        let queueBefore = model.queue.count

        func recorded(_ needle: String) -> Bool {
            model.detail?.history.contains {
                $0.action == .edited && $0.detail?.contains(needle) == true
            } == true
        }

        let tag = "HandEdited"
        model.addTag(tag, to: [row])
        let tagged = await settle { recorded(tag) }
        Check.that("a tag added by hand is recorded in the history", tagged,
                   model.detail?.history.compactMap(\.detail).prefix(3)
                       .joined(separator: " / ") ?? "no events")

        let finderTag = "Green"
        model.addFinderTag(finderTag, to: [row])
        let finderTagged = await settle { recorded(finderTag) }
        Check.that("a Finder tag added by hand is recorded in the history", finderTagged)

        let title = "Titled by the checks"
        model.editMetadata(row.id, column: "title", value: title)
        let retitled = await settle { recorded(title) }
        Check.that("a title typed by hand is recorded in the history", retitled)

        Check.that("each hand edit is its own history entry",
                   (model.detail?.history.count ?? 0) >= before + 3
                       && recorded(tag) && recorded(finderTag) && recorded(title),
                   "\(model.detail?.history.count ?? 0) events, was \(before)")
        let titled = model.detail?.history.first { $0.detail?.contains(title) == true }
        Check.that("a hand edit can be reverted from the history",
                   titled?.revert == .rows && model.detail?.history.contains {
                       $0.detail?.contains(finderTag) == true && $0.revert == nil
                   } == true)

        Check.that("a hand edit does not queue the document for review",
                   model.queue.count <= queueBefore
                       && model.documents.first { $0.id == row.id }?.approved != false,
                   "\(model.queue.count) entries, was \(queueBefore)")

        let summary = "Summarized by the checks"
        model.editMetadata(row.id, column: "summary", value: summary)
        let summarized = await settle {
            recorded(summary) && model.detail?.row.summary == summary
        }
        Check.that("a summary typed by hand is saved and recorded in the history", summarized,
                   model.detail?.row.summary ?? "no summary")
        if let edit = model.detail?.history.first(where: { $0.detail?.contains(summary) == true }) {
            await model.revert(edit)
            let reverted = await settle {
                model.detail?.row.summary == row.summary
                    && model.detail?.history.contains { $0.id == edit.id && $0.reverted } == true
            }
            Check.that("reverting it from the history puts the summary back", reverted,
                       model.detail?.row.summary ?? "no summary")
        }

        model.removeFinderTag(finderTag, from: [row])
        if let added = model.tags.first(where: { $0.name == tag }) {
            model.removeTag(added, from: [row])
            let untagged = await settle { recorded("Untagged") }
            Check.that("taking a tag off by hand is recorded too", untagged)
            model.deleteTag(added)
        }
        model.editMetadata(row.id, column: "title", value: row.title)
        model.editMetadata(row.id, column: "summary", value: row.summary)
        _ = await settle {
            model.documents.first { $0.id == row.id }.map {
                $0.title == row.title && $0.summary == row.summary
            } == true
        }
    }

    static func changeHistoryDraws(_ model: AppModel, snapshots: String?) async {
        let (window, host) = host(ChangeHistorySheet().environment(model),
                                  size: NSSize(width: 560, height: 520))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(1))
        if let dir = snapshots { snapshot(host, to: dir + "/change-history.png") }
        let logged = await model.changeLog(limit: 50)
        Check.that("the change history lists the library's changes",
                   logged.contains { $0.action == .edited } && logged.contains { $0.docID == nil },
                   "\(logged.count) changes")
        Check.that("the change history draws them", inkedRows(host) > 40, "\(inkedRows(host)) rows with ink")
    }
}
