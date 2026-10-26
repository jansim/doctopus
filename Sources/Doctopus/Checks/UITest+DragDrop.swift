import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drops onto the window, the Dock icon and folders, and Undo of what a drop did.
extension UITest {
    static func droppingAFolderImportsIt(_ model: AppModel) async {
        let fm = FileManager.default
        model.selection = .all
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(1))

        let folder = fm.temporaryDirectory.appendingPathComponent("doctopus-drop-\(UUID().uuidString)")
        let nested = folder.appendingPathComponent("Receipts/2025", isDirectory: true)
        try? fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let tag = String(UUID().uuidString.prefix(6))
        for (i, row) in model.documents.prefix(2).enumerated() {
            copyAsNew(row.url, to: (i == 0 ? folder : nested)
                .appendingPathComponent("dropped-\(tag)-\(i).pdf"))
        }

        let pasteboard = NSPasteboard(name: .init("doctopus-uitest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        let drag = SyntheticDrag(pasteboard: pasteboard, window: window,
                                 at: NSPoint(x: size.width / 2, y: size.height / 2))
        // SwiftUI registers a subview of the hosting view for drops, not the
        // hosting view itself.
        guard let target = dropTarget(in: host) else {
            Check.that("dropping a folder imports the documents inside it", false, "no drop target"); return
        }
        let accepted = target.draggingEntered(drag) != [] && target.draggingUpdated(drag) != []
            && target.prepareForDragOperation(drag) && target.performDragOperation(drag)
        target.concludeDragOperation(drag)

        let arrived = await settle({ model.documents.filter { $0.filename.contains(tag) }.count == 2 },
                                   timeout: 30)
        Check.that("dropping a folder imports the documents inside it", accepted && arrived,
                   "accepted \(accepted), \(model.documents.filter { $0.filename.contains(tag) }.count) of 2 arrived")
        for row in model.documents where row.filename.contains(tag) { try? fm.removeItem(at: row.url) }
    }

