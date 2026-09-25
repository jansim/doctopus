import Foundation

extension UITest {
    /// Approving takes a document out of Needs Review, which says it was done;
    /// a toast on top of that is noise, whichever way the approval came.
    static func approvingIsNotAToast(_ model: AppModel) async {
        guard let lib = model.library else { return }
        model.selection = .all
        guard let row = model.documents.first else {
            Check.that("a document to approve", false)
            return
        }
        let wasApproved = row.approved
        let folder = URL(fileURLWithPath: row.directory, isDirectory: true)
        // Filing in place drops any folder alias not asked for, so ask for the ones it has.
        let aliases = Set((await model.loadDetail(row.id)?.folderAliases ?? [])
            .map { ($0 as NSString).deletingLastPathComponent })

        func waiting() async -> DocumentRow {
            try? await lib.store.setDocumentApproved(row.doc, false)
            model.refreshAll()
            model.dismissNotice()
            model.errorMessage = nil
            return await model.loadDetail(row.id)?.row ?? row
        }

        func approvedQuietly(_ how: String, from: DocumentRow) async {
            let approved = await UITest.poll(timeout: 20, { await model.loadDetail(row.id)?.row.approved }) {
                $0 == true
            }
            // Long enough for a toast that follows the refresh to have shown up.
            try? await Task.sleep(for: .seconds(1.5))
            Check.that("\(how) approves without a toast",
                       !from.approved && approved == true && model.notice == nil && model.errorMessage == nil,
                       model.notice?.text ?? model.errorMessage
                           ?? (from.approved ? "was never waiting" : approved == true ? "" : "not approved"))
        }

        let reviewed = await waiting()
        model.accept(reviewed, in: folder, alsoIn: aliases, rules: [])
        await approvedQuietly("accepting a review", from: reviewed)

        let filed = await waiting()
        model.file(filed, in: folder, alsoIn: aliases, approve: true)
        await approvedQuietly("filing and approving", from: filed)

        let batched = await waiting()
        let asItIs = ReviewTreatment(move: false, version: nil)
        model.approve([batched], newArrivals: asItIs, alreadyInLibrary: asItIs)
        await approvedQuietly("approving a batch", from: batched)

        let current = await model.loadDetail(row.id)?.row ?? row
        model.dismissNotice()
        model.file(current, in: folder, alsoIn: aliases, approve: false)
        let said = await UITest.settle({ model.notice != nil }, timeout: 10)
        Check.that("filing without approving still says so", said, model.errorMessage ?? "nothing")

        try? await lib.store.setDocumentApproved(row.doc, wasApproved)
        model.refreshAll()
        model.dismissNotice()
    }
}
