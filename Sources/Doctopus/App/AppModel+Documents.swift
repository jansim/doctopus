import Foundation
import AppKit

extension AppModel {

    static func editDetail(_ label: String, _ value: String?) -> String {
        guard let value = value?.nilIfBlank else { return "\(label) cleared" }
        return "\(label) → \(value)"
    }

    /// Fills `revealedFolders` for the current selection, or empties it once ⌥
    /// is let go. Aliases count: a document filed in a second folder is in
    /// that folder too, and that is the one a glance at the list cannot show.
    func refreshRevealedFolders() {
        revealTask?.cancel()
        guard revealingFolders, let lib = library, !selectedRows.isEmpty else {
            if !revealedFolders.isEmpty { revealedFolders = [] }
            return
        }
        let rows = selectedRows
        revealTask = Task { [weak self] in
            var folders: Set<String> = []
            for row in rows {
                folders.insert(row.directory)
                for alias in ((try? await lib.store.aliases(for: row.doc)) ?? []) {
                    folders.insert((alias.path as NSString).deletingLastPathComponent)
                }
            }
            guard !Task.isCancelled, let self, self.revealingFolders else { return }
            if folders != self.revealedFolders { self.revealedFolders = folders }
        }
    }

    func quickLook(startingAt row: DocumentRow? = nil) {
        let rows = selectedRows.isEmpty ? documents : selectedRows
        guard !rows.isEmpty else { return }
        QuickLookController.shared.toggle(urls: rows.map(\.url),
                                          startingAt: row?.url ?? lastSelected?.url)
    }

    func reveal(_ rows: [DocumentRow]) {
        NSWorkspace.shared.activateFileViewerSelecting(rows.map(\.url))
    }

    func open(_ rows: [DocumentRow]) {
        for row in rows { Self.opener(row.url) }
    }