    /// A document dropped on the Dock icon reaches the app rather than a
    /// window, and the one library open takes it even with an empty window in
    /// front. At launch it waits for the libraries being reopened.
    static func handedOverDocumentsImport(_ model: AppModel) async {
        let fm = FileManager.default
        let workspace = Workspace.shared
        workspace.register(model)
        let empty = AppModel()
        workspace.register(empty)
        workspace.current = empty
        defer {
            empty.windowClosed()
            workspace.current = model
        }
        Check.that("a document handed to the app goes to the one library open, even with an empty window in front",
                   workspace.importTarget === model)

        model.selection = .all
        // The checks before this one take away files they brought in, and
        // the list can still show them until the watcher has caught up.
        guard let source = model.documents.first(where: {
            $0.filename.lowercased().hasSuffix(".pdf") && !$0.isAliasHere && !$0.missing
                && fm.fileExists(atPath: $0.path)
        }) else {
            return Check.that("a document handed over at launch lands once the libraries are open", false,
                              "no PDF to copy")
        }
        let folder = fm.temporaryDirectory.appendingPathComponent("doctopus-handed-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let tag = String(UUID().uuidString.prefix(6))
        let file = folder.appendingPathComponent("handed-\(tag).pdf")
        guard copyAsNew(source.url, to: file) else {
            return Check.that("a document handed over at launch lands once the libraries are open", false,
                              "could not copy \(source.filename)")
        }
        func arrived() -> Bool { model.documents.contains { $0.filename.contains(tag) } }

        // Nothing in the UI checks reopens last time's libraries, so until
        // `restore` runs this is the app still launching.
        workspace.importHandedOver([file])
        try? await Task.sleep(for: .seconds(1))
        let waited = !arrived()
        Preferences.libraryBookmarks = []
        workspace.restore(into: empty)
        let landed = await settle(arrived, timeout: 30)
        Check.that("a document handed over at launch lands once the libraries are open",
                   waited && landed,
                   "waited \(waited), landed \(landed) · "
                       + (model.errorMessage ?? empty.errorMessage ?? model.notice?.text ?? "nothing said"))
        for row in model.documents where row.filename.contains(tag) { try? fm.removeItem(at: row.url) }
    }

    static func draggingOntoAFolderFilesOrMoves(_ model: AppModel) async {
        let fm = FileManager.default
        defer { FolderDropIntent.heldModifiers = { NSEvent.modifierFlags } }
        func fail(_ why: String) {
            Check.that("⌥ held over a folder files the document there as well", false, why)
        }
        guard let library = model.library else { return fail("no library open") }

        let name = "Dropped-\(UUID().uuidString.prefix(6))"
        let destination = library.root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let node = FolderNode(path: destination.path, name: name,
                              children: [], count: 0, deepCount: 0)
        let (window, host) = host(VStack { FolderRow(node: node, depth: 0) }.environment(model),
                                  size: NSSize(width: 240, height: 90))
        defer { window.orderOut(nil) }
        // SwiftUI registers a drop target under the types the wanted one
        // conforms to — `public.data` and `public.item` for ours — rather than
        // under its own identifier, and not before the view has been laid out.
        func takesDocuments(_ view: NSView) -> Bool {
            view.registeredDraggedTypes.contains {
                UTType($0.rawValue).map(UTType.doctopusDocument.conforms(to:)) == true
            }
        }
        var targets: [NSView] = []
        _ = await settle({
            targets = dropTargets(in: host)
            return targets.contains(where: takesDocuments)
        }, timeout: 10)
        guard let target = targets.first(where: takesDocuments) else {
            return fail("nothing under the hosted row takes a Doctopus document · registered "
                + "\(Set(targets.flatMap { $0.registeredDraggedTypes.map(\.rawValue) }).sorted())")
        }

        model.selectedIDs = []
        let candidates = model.documents.filter {
            !$0.isAliasHere && !$0.missing
                && $0.directory != destination.path && fm.fileExists(atPath: $0.path)
        }
        guard candidates.count >= 2 else { return fail("\(candidates.count) usable documents") }

        FolderDropIntent.heldModifiers = { NSEvent.ModifierFlags.option }
        let filed = candidates[0]
        let filedTaken = drop(DocumentDragItem(filed), on: target, in: window)
        let aliased = await settle({
            ((try? fm.contentsOfDirectory(atPath: destination.path)) ?? []).count > 0
        }, timeout: 20)
        Check.that("⌥ held over a folder files the document there as well",
                   filedTaken && aliased && fm.fileExists(atPath: filed.path),
                   "taken \(filedTaken), filed \(aliased), master still in place \(fm.fileExists(atPath: filed.path))")

        FolderDropIntent.heldModifiers = { NSEvent.ModifierFlags() }
        let moving = candidates[1]
        let cameFrom = URL(fileURLWithPath: moving.directory)
        let movedTaken = drop(DocumentDragItem(moving), on: target, in: window)
        let landed = destination.appendingPathComponent(moving.filename)
        let arrived = await settle({
            fm.fileExists(atPath: landed.path) && !fm.fileExists(atPath: moving.path)
        }, timeout: 20)
        Check.that("a plain drag onto a folder moves the file there",
                   movedTaken && arrived,
                   "taken \(movedTaken), at \(name)/\(moving.filename) \(fm.fileExists(atPath: landed.path)), "
                       + "gone from where it was \(!fm.fileExists(atPath: moving.path))")

        Check.that("a completed folder drop clears the sidebar highlight",
                   model.folderDropTarget == nil, model.folderDropTarget ?? "clear")

        try? fm.createDirectory(at: cameFrom, withIntermediateDirectories: true)
        try? fm.moveItem(at: landed, to: cameFrom.appendingPathComponent(moving.filename))
        try? fm.removeItem(at: destination)
    }

    static func undoTakesBackAMove(_ model: AppModel) async {
        let undo = UndoManager()
        model.undoManager = undo
        model.selection = .all
        guard let row = model.documents.first(where: { !$0.isAliasHere }),
              let library = model.library else { return }
        let folder = library.root.appendingPathComponent("Undo Check", isDirectory: true)
        model.move([row], to: folder)
        let moved = await settle { undo.canUndo }
        Check.that("a move is offered to Edit › Undo", moved && undo.undoActionName == "Move",
                   undo.undoActionName)
        guard moved else { return }
        undo.undo()
        let back = await settle { FileManager.default.fileExists(atPath: row.path) }
        Check.that("…and undoing it puts the file back where it was", back)
    }

    private static func drop(_ item: DocumentDragItem, on target: NSView, in window: NSWindow) -> Bool {
        guard let payload = try? JSONEncoder().encode(item) else { return false }
        let pasteboard = NSPasteboard(name: .init("doctopus-uitest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        _ = entry.setData(payload, forType: .init(UTType.doctopusDocument.identifier))
        _ = pasteboard.writeObjects([entry])

        let middle = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let drag = SyntheticDrag(pasteboard: pasteboard, window: window, at: middle)
        drag.draggingSourceOperationMask = [.copy, .move]
        let taken = target.draggingEntered(drag) != [] && target.draggingUpdated(drag) != []
            && target.prepareForDragOperation(drag) && target.performDragOperation(drag)
        target.concludeDragOperation(drag)
        return taken
    }

    private static func dropTarget(in view: NSView) -> NSView? {
        if !view.registeredDraggedTypes.isEmpty { return view }
        return view.subviews.lazy.compactMap { dropTarget(in: $0) }.first
    }

    private static func dropTargets(in view: NSView) -> [NSView] {
        (view.registeredDraggedTypes.isEmpty ? [] : [view])
            + view.subviews.flatMap { dropTargets(in: $0) }
    }
}

@MainActor
private final class SyntheticDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    private weak var window: NSWindow?

    init(pasteboard: NSPasteboard, window: NSWindow, at point: NSPoint) {
        draggingPasteboard = pasteboard
        draggingLocation = point
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
