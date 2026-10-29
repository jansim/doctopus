import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing
import QuickLookUI

/// Selecting, dragging and sorting in the centre pane, in the list and the gallery.
extension UITest {
    static func clickSelectsARow(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/list.png") }

        model.selectedIDs = []
        let selected = await click(window, at: NSPoint(x: 140, y: size.height - 43),
                                   activating: true) {
            !model.selectedIDs.isEmpty
        }
        Check.that("clicking a document's name selects it", selected,
                   model.documents.filter { model.selectedIDs.contains($0.id) }
                       .map(\.filename).joined(separator: ", "))

        model.selectedIDs = []
        let viaThumbnail = await click(window, at: NSPoint(x: 22, y: size.height - 43),
                                       activating: true) {
            !model.selectedIDs.isEmpty
        }
        Check.that("clicking a row's thumbnail selects it too", viaThumbnail)
        yieldFocus()
    }

    static func clickSelectsAGalleryThumbnail(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        model.viewMode = .gallery
        defer { model.viewMode = .list }
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/gallery.png") }

        let cell = CGFloat(model.settings.galleryThumbnailSize)
        let headed = !Timeline.sections(for: model).isEmpty
        Check.that("the gallery sorted by date is headed by month or year", headed,
                   "sorted by \(model.sort.label)")
        let top = headed ? GalleryHeader.height + 20 : 18
        let middle = NSPoint(x: 18 + cell / 2, y: size.height - (top + cell * 0.65))
        for (where_, point) in [("middle", middle),
                                ("corner", NSPoint(x: 22, y: size.height - (top + 6)))] {
            model.selectedIDs = []
            let selected = await click(window, at: point, attempts: 1, settling: 0.6) {
                !model.selectedIDs.isEmpty
            }
            Check.that("clicking the \(where_) of a gallery thumbnail selects it", selected)
        }

        model.selectedIDs = []
        let start = Date()
        post(window, at: middle)
        let landed = await settle({ !model.selectedIDs.isEmpty }, timeout: 2, every: .milliseconds(5))
        let elapsed = Date().timeIntervalSince(start)
        Check.that("a gallery click selects without waiting out the double-click interval",
                   landed && elapsed < NSEvent.doubleClickInterval * 0.6,
                   "\(Int(elapsed * 1000)) ms, interval \(Int(NSEvent.doubleClickInterval * 1000)) ms")

        model.selectedIDs = []
        let handedOver = URLRecorder()
        AppModel.opener = { handedOver.urls.append($0) }
        defer { AppModel.opener = AppModel.defaultOpener }
        post(window, at: middle)
        post(window, at: middle, clickCount: 2)
        let opened = await settle({ !handedOver.urls.isEmpty }, timeout: 3)
        Check.that("double-clicking a gallery thumbnail opens it in its default app",
                   opened, "\(model.selectedIDs.count) selected")
        Check.that("and does not open Quick Look instead", !QuickLookController.shared.isOpen)
        if QuickLookController.shared.isOpen { QLPreviewPanel.shared().orderOut(nil) }
        model.selectedIDs = []
    }

    /// Asks `GallerySelection` rather than the hosted grid because the branch
    /// turns on `NSEvent.modifierFlags`, which reads the keyboard and not the
    /// event — a posted click cannot hold ⇧ down.
    static func galleryModifierClicks(_ model: AppModel) {
        let order = model.documents.map(\.id)
        guard order.count >= 4 else {
            Check.that("enough documents to select a run of", false, "\(order.count) documents")
            return
        }

        let plain = GallerySelection.click(order[1], in: order, modifiers: [],
                                           selection: [order[3]], anchor: order[3])
        Check.that("a plain click selects only what was clicked",
                   plain == .init(selection: [order[1]], anchor: order[1]))

        let forwards = GallerySelection.click(order[3], in: order, modifiers: .shift,
                                              selection: plain.selection, anchor: plain.anchor)
        Check.that("⇧ extends the selection from the anchor to the click",
                   forwards.selection == Set(order[1...3]), "\(forwards.selection.count) selected")
        Check.that("and a ⇧ click leaves the anchor where it was", forwards.anchor == order[1])

        let backwards = GallerySelection.click(order[0], in: order, modifiers: .shift,
                                               selection: forwards.selection, anchor: forwards.anchor)
        Check.that("a following ⇧ click extends from that same anchor",
                   backwards == .init(selection: Set(order[0...1]), anchor: order[1]),
                   "\(backwards.selection.count) selected")

        let added = GallerySelection.click(order[3], in: order, modifiers: [.shift, .command],
                                           selection: [order[0]], anchor: order[2])
        Check.that("⌘⇧ adds the run to what was already selected",
                   added.selection == Set([order[0], order[2], order[3]]),
                   "\(added.selection.count) selected")

        let picked = GallerySelection.click(order[2], in: order, modifiers: .command,
                                            selection: [order[0]], anchor: order[0])
        Check.that("⌘ adds a cell and moves the anchor to it",
                   picked == .init(selection: [order[0], order[2]], anchor: order[2]))
        let dropped = GallerySelection.click(order[2], in: order, modifiers: .command,
                                             selection: picked.selection, anchor: picked.anchor)
        Check.that("and ⌘ on a selected cell takes it back out",
                   dropped.selection == [order[0]])

        let unanchored = GallerySelection.click(order[2], in: order, modifiers: .shift,
                                                selection: [], anchor: nil)
        Check.that("⇧ before anything has been clicked selects the one cell",
                   unanchored == .init(selection: [order[2]], anchor: order[2]))
        let stale = GallerySelection.click(order[2], in: order, modifiers: .shift, selection: [],
                                           anchor: -1)
        Check.that("⇧ with an anchor no longer in the pane selects the one cell",
                   stale == .init(selection: [order[2]], anchor: order[2]))
    }

