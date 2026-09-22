import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension UTType {
    /// Private drag type for moving documents around inside the app.
    static let doctopusDocument = UTType(exportedAs: "io.doctopus.document")
    /// A `library.doctopus`: a package, so Finder and the open panel treat it
    /// as one item rather than a folder to browse into.
    static let doctopusLibrary = UTType(exportedAs: "io.doctopus.library")
}

/// What travels on the pasteboard when documents are dragged. Deliberately thin
/// — the receiver looks everything else up by id.
struct DocumentDragItem: Codable, Transferable, Hashable, Sendable {
    var id: DocumentRef
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

    /// Reads dragged documents back off a drop's item providers.
    ///
    /// Waited out rather than handed a callback: the providers read lazily from
    /// the drag pasteboard, which the system takes away as soon as the drop
    /// returns, and a drop that knows whether it took anything is a drop that
    /// can snap back when it did not.
    static func read(from providers: [NSItemProvider]) -> [DocumentDragItem] {
        guard !providers.isEmpty else { return [] }
        let loads = Loads(count: providers.count)
        for provider in providers {
            _ = provider.loadDataRepresentation(for: .doctopusDocument) { data, _ in
                loads.finish(with: data)
            }
        }
        // Keep the run loop turning in case a loader calls back on main.
        let deadline = Date(timeIntervalSinceNow: 5)
        while !loads.isComplete, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return loads.items
    }

    /// Provider loads, which finish on arbitrary queues.
    private final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var outstanding: Int
        private var loaded: [DocumentDragItem] = []

        init(count: Int) { outstanding = count }

        func finish(with data: Data?) {
            let item = data.flatMap { try? JSONDecoder().decode(DocumentDragItem.self, from: $0) }
            lock.withLock {
                if let item { loaded.append(item) }
                outstanding -= 1
            }
        }

        var isComplete: Bool { lock.withLock { outstanding == 0 } }
        var items: [DocumentDragItem] { lock.withLock { loaded } }
    }
}

/// A dragged document, with Finder's red count once it carries more than one.
struct DocumentDragPreview: View {
    let row: DocumentRow
    let count: Int
    var width: CGFloat = 64

    var body: some View {
        AliasBadgedThumbnail(row: row, width: width, height: width * 1.3,
                             cornerRadius: 4, showsShadow: true)
            .padding(10)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(Color.red))
                }
            }
    }
}

/// What a drop onto a sidebar row should do.
enum DropAction {
    case alias(folder: String)
    case move(folder: String)
    case tag(Tag)
    case field(Field, value: String)
}

/// What a drag onto a folder will do when it is let go, which is the keys'
/// decision: on its own it files the document in a second place and leaves the
/// master where it is, and with Command held it moves the master itself — the
/// same thing ⌘ does to a Finder drag between two volumes.
enum FolderDropIntent: Equatable {
    case alias
    case move

    static func reading(_ modifiers: NSEvent.ModifierFlags) -> FolderDropIntent {
        modifiers.contains(.command) ? .move : .alias
    }

    /// Which keys are down. A stored function rather than a call straight to
    /// `NSEvent`, so the headless checks — which have no keyboard to hold —
    /// can answer for it.
    nonisolated(unsafe) static var heldModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    /// What the keys say at this instant. Only ever asked while a drag is still
    /// in the air: read once the drop has landed and its payload has been
    /// decoded, the keys are back up again, because they come up with the
    /// mouse button.
    static var held: FolderDropIntent { reading(heldModifiers()) }

    func action(on folder: String) -> DropAction {
        switch self {
        case .alias: return .alias(folder: folder)
        case .move: return .move(folder: folder)
        }
    }

    /// What the row shows while a drag is over it.
    var label: String {
        switch self {
        case .alias: return "File Here"
        case .move: return "Move Here"
        }
    }
}

/// What the drag currently over a folder row is doing. A class, because SwiftUI
/// builds the delegate afresh every time the row's body runs, and what was read
/// while the drag was in the air has to survive into the drop.
final class FolderDropState {
    var intent: FolderDropIntent = .alias
}

