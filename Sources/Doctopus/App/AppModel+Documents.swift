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
            do {
                // Its own change, so reverting one document's tagging cannot delete
                // the tag from under the others.
                let id = try await lib.store.change(doc: nil, "Created tag “\(name)”") { store in
                    try store.tagID(named: name)
                }
                for row in rows where id > 0 {
                    try await lib.store.change(doc: row.doc, "Tagged “\(name)”") { store in
                        try store.assign(tag: id, to: row.doc)
                    }
                }
            } catch { report(error, "tag \(rows.count == 1 ? "it" : "them") “\(name)”") }
            refreshAll()
            reloadDetail()
        }
    }

    func removeTag(_ tag: Tag, from rows: [DocumentRow]) {
        guard let lib = library else { return }
        Task {
            let tagID = tag.tagID
            for row in rows {
                do {
                    try await lib.store.change(doc: row.doc, "Untagged “\(tag.name)”") { store in
                        try store.unassign(tag: tagID, from: row.doc)
                    }
                } catch { report(error, "take “\(tag.name)” off “\(row.displayTitle)”") }
            }
            refreshAll()
            reloadDetail()
        }
    }

    func acceptTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library else { return }
        Task {
            let name = suggestion.name
            do {
                try await lib.store.change(doc: row.doc, "Tagged “\(name)”") { store in
                    try store.acceptTagSuggestion(name, for: row.doc)
                }
            } catch { report(error, "tag it “\(name)”") }
            refreshAll()
            reloadDetail()
        }
    }

    func discardTagSuggestion(_ suggestion: TagSuggestion, for row: DocumentRow) {
        guard let lib = library else { return }
        Task {
            let name = suggestion.name
            do {
                try await lib.store.change(doc: row.doc, "Dismissed the suggested tag “\(name)”") { store in
                    try store.discardTagSuggestion(name, for: row.doc)
                }
            } catch { report(error, "discard the suggestion “\(name)”") }
            reloadDetail()
        }
    }

    func setTagParent(_ tag: Tag, to parent: Tag?) {
        guard let lib = library else { return }
        Task {
            do {
                let (tagID, parentID) = (tag.tagID, parent?.tagID)
                let detail = parent.map { "Moved tag “\(tag.name)” into “\($0.name)”" }
                    ?? "Moved tag “\(tag.name)” to the top level"
                let moved = try await lib.store.change(doc: nil, detail) { store in
                    try store.setTagParent(tagID, to: parentID)
                }
                if !moved, parent != nil {
                    errorMessage = "“\(tag.name)” cannot go under “\(parent?.name ?? "")”: "
                        + "a tag cannot sit inside itself, and tags nest at most \(Tag.maxDepth) deep."
                }
            } catch { report(error, "move “\(tag.name)”") }
            refreshAll()
        }
    }

    func createTag(named name: String) {
        guard let lib = library else { return }
        Task {
            do {
                try await lib.store.change(doc: nil, "Created tag “\(name)”") { store in
                    _ = try store.tagID(named: name)
                }
            } catch { report(error, "create “\(name)”") }
            refreshAll()
        }
    }

    func renameTag(_ tag: Tag, to name: String) {
        guard let lib = library else { return }
        Task {
            let survivor: Int64
            let tagID = tag.tagID
            do {
                survivor = try await lib.store.change(doc: nil, "Renamed tag “\(tag.name)” to “\(name)”") { store in
                    try store.renameTag(tagID, to: name)
                }
            } catch { report(error, "rename “\(tag.name)”"); return }
            if selection == .tag(tag.id) {
                selection = .tag(survivor)
            }
            refreshAll()
            reloadDetail()
        }
    }

    func setTagColor(_ tag: Tag, _ color: Int64) {
        guard let lib = library else { return }
        Task {
            let tagID = tag.tagID
            do {
                try await lib.store.change(doc: nil, "Recoloured tag “\(tag.name)”") { store in
                    try store.setTagColor(tagID, color)
                }
            } catch { report(error, "recolour “\(tag.name)”") }
            refreshAll()
            reloadDetail()
        }
    }

    func setTagIcon(_ tag: Tag, _ icon: String?) {
        guard let lib = library else { return }
        Task {
            let tagID = tag.tagID
            do {
                try await lib.store.change(doc: nil, "Changed the icon of tag “\(tag.name)”") { store in
                    try store.setTagIcon(tagID, icon)
                }
            } catch { report(error, "set the icon for “\(tag.name)”") }
            refreshAll()
        }
    }

    func deleteTag(_ tag: Tag) {
        guard let lib = library else { return }
        Task {
            let tagID = tag.tagID
            do {
                try await lib.store.change(doc: nil, "Deleted tag “\(tag.name)”") { store in
                    try store.deleteTag(tagID)
                }
            } catch { report(error, "delete “\(tag.name)”"); refreshAll(); return }
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
                do { try await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url)) }
                catch { report(error, "record the Finder tag on “\(row.displayTitle)”"); continue }
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
                do { try await lib.store.indexFinderTags(docID: row.doc, entries: FinderTags.entries(row.url)) }
                catch { report(error, "record the Finder tag on “\(row.displayTitle)”"); continue }
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
            do {
                try await lib.store.change(doc: nil, "Changed the icon of “\(value)”") { store in
                    try store.setValueIcon(field: field, value: value, icon: icon)
                }
            } catch { report(error, "set the icon for “\(value)”") }
            refreshAll()
        }
    }

    func setNote(_ body: String, for doc: Int64) {
        guard let lib = library else { return }
        Task {
            do {
                try await lib.store.change(doc: doc, "Note edited") { store in
                    let before = try store.setNote(body, for: doc)
                    let after = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if after.isEmpty { store.describe("Note deleted") }
                    else if before.isEmpty { store.describe("Note added") }
                }
            } catch { report(error, "save the note") }
            reloadDetail()
        }
    }

    func setFieldValue(_ rows: [DocumentRow], field: Field, value: String?) {
        guard let lib = library else { return }
        Task {
            let mark = await eventMark()
            for row in rows {
                do {
                    try await lib.store.change(doc: row.doc, Self.editDetail(field.name, value)) { store in
                        try store.setFieldValue(docID: row.doc, field: field, value: value)
                    }
                } catch { report(error, "set \(field.name) on “\(row.displayTitle)”") }
            }
            await lib.indexer.reroute(rows.map(\.doc), applyingActions: false)
            await followNaming(rows.map(\.doc), since: mark, in: lib)
            reloadDetail()
            refreshAll()
        }
    }

    func setFieldValue(_ doc: Int64, field: Field, value: String?) {
        guard let lib = library else { return }
        Task {
            let mark = await eventMark()
            do {
                try await lib.store.change(doc: doc, Self.editDetail(field.name, value)) { store in
                    try store.setFieldValue(docID: doc, field: field, value: value)
                }
                await lib.indexer.reroute([doc], applyingActions: false)
                await followNaming([doc], since: mark, in: lib)
            } catch { report(error, "set \(field.name)") }
            reloadDetail()
            refreshAll()
        }
    }

    func renameFieldValue(_ field: Field, from old: String, to new: String) {
        guard let lib = library else { return }
        Task {
            var n = 0
            do {
                n = try await lib.store.change(doc: nil, "Renamed “\(old)” to “\(new)”") { store in
                    try store.renameFieldValue(field: field, from: old, to: new)
                }
            } catch { report(error, "rename “\(old)”") }
            if case .field(let key, let value) = selection, key == field.key, value == old, n > 0 {
                selection = .field(field.key, new)
            }
            refreshAll()
            if n > 0 { notify("Renamed “\(old)” to “\(new)” on \(n) document\(n == 1 ? "" : "s").") }
        }
    }

    func mergeFieldValues(_ field: Field, _ values: [String], into name: String) {
        guard let lib = library, let target = name.nilIfBlank else { return }
        Task {
            var n = 0
            do {
                n = try await lib.store.change(doc: nil, "Merged \(values.count) values into “\(target)”") { store in
                    try store.mergeFieldValues(field: field, values, into: target)
                }
            } catch { report(error, "merge into “\(target)”") }
            if case .field(let key, let value) = selection, key == field.key, values.contains(value) {
                selection = .field(field.key, target)
            }
            refreshAll()
            reloadDetail()
            notify("Merged \(values.count) into “\(target)” on \(n) document\(n == 1 ? "" : "s").")
        }
    }

    func mergeTags(_ tags: [Tag], into name: String) {
        guard let lib = library, let target = name.nilIfBlank else { return }
        Task {
            let survivor: Int64?
            let ids = tags.map(\.tagID)
            do {
                survivor = try await lib.store.change(doc: nil, "Merged \(tags.count) tags into “\(target)”") { store in
                    try store.mergeTags(ids, into: target)
                }
            } catch { report(error, "merge into “\(target)”"); refreshAll(); return }
            if case .tag(let id) = selection, tags.contains(where: { $0.tagID == id }), let survivor {
                selection = .tag(survivor)
            }
            refreshAll()
            reloadDetail()
            notify("Merged \(tags.count) tags into “\(target)”.")
        }
    }

    func setEntityMatch(_ field: Field, value: String, pattern: String) {
        guard let lib = library else { return }
        Task {
            var saved = false
            do {
                if let column = field.builtinColumn,
                   let id = try await lib.store.existingEntityID(named: value, builtin: column) {
                    let detail = pattern.nilIfBlank == nil ? "“\(value)” no longer matched by its text"
                        : "“\(value)” matched by “\(pattern)”"
                    try await lib.store.change(doc: nil, detail) { store in
                        try store.setEntityMatch(id, pattern: pattern.nilIfBlank)
                    }
                    saved = true
                }
            } catch { report(error, "save what “\(value)” matches") }
            refreshAll()
            if saved, pattern.nilIfBlank != nil {
                notify("Documents mentioning that will be filed as “\(value)”.")
            }
        }
    }

    func deleteFieldValue(_ field: Field, value: String) {
        guard let lib = library else { return }
        Task {
            do {
                try await lib.store.change(doc: nil, "Deleted “\(value)” from \(field.name)") { store in
                    try store.deleteFieldValue(field: field, value: value)
                }
            } catch { report(error, "delete “\(value)”") }
            if selection == .field(field.key, value) { selection = .all }
            refreshAll()
        }
    }

    func updateField(_ field: Field) {
        guard let lib = library else { return }
        listColumns[visibility: "field.\(field.key)"] = .automatic
        Task {
            do {
                try await lib.store.change(doc: nil, "Changed the field “\(field.name)”") { store in
                    try store.updateField(field)
                }
            } catch { report(error, "update “\(field.name)”") }
            refreshAll()
        }
    }

    func addCustomField(named name: String, type: FieldType = .string) {
        guard let lib = library else { return }
        Task {
            do {
                try await lib.store.change(doc: nil, "Added the field “\(name)”") { store in
                    _ = try store.addCustomField(name: name, type: type)
                }
            } catch { report(error, "add “\(name)”") }
            refreshAll()
        }
    }

    func deleteField(_ field: Field) {
        guard let lib = library else { return }
        Task {
            let fieldID = field.fieldID
            do {
                try await lib.store.change(doc: nil, "Deleted the field “\(field.name)”") { store in
                    try store.deleteField(fieldID)
                }
            } catch { report(error, "delete “\(field.name)”") }
            if case .field(let key, _) = selection, key == field.key { selection = .all }
            refreshAll()
        }
    }

    func editMetadata(_ doc: Int64, column: String, value: String?) {
        guard let lib = library else { return }
        let label = columnLabel(column)
        Task {
            let mark = await eventMark()
            do {
                try await lib.store.change(doc: doc, Self.editDetail(label, value)) { store in
                    try store.overwriteMetadataField(doc, column: column, value: value?.nilIfBlank)
                }
                await lib.indexer.reroute([doc], applyingActions: false)
                await followNaming([doc], since: mark, in: lib)
            } catch { report(error, "set \(label)") }
            reloadDetail()
            reloadDocuments()
            refreshRuleMatches()
        }
    }

    private func columnLabel(_ column: String) -> String {
        if let field = fields.first(where: { $0.builtinColumn == column }) { return field.name }
        return column == "summary" ? "Summary" : "Title"
    }

    func setDocumentDate(_ doc: Int64, _ date: Date?) {
        guard let lib = library else { return }
        Task {
            let mark = await eventMark()
            do {
                try await lib.store.change(doc: doc, Self.editDetail("Date", date.map(DayDate.display))) { store in
                    try store.setDocumentDate(doc, date)
                }
                await lib.indexer.reroute([doc], applyingActions: false)
                await followNaming([doc], since: mark, in: lib)
            } catch { report(error, "set the date") }
            reloadDetail()
            reloadDocuments()
            refreshRuleMatches()
        }
    }
}