    /// Asks `SelectAllDocuments` rather than posting a keystroke: a local
    /// monitor only sees events the run loop takes off the queue itself.
    static func commandASelectsEverything(_ model: AppModel) {
        Check.that("⌘A is taken for selecting documents",
                   SelectAllDocuments.applies(characters: "a", modifiers: .command, editingText: false))
        Check.that("but left to a text field being edited",
                   !SelectAllDocuments.applies(characters: "a", modifiers: .command, editingText: true))
        Check.that("and ⌘⇧A, ⌥A and a plain A are left alone",
                   !SelectAllDocuments.applies(characters: "a", modifiers: [.command, .shift], editingText: false)
                       && !SelectAllDocuments.applies(characters: "a", modifiers: .option, editingText: false)
                       && !SelectAllDocuments.applies(characters: "a", modifiers: [], editingText: false))

        model.selectedIDs = model.documents.first.map { [$0.id] } ?? []
        model.selectAll()
        Check.that("selecting all selects every document in the pane",
                   model.selectedIDs == Set(model.documents.map(\.id)),
                   "\(model.selectedIDs.count) of \(model.documents.count)")
        model.selectedIDs = []
    }

    static func dragCountsTheSelection(_ model: AppModel) {
        let rows = model.documents
        guard rows.count >= 3 else {
            Check.that("enough documents to drag a selection of", false, "\(rows.count) documents")
            return
        }
        let saved = model.selectedIDs
        defer { model.selectedIDs = saved }

        model.selectedIDs = [rows[0].id, rows[1].id]
        let promised = model.dragCount(from: rows[0])
        let dropped = model.rows(forDropped: [DocumentDragItem(rows[0])]).count
        Check.that("dragging a selected document counts the whole selection",
                   promised == 2 && dropped == promised, "badge \(promised), drop \(dropped)")
        let pasteboard = NSPasteboard(name: .init("doctopus-export-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let payloads = DocumentDragSource.pasteboardItems(for: model.selectedRows)
        pasteboard.writeObjects(payloads)
        let exported = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let internalItems = payloads.compactMap {
            $0.data(forType: .init(UTType.doctopusDocument.identifier))
        }.compactMap { try? JSONDecoder().decode(DocumentDragItem.self, from: $0) }
        Check.that("a document selection exports every file URL to other applications",
                   Set(exported.map(\.path)) == Set(model.selectedRows.map(\.path)) && exported.count == 2)
        Check.that("each exported file also carries its own internal document identity",
                   Set(internalItems.map(\.id)) == model.selectedIDs)
        Check.that("dragging an unselected document exports only that file",
                   DocumentDragSource.pasteboardItems(for: [rows[2]]).count == 1)
        // Sampled just inside the top of the badge, above its digits.
        let badged = DocumentDragSource.dragImage(for: rows[0], count: promised)
        let badge = badged.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map { NSBitmapImageRep(cgImage: $0) }
            .flatMap { $0.colorAt(x: $0.pixelsWide * 37 / 48, y: $0.pixelsHigh * 2 / 64) }?
            .usingColorSpace(.sRGB)
        Check.that("the drag image of a selection carries its count badge",
                   badge.map { $0.redComponent > 0.6 && $0.greenComponent < 0.4 } == true,
                   badge.map { "\($0)" } ?? "no image")

        let outside = model.dragCount(from: rows[2])
        Check.that("dragging a document outside the selection counts just that one",
                   outside == 1 && model.rows(forDropped: [DocumentDragItem(rows[2])]).count == 1,
                   "badge \(outside)")

        // What another window's library would send: the same row number, but
        // not a file this library holds.
        var foreign = DocumentDragItem(rows[0])
        foreign.path = "/elsewhere/" + rows[0].filename
        Check.that("a document dragged in from another library's window is not taken for one here",
                   model.rows(forDropped: [foreign]).isEmpty)
    }

    static func headerClickSorts(_ model: AppModel, snapshots: String?) async {
        let size = NSSize(width: 760, height: 420)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))

        let header = NSPoint(x: size.width - 40, y: size.height - 14)
        let sorted = await click(window, at: header, activating: true) { model.sort == .size }
        Check.that("clicking a column header sorts by it", sorted, "sort is \(model.sort.label)")

        let wasAscending = model.sortAscending
        let flipped = await click(window, at: header, activating: true) {
            model.sortAscending != wasAscending
        }
        Check.that("clicking it again reverses the direction", flipped)
        if let dir = snapshots {
            try? await Task.sleep(for: .seconds(1))
            snapshot(host, to: dir + "/list-sorted.png")
        }
        yieldFocus()
    }

    static func rowThumbnailIsAPage(_ model: AppModel) async {
        guard let row = model.documents.first(where: { $0.ext == "pdf" }) else {
            Check.that("row thumbnail renders the page", false, "no PDF in the library")
            return
        }
        let rendered = await ThumbnailCache.shared.thumbnail(for: row.url, size: .row, mtime: row.mtime)
        let request = QLThumbnailGenerator.Request(
            fileAt: row.url, size: ThumbnailCache.SizeClass.row.points, scale: 2,
            representationTypes: .icon)
        let icon = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        Check.that("row thumbnail renders the page rather than the file icon",
                   rendered != nil && rendered?.tiffRepresentation != icon?.nsImage.tiffRepresentation)
    }
}

private final class URLRecorder {
    var urls: [URL] = []
}
