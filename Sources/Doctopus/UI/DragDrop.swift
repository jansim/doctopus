import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension UTType {
    static let doctopusDocument = UTType(exportedAs: "io.doctopus.document")
    static let doctopusLibrary = UTType(exportedAs: "io.doctopus.library")
}

struct DocumentDragItem: Codable, Transferable, Hashable, Sendable {
    var id: DocumentRef
    var path: String

    init(_ row: DocumentRow) {
        id = row.id
        path = row.path
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .doctopusDocument)
        ProxyRepresentation(exporting: \.path)
    }

    /// Handed a callback rather than waited out: a drag out of this app's own
    /// list is exported on the main thread, so a drop that blocks the main
    /// thread for its payload waits for nothing and freezes the app doing it.
    static func load(from providers: [NSItemProvider],
                     then deliver: @escaping @MainActor @Sendable ([DocumentDragItem]) -> Void) {
        let loads = Loads(count: providers.count)
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadDataRepresentation(for: .doctopusDocument) { data, _ in
                loads.finish(with: data)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { deliver(loads.items) }
        }
    }

    private final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [DocumentDragItem] = []

        init(count: Int) { loaded.reserveCapacity(count) }

        func finish(with data: Data?) {
            let item = data.flatMap { try? JSONDecoder().decode(DocumentDragItem.self, from: $0) }
            if let item { lock.withLock { loaded.append(item) } }
        }

        var items: [DocumentDragItem] { lock.withLock { loaded } }
    }
}

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

enum DropAction {
    case alias(folder: String)
    case move(folder: String)
    case tag(Tag)
    case field(Field, value: String)
}

enum FolderDropIntent: Equatable {
    case alias
    case move

    static func reading(_ modifiers: NSEvent.ModifierFlags) -> FolderDropIntent {
        modifiers.contains(.command) ? .move : .alias
    }

    nonisolated(unsafe) static var heldModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    static var held: FolderDropIntent { reading(heldModifiers()) }

    func action(on folder: String) -> DropAction {
        switch self {
        case .alias: return .alias(folder: folder)
        case .move: return .move(folder: folder)
        }
    }

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

/// A `DropDelegate` rather than `dropDestination`, which hands the items over
/// only after the drop lands — too late to read which keys were held.
struct FolderDropDelegate: DropDelegate {
    let folder: String
    let model: AppModel
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
        let providers = info.itemProviders(for: [.doctopusDocument])
        guard !providers.isEmpty else { return false }
        // Decided now, while the keys still say what was held.
        let action = state.intent.action(on: folder)
        DocumentDragItem.load(from: providers) { items in
            guard !items.isEmpty else { return }
            model.handleDrop(items, action: action)
        }
        return true
    }

    private func note(_ intent: FolderDropIntent) {
        state.intent = intent
        if hovering != intent { hovering = intent }
    }
}

extension AppModel {
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

    func handleDroppedFiles(_ urls: [URL]) -> Bool {
        let libraries = urls.filter { $0.lastPathComponent.hasSuffix(".doctopus") }
        let imports = urls.filter { url in
            guard !url.lastPathComponent.hasSuffix(".doctopus") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                || FileScanner.supportedExtensions.contains(url.pathExtension.lowercased())
        }
        guard !libraries.isEmpty || !imports.isEmpty else { return false }
        for library in libraries { openLibrary(at: library) }
        if !imports.isEmpty { importFiles(imports, into: nil) }
        return true
    }

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
            let mine = dropped.filter { $0.library == tag.library }
            guard !mine.isEmpty else { return false }
            addTag(tag.name, to: mine)
        case .field(let field, let value):
            guard confirmFieldChange(field: field, value: value, count: dropped.count) else { return false }
            setFieldValue(dropped, field: field, value: value)
        }
        return true
    }

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
