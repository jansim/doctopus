import Foundation

extension AppModel {

    /// Nil unless the naming setting points mismatches out; a suppressed one
    /// is still returned, so it can be handed back.
    func namingMismatch(for row: DocumentRow) -> NamingMismatch? {
        guard settings.namingEnforcement.highlights else { return nil }
        return library?.namingMismatches[row.doc]
    }

    func pendingNamingMismatch(for row: DocumentRow) -> NamingMismatch? {
        namingMismatch(for: row).flatMap { $0.isPending ? $0 : nil }
    }

    /// Goes through Rename…, so the name counts as the template's from now on
    /// and Undo takes it back.
    func renameToTemplate(_ row: DocumentRow) {
        rename([row], template: settings.namingTemplate)
    }

    func setNamingSuppressed(_ suppressed: Bool, for row: DocumentRow) {
        guard let lib = library else { return }
        Task {
            do { try await lib.store.setNamingSuppressed(suppressed, doc: row.doc) }
            catch {
                report(error, suppressed ? "keep the name of “\(row.displayTitle)”"
                                         : "hand the name of “\(row.displayTitle)” back to the template")
                return
            }
            // Update now rather than after the debounced pass.
            lib.namingMismatches[row.doc]?.suppressed = suppressed
            try? await lib.store.logEdit(docID: row.doc, detail: suppressed
                                         ? "Name kept apart from the naming template"
                                         : "Name follows the naming template again")
            refreshRuleMatches()
            reloadDetail()
        }
    }

    /// After documents' fields changed by hand, renames what the naming
    /// setting says should follow them, as one step Undo takes back.
    /// `mark` is from before the edit.
    func followNaming(_ docs: [Int64], since mark: Int64, in lib: Library) async {
        guard lib.settings.namingEnforcement.followsEdits else { return }
        let result = await lib.indexer.followNaming(docs)
        report(failures: result.failures, "rename")
        guard result.done > 0 else { return }
        offerUndo("Rename", docs: docs, since: mark)
        notify(result.done == 1 ? "Renamed the file to match the naming template."
                                : "Renamed \(result.done) files to match the naming template.")
    }
}
