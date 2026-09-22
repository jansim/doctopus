import Foundation
import AppKit

extension AppModel {

    /// How an edit reads in the history: "Amount → €49,90", or "Amount cleared".
    static func editDetail(_ label: String, _ value: String?) -> String {
        guard let value = value?.nilIfBlank else { return "\(label) cleared" }
        return "\(label) → \(value)"
    }

    // MARK: - Where the selection lives

    /// Fills `revealedFolders` for the current selection, or empties it once ⌥
    /// is let go. Aliases count: a document filed in a second folder is in
    /// that folder too, and that is the one a glance at the list cannot show.
    func refreshRevealedFolders() {
        revealTask?.cancel()
        guard revealingFolders, !selectedRows.isEmpty else {
            if !revealedFolders.isEmpty { revealedFolders = [] }
            return
        }
        let groups = grouped(selectedRows)
        revealTask = Task { [weak self] in
            var folders: Set<String> = []
            for (lib, rows) in groups {
                for row in rows {
                    folders.insert(row.directory)
                    for alias in ((try? await lib.store.aliases(for: row.doc)) ?? []) {
                        folders.insert((alias.path as NSString).deletingLastPathComponent)
                    }
                }
            }
            guard !Task.isCancelled, let self, self.revealingFolders else { return }
            if folders != self.revealedFolders { self.revealedFolders = folders }
        }
    }

    // MARK: - Document actions