    static var opener: (URL) -> Void = defaultOpener
    static let defaultOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    func reprocess(_ rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            let n = await lib.indexer.reprocess(ids: rows.map(\.doc))
            switch n {
            case 0: notify("Nothing to reprocess — those files are no longer on disk.", .info)
            case 1: notify("Reprocessed “\(rows.first?.displayTitle ?? "document")”.")
            default: notify("Reprocessed \(n) documents.")
            }
        }
    }

    func addTag(_ name: String, to rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            if let id = try? await lib.store.tagID(named: name), id > 0 {
                for row in rows {
                    try? await lib.store.assign(tag: id, to: row.doc)
                    try? await lib.store.logEdit(docID: row.doc, detail: "Tagged “\(name)”")
                    await lib.indexer.syncAliases(docID: row.doc, target: row.url)
                }
            }
            refreshAll()
            reloadDetail()
        }
    }

    func removeTag(_ tag: Tag, from rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            for row in rows where row.library == tag.library {
                try? await lib.store.unassign(tag: tag.tagID, from: row.doc)
                try? await lib.store.logEdit(docID: row.doc, detail: "Untagged “\(tag.name)”")
                await lib.indexer.syncAliases(docID: row.doc, target: row.url)
            }
            refreshAll()
            reloadDetail()
        }
    }

    func acceptTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.acceptTagSuggestion(suggestion.name, for: row.doc)
            try? await lib.store.logEdit(docID: row.doc,
                                         detail: "Tagged “\(suggestion.name)”")
            await lib.indexer.syncAliases(docID: row.doc, target: row.url)
            refreshAll()
            reloadDetail()
        }
    }

    func discardTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.discardTagSuggestion(suggestion.name, for: row.doc)
            reloadDetail()
        }
    }

    func setTagMirroring(_ tag: Tag, enabled: Bool) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.setTagMirroring(tag.tagID, enabled, folder: tag.folder)
            let rows = (try? await lib.store.listDocuments(selection: .tag(tag.id), query: SearchQuery(""),
                                                           sort: .added, ascending: false, limit: 5000)) ?? []
            for row in rows { await lib.indexer.syncAliases(docID: row.doc, target: row.url) }
            refreshAll()
        }
    }

    func setTagParent(_ tag: Tag, to parent: Tag?) {
        guard let lib = library else { return }
        Task {
            let moved = (try? await lib.store.setTagParent(tag.tagID, to: parent?.tagID)) ?? false
            if !moved, parent != nil {
                errorMessage = "“\(tag.name)” cannot go under “\(parent?.name ?? "")”: "
                    + "a tag cannot sit inside itself, and tags nest at most \(Tag.maxDepth) deep."
            }
            refreshAll()
        }
    }

    func createTag(named name: String) {
        guard let lib = library else { return }
        Task { _ = try? await lib.store.tagID(named: name); refreshAll() }
    }

    func renameTag(_ tag: Tag, to name: String) {
        guard let lib = library else { return }
        Task {
            let survivor = (try? await lib.store.renameTag(tag.tagID, to: name)) ?? tag.tagID
            if selection == .tag(tag.id) {
                selection = .tag(TagRef(library: tag.library, tag: survivor))
            }
            refreshAll()
            reloadDetail()
        }
    }

    func setTagColor(_ tag: Tag, _ color: Int64) {
        guard let lib = library else { return }
        Task { try? await lib.store.setTagColor(tag.tagID, color); refreshAll(); reloadDetail() }
    }

    func deleteTag(_ tag: Tag) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.deleteTag(tag.tagID)
            if selection == .tag(tag.id) { selection = .all }
            refreshAll()
        }
    }

    /// Writing one changes the file's extended attributes, so it only ever
    /// happens on an explicit action, and the index is refreshed from whatever
    /// the disk ends up saying rather than from what we asked for.
    func addFinderTag(_ name: String, to rows: [DocumentRow]) {
        guard let lib = library else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        Task {
            for row in rows where FinderTags.add(clean, to: row.url) {
                try? await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url))
                try? await lib.store.logEdit(docID: row.doc,
                                             detail: "Finder tag “\(clean)” added")
            }
            refreshAll()
            reloadDetail()
        }
    }

    func removeFinderTag(_ name: String, from rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            for row in rows where FinderTags.remove(name, from: row.url) {
                try? await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url))
                try? await lib.store.logEdit(docID: row.doc,
                                             detail: "Finder tag “\(name)” removed")
            }
            if selection == .finderTag(name) { selection = .all }
            refreshAll()
            reloadDetail()
        }
    }

    func setValueIcon(_ field: Field, value: String, icon: String?) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.setValueIcon(field: field, value: value, icon: icon)
            refreshAll()
        }
    }

    func addNote(_ body: String, to ref: DocumentRef) {
        guard let lib = library, body.nilIfBlank != nil else { return }
        Task {
            _ = try? await lib.store.addNote(body, to: ref.doc)
            try? await lib.store.logEdit(docID: ref.doc, detail: "Note added")
            reloadDetail()
        }
    }

    func updateNote(_ id: Int64, body: String, in ref: DocumentRef) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.updateNote(id, body: body)
            try? await lib.store.logEdit(docID: ref.doc,
                                         detail: body.nilIfBlank == nil ? "Note deleted" : "Note edited")
            reloadDetail()
        }
    }

    func deleteNote(_ id: Int64, in ref: DocumentRef) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.deleteNote(id)
            try? await lib.store.logEdit(docID: ref.doc, detail: "Note deleted")
            reloadDetail()
        }
    }

    func setFieldValue(_ rows: [DocumentRow], field: Field, value: String?) {
        guard let lib = library else { return }
        Task {
            for row in rows {
                try? await lib.store.setFieldValue(docID: row.doc, field: field, value: value)
                try? await lib.store.logEdit(docID: row.doc,
                                             detail: Self.editDetail(field.name, value))
            }
            await lib.indexer.reroute(rows.map(\.doc), applyingActions: false)
            reloadDetail()
            refreshAll()
        }
    }

    func setFieldValue(_ ref: DocumentRef, field: Field, value: String?) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.setFieldValue(docID: ref.doc, field: field, value: value)
            try? await lib.store.logEdit(docID: ref.doc, detail: Self.editDetail(field.name, value))
            await lib.indexer.reroute([ref.doc], applyingActions: false)
            reloadDetail()
            refreshAll()
        }
    }

    func renameFieldValue(_ field: Field, from old: String, to new: String) {
        guard let lib = library else { return }
        Task {
            let n = (try? await lib.store.renameFieldValue(field: field, from: old, to: new)) ?? 0
            if case .field(let key, let value) = selection, key == field.key, value == old {
                selection = .field(field.key, new)
            }
            refreshAll()
            if n > 0 { notify("Renamed “\(old)” to “\(new)” on \(n) document\(n == 1 ? "" : "s").") }
        }
    }

    func setEntityMatch(_ field: Field, value: String, pattern: String) {
        guard let lib = library else { return }
        Task {
            if let column = field.builtinColumn,
               let id = try? await lib.store.existingEntityID(named: value, builtin: column) {
                try? await lib.store.setEntityMatch(id, pattern: pattern.nilIfBlank)
            }
            refreshAll()
            if pattern.nilIfBlank != nil {
                notify("Documents mentioning that will be filed as “\(value)”.")
            }
        }
    }

    func deleteFieldValue(_ field: Field, value: String) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.deleteFieldValue(field: field, value: value)
            if selection == .field(field.key, value) { selection = .all }
            refreshAll()
        }
    }

    func updateField(_ field: Field) {
        guard let lib = library else { return }
        listColumns[visibility: "field.\(field.key)"] = .automatic
        Task {
            try? await lib.store.updateField(field)
            refreshAll()
        }
    }

    func addCustomField(named name: String, type: FieldType = .string) {
        guard let lib = library else { return }
        Task {
            _ = try? await lib.store.addCustomField(name: name, type: type)
            refreshAll()
        }
    }

    func deleteField(_ field: Field) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.deleteField(field.fieldID)
            if case .field(let key, _) = selection, key == field.key { selection = .all }
            refreshAll()
        }
    }

    func editMetadata(_ ref: DocumentRef, column: String, value: String?) {
        guard let lib = library else { return }
        let label = columnLabel(column)
        Task {
            try? await lib.store.overwriteMetadataField(ref.doc, column: column, value: value?.nilIfBlank)
            try? await lib.store.logEdit(docID: ref.doc,
                                         detail: Self.editDetail(label, value))
            await lib.indexer.reroute([ref.doc], applyingActions: false)
            reloadDetail()
            reloadDocuments()
            refreshRuleMatches()
        }
    }

    private func columnLabel(_ column: String) -> String {
        if let field = fields.first(where: { $0.builtinColumn == column }) { return field.name }
        return column == "summary" ? "Summary" : "Title"
    }

    func setDocumentDate(_ ref: DocumentRef, _ date: Date?) {
        guard let lib = library else { return }
        Task {
            try? await lib.store.setDocumentDate(ref.doc, date)
            try? await lib.store.logEdit(
                docID: ref.doc,
                detail: Self.editDetail("Date", date.map(DayDate.display)))
            await lib.indexer.reroute([ref.doc], applyingActions: false)
            reloadDetail()
            reloadDocuments()
            refreshRuleMatches()
        }
    }
}
