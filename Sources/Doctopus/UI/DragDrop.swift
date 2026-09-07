import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension UTType {
    /// Private drag type for moving documents around inside the app.
    static let doctopusDocument = UTType(exportedAs: "io.doctopus.document")
}

/// What travels on the pasteboard when documents are dragged. Deliberately thin
/// — the receiver looks everything else up by id.
struct DocumentDragItem: Codable, Transferable, Hashable, Sendable {
    var id: Int64
    var path: String

    init(_ row: DocumentRow) {
        id = row.id
        path = row.path
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .doctopusDocument)
        // Also offer the file itself, so a drag out to Finder or Mail works.
        ProxyRepresentation(exporting: \.path)
    }
}

/// What a drop onto a sidebar row should do.
enum DropAction {
    case alias(folder: String)
    case move(folder: String)
    case tag(Tag)
    case field(Field, value: String)
}

extension AppModel {
    /// Resolves a dropped payload to full rows. Dragging one row out of a
    /// multiple selection carries the whole selection, which is what every
    /// other Mac app does.
    func rows(forDropped items: [DocumentDragItem]) -> [DocumentRow] {
        let dropped = Set(items.map(\.id))
        if !dropped.isDisjoint(with: selectedIDs) {
            let union = dropped.union(selectedIDs)
            return documents.filter { union.contains($0.id) }
        }
        return documents.filter { dropped.contains($0.id) }
    }

    /// Handles a drop on a sidebar row. Returns false when nothing was done, so
    /// the drop animation snaps back.
    @discardableResult
    func handleDrop(_ items: [DocumentDragItem], action: DropAction) -> Bool {
        let dropped = rows(forDropped: items)
        guard !dropped.isEmpty else { return false }

        switch action {
        case .alias(let folder):
            // Holding Command turns the default "file it in two places" drop
            // into a real move of the master file.
            if NSEvent.modifierFlags.contains(.command) {
                move(dropped, to: URL(fileURLWithPath: folder))
            } else {
                createAliases(dropped, in: URL(fileURLWithPath: folder))
            }
        case .move(let folder):
            move(dropped, to: URL(fileURLWithPath: folder))
        case .tag(let tag):
            addTag(tag.name, to: dropped)
        case .field(let field, let value):
            guard confirmFieldChange(field: field, value: value, count: dropped.count) else { return false }
            setFieldValue(dropped, field: field, value: value)
        }
        return true
    }

    /// Changing a whole selection's document type or language is destructive in
    /// a way tagging is not — it overwrites what was extracted — so it asks.
    private func confirmFieldChange(field: Field, value: String, count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Set \(field.name) to “\(value)”?"
        alert.informativeText = count == 1
            ? "This replaces the \(field.name.lowercased()) currently on this document."
            : "This replaces the \(field.name.lowercased()) on all \(count) selected documents."
        alert.addButton(withTitle: "Set \(field.name)")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