/// A folder row's drop target.
///
/// `dropDestination` would carry the documents on its own, but it only hands
/// them over once the drop has landed and its payload has been decoded — far
/// too late to still know which keys were held. A `DropDelegate` is asked on
/// every update of the drag instead, which is early enough to read them, and
/// early enough to tell the row what it is about to do while the drag is still
/// in the air.
struct FolderDropDelegate: DropDelegate {
    let folder: String
    let model: AppModel
    /// What the drop acts on. Kept apart from `hovering` because a binding
    /// handed out on an earlier pass through the row's body can read back what
    /// that pass saw — fine for a highlight, not for a decision.
    let state: FolderDropState
    @Binding var hovering: FolderDropIntent?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.doctopusDocument])
    }

    func dropEntered(info: DropInfo) { note(.held) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        note(.held)
        // Always copy, whichever way the drop will go: an operation the drag's
        // source did not offer is refused, and a refused drop is a drag that
        // cannot be let go at all. Which of the two it is, the row says.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { hovering = nil }

    func performDrop(info: DropInfo) -> Bool {
        hovering = nil
        let items = DocumentDragItem.read(from: info.itemProviders(for: [.doctopusDocument]))
        guard !items.isEmpty else { return false }
        let action = state.intent.action(on: folder)
        // Drop callbacks arrive on the main thread, which is where the model is.
        return MainActor.assumeIsolated { model.handleDrop(items, action: action) }
    }

    private func note(_ intent: FolderDropIntent) {
        state.intent = intent
        if hovering != intent { hovering = intent }
    }
}

extension AppModel {
    /// Resolves a dropped payload to full rows. Dragging one row out of a
    /// multiple selection carries the whole selection, which is what every
    /// other Mac app does.
    /// Must agree with `rows(forDropped:)`.
    func dragCount(from row: DocumentRow) -> Int {
        selectedIDs.contains(row.id) ? selectedIDs.count : 1
    }

    func rows(forDropped items: [DocumentDragItem]) -> [DocumentRow] {
        let dropped = Set(items.map(\.id))
        if !dropped.isDisjoint(with: selectedIDs) {
            let union = dropped.union(selectedIDs)
            return documents.filter { union.contains($0.id) }
        }
        return documents.filter { dropped.contains($0.id) }
    }

    /// Files and folders dragged in from outside the app. A library opens; a
    /// folder is imported as the documents inside it, however deep; a file is
    /// imported if Doctopus can read it. Returns false when there is nothing
    /// to take, so the drop snaps back.
    func handleDroppedFiles(_ urls: [URL]) -> Bool {
        let libraries = urls.filter { $0.lastPathComponent.hasSuffix(".doctopus") }
        let imports = urls.filter { url in
            guard !url.lastPathComponent.hasSuffix(".doctopus") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                || FileScanner.supportedExtensions.contains(url.pathExtension.lowercased())
        }
        guard !libraries.isEmpty || !imports.isEmpty else { return false }
        for library in libraries { openLibrary(at: library) }
        // No explicit destination: a drop lands in the selected folder and
        // stays there, or in the Inbox and gets routed from it.
        if !imports.isEmpty { importFiles(imports, into: nil) }
        return true
    }

    /// Handles a drop on a sidebar row. Returns false when nothing was done, so
    /// the drop animation snaps back.
    @discardableResult
    func handleDrop(_ items: [DocumentDragItem], action: DropAction) -> Bool {
        let dropped = rows(forDropped: items)
        guard !dropped.isEmpty else { return false }

        switch action {
        case .alias(let folder):
            createAliases(dropped, in: URL(fileURLWithPath: folder))
        case .move(let folder):
            move(dropped, to: URL(fileURLWithPath: folder))
        case .tag(let tag):
            // A tag belongs to one library, so rows from any other are simply
            // not part of this drop.
            let mine = dropped.filter { $0.library == tag.library }
            guard !mine.isEmpty else { return false }
            addTag(tag.name, to: mine)
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