    /// Space and the Document menu land here.
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
        Task {
            var n = 0
            for (lib, rows) in grouped(rows) {
                n += await lib.indexer.reprocess(ids: rows.map(\.doc))
            }
            switch n {
            case 0: notify("Nothing to reprocess — those files are no longer on disk.", .info)
            case 1: notify("Reprocessed “\(rows.first?.displayTitle ?? "document")”.")
            default: notify("Reprocessed \(n) documents.")
            }
        }
    }

    // MARK: - Tags

    /// Tagging a mixed selection tags each row in its own library, creating the
    /// tag there if it is missing. Two libraries can carry the same tag name
    /// without it being one tag.
    func addTag(_ name: String, to rows: [DocumentRow]) {
        Task {
            for (lib, rows) in grouped(rows) {
                guard let id = try? await lib.store.tagID(named: name), id > 0 else { continue }
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

    /// A tag belongs to one library, so this only touches the rows from it.
    func removeTag(_ tag: Tag, from rows: [DocumentRow]) {
        guard let lib = library(tag.library) else { return }
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

    /// Turns a tag the model proposed into a real assignment.
    func acceptTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library(of: row) else { return }
        Task {
            try? await lib.store.acceptTagSuggestion(suggestion.name, for: row.doc)
            try? await lib.store.logEdit(docID: row.doc,
                                         detail: "Tagged “\(suggestion.name)”")
            await lib.indexer.syncAliases(docID: row.doc, target: row.url)
            refreshAll()
            reloadDetail()
        }
    }

    /// Dismisses a proposed tag without ever making it a real one.
    func discardTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library(of: row) else { return }
        Task {
            try? await lib.store.discardTagSuggestion(suggestion.name, for: row.doc)
            reloadDetail()
        }
    }

    func setTagMirroring(_ tag: Tag, enabled: Bool) {
        guard let lib = library(tag.library) else { return }
        Task {
            try? await lib.store.setTagMirroring(tag.tagID, enabled, folder: tag.folder)
            // Re-sync every document carrying the tag so disk matches immediately.
            let rows = (try? await lib.store.listDocuments(selection: .tag(tag.id), query: SearchQuery(""),
                                                           sort: .added, ascending: false, limit: 5000)) ?? []
            for row in rows { await lib.indexer.syncAliases(docID: row.doc, target: row.url) }
            refreshAll()
        }
    }

    /// Moves a tag under another, or back to the top level. Refused when it
    /// would make a loop or push the tree past its depth cap — the store is the
    /// one that knows, so the answer comes back from there.
    func setTagParent(_ tag: Tag, to parent: Tag?) {
        guard let lib = library(tag.library) else { return }
        if let parent, parent.library != tag.library {
            errorMessage = "Tags can only be nested inside their own library."
            return
        }
        Task {
            let moved = (try? await lib.store.setTagParent(tag.tagID, to: parent?.tagID)) ?? false
            if !moved, parent != nil {
                errorMessage = "“\(tag.name)” cannot go under “\(parent?.name ?? "")”: "
                    + "a tag cannot sit inside itself, and tags nest at most \(Tag.maxDepth) deep."
            }
            refreshAll()
        }
    }

    /// New tags go to the library the sidebar selection belongs to.
    func createTag(named name: String, in lib: Library? = nil) {
        guard let lib = lib ?? activeLibrary else { return }
        Task { _ = try? await lib.store.tagID(named: name); refreshAll() }
    }

    func renameTag(_ tag: Tag, to name: String) {
        guard let lib = library(tag.library) else { return }
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
        guard let lib = library(tag.library) else { return }
        Task { try? await lib.store.setTagColor(tag.tagID, color); refreshAll(); reloadDetail() }
    }

    func deleteTag(_ tag: Tag) {
        guard let lib = library(tag.library) else { return }
        Task {
            try? await lib.store.deleteTag(tag.tagID)
            if selection == .tag(tag.id) { selection = .all }
            refreshAll()
        }
    }

    // MARK: - Finder tags

    /// Writing one changes the file's extended attributes, so it only ever
    /// happens on an explicit action, and the index is refreshed from whatever
    /// the disk ends up saying rather than from what we asked for.
    func addFinderTag(_ name: String, to rows: [DocumentRow]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows where FinderTags.add(clean, to: row.url) {
                    try? await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url))
                    try? await lib.store.logEdit(docID: row.doc,
                                                 detail: "Finder tag “\(clean)” added")
                }
            }
            refreshAll()
            reloadDetail()
        }
    }

    func removeFinderTag(_ name: String, from rows: [DocumentRow]) {
        Task {
            for (lib, rows) in grouped(rows) {
                for row in rows where FinderTags.remove(name, from: row.url) {
                    try? await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url))
                    try? await lib.store.logEdit(docID: row.doc,
                                                 detail: "Finder tag “\(name)” removed")
                }
            }
            if selection == .finderTag(name) { selection = .all }
            refreshAll()
            reloadDetail()
        }
    }

    // MARK: - Value icons

    /// Field values are matched across libraries, so an icon chosen for one is
    /// set everywhere the field exists.
    func setValueIcon(_ field: Field, value: String, icon: String?) {
        Task {
            for (lib, field) in librariesDefining(field) {
                try? await lib.store.setValueIcon(field: field, value: value, icon: icon)
            }
            refreshAll()
        }
    }

    // MARK: - Fields

    /// Each library's own copy of a field key, for the actions the merged field
    /// list has to apply everywhere at once.
    func librariesDefining(_ field: Field) -> [(Library, Field)] {
        libraries.compactMap { lib in
            lib.fields.first { $0.key == field.key }.map { (lib, $0) }
        }
    }

    // MARK: - Notes

    /// A note is the escape hatch for what no field models — and it is indexed
    /// with the document's text, so it is findable afterwards.
    func addNote(_ body: String, to ref: DocumentRef) {
        guard let lib = library(ref.library), body.nilIfBlank != nil else { return }
        Task {
            _ = try? await lib.store.addNote(body, to: ref.doc)
            try? await lib.store.logEdit(docID: ref.doc, detail: "Note added")
            reloadDetail()
        }
    }

    func updateNote(_ id: Int64, body: String, in ref: DocumentRef) {
        guard let lib = library(ref.library) else { return }
        Task {
            try? await lib.store.updateNote(id, body: body)
            // Editing a note to nothing deletes it.
            try? await lib.store.logEdit(docID: ref.doc,
                                         detail: body.nilIfBlank == nil ? "Note deleted" : "Note edited")
            reloadDetail()
        }
    }

    func deleteNote(_ id: Int64, in ref: DocumentRef) {
        guard let lib = library(ref.library) else { return }
        Task {
            try? await lib.store.deleteNote(id)
            try? await lib.store.logEdit(docID: ref.doc, detail: "Note deleted")
            reloadDetail()
        }
    }

    func setFieldValue(_ rows: [DocumentRow], field: Field, value: String?) {
        Task {
            for (lib, rows) in grouped(rows) {
                guard let owned = lib.fields.first(where: { $0.key == field.key }) else { continue }
                for row in rows {
                    try? await lib.store.setFieldValue(docID: row.doc, field: owned, value: value)
                    try? await lib.store.logEdit(docID: row.doc,
                                                 detail: Self.editDetail(field.name, value))
                }
            }
            reloadDetail()
            refreshAll()
        }
    }

    func setFieldValue(_ ref: DocumentRef, field: Field, value: String?) {
        guard let lib = library(ref.library),
              let owned = lib.fields.first(where: { $0.key == field.key }) else { return }
        Task {
            try? await lib.store.setFieldValue(docID: ref.doc, field: owned, value: value)
            try? await lib.store.logEdit(docID: ref.doc, detail: Self.editDetail(field.name, value))
            reloadDetail()
            refreshAll()
        }
    }

    /// Renaming a value onto an existing one merges every matching document.
    func renameFieldValue(_ field: Field, from old: String, to new: String) {
        Task {
            var n = 0
            for (lib, field) in librariesDefining(field) {
                n += (try? await lib.store.renameFieldValue(field: field, from: old, to: new)) ?? 0
            }
            if case .field(let key, let value) = selection, key == field.key, value == old {
                selection = .field(field.key, new)
            }
            refreshAll()
            if n > 0 { notify("Renamed “\(old)” to “\(new)” on \(n) document\(n == 1 ? "" : "s").") }
        }
    }

    /// Gives a correspondent or document type a pattern that identifies it, so
    /// every document mentioning it is filed as it from now on — no model, no
    /// network, and right every time the pattern is. An empty pattern stops it.
    func setEntityMatch(_ field: Field, value: String, pattern: String) {
        Task {
            for (lib, owned) in librariesDefining(field) {
                guard let column = owned.builtinColumn,
                      let id = try? await lib.store.existingEntityID(named: value, builtin: column)
                else { continue }
                try? await lib.store.setEntityMatch(id, pattern: pattern.nilIfBlank)
            }
            refreshAll()
            if pattern.nilIfBlank != nil {
                notify("Documents mentioning that will be filed as “\(value)”.")
            }
        }
    }

    func deleteFieldValue(_ field: Field, value: String) {
        Task {
            for (lib, field) in librariesDefining(field) {
                try? await lib.store.deleteFieldValue(field: field, value: value)
            }
            if selection == .field(field.key, value) { selection = .all }
            refreshAll()
        }
    }

    func updateField(_ field: Field) {
        // An explicit choice in Settings supersedes one made in the list header.
        listColumns[visibility: "field.\(field.key)"] = .automatic
        Task {
            // The list shows one column per key, so a change to it has to reach
            // every library that has that key or the next refresh would undo it.
            for (lib, owned) in librariesDefining(field) {
                var updated = field
                updated.fieldID = owned.fieldID
                updated.library = lib.id
                try? await lib.store.updateField(updated)
            }
            refreshAll()
        }
    }

    /// Fields are a vocabulary the open libraries share — the centre pane shows
    /// one column per key however many libraries fill it — so a new one is
    /// added to every library rather than to a chosen one.
    func addCustomField(named name: String, type: FieldType = .string) {
        Task {
            for lib in libraries {
                _ = try? await lib.store.addCustomField(name: name, type: type)
            }
            refreshAll()
        }
    }

    func deleteField(_ field: Field) {
        Task {
            for (lib, owned) in librariesDefining(field) {
                try? await lib.store.deleteField(owned.fieldID)
            }
            if case .field(let key, _) = selection, key == field.key { selection = .all }
            refreshAll()
        }
    }

    // MARK: - Metadata editing

    func editMetadata(_ ref: DocumentRef, column: String, value: String?) {
        guard let lib = library(ref.library) else { return }
        let label = columnLabel(column)
        Task {
            try? await lib.store.overwriteMetadataField(ref.doc, column: column, value: value?.nilIfBlank)
            try? await lib.store.logEdit(docID: ref.doc,
                                         detail: Self.editDetail(label, value))
            reloadDetail()
            reloadDocuments()
        }
    }

    /// `title` and `summary` are edited straight; every other column is
    /// reached through a `Field`, which carries the name the user gave it.
    private func columnLabel(_ column: String) -> String {
        if let field = fields.first(where: { $0.builtinColumn == column }) { return field.name }
        return column == "summary" ? "Summary" : "Title"
    }

    func setDocumentDate(_ ref: DocumentRef, _ date: Date?) {
        guard let lib = library(ref.library) else { return }
        Task {
            try? await lib.store.setDocumentDate(ref.doc, date)
            try? await lib.store.logEdit(
                docID: ref.doc,
                detail: Self.editDetail("Date", date.map(DayDate.display)))
            reloadDetail()
            reloadDocuments()
        }
    }
}
