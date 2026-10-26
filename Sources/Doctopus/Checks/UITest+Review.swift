import SwiftUI
import AppKit

/// Filing from the review panel and the folder picker.
extension UITest {
    static func versionChoiceScrollsIntoView(_ model: AppModel, snapshots: String?) async {
        guard let row = model.documents.first(where: { $0.ext.lowercased() == "pdf" }),
              var detail = await model.loadDetail(row.doc) else { return }
        detail.row.originalSize = row.size + 100
        detail.originalFileURL = row.url
        detail.row.summary = Array(repeating: "A long document can have a long summary.", count: 80)
            .joined(separator: "\n")
        var version = KeptVersion.optimized
        let binding = Binding(get: { version }, set: { version = $0 })
        let (window, host) = host(GeneratedInfoEditor(detail: detail, version: binding).environment(model),
                                  size: NSSize(width: 380, height: 240))
        defer { window.orderOut(nil) }
        func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
        var picker: NSSegmentedControl?
        _ = await settle {
            picker = descendants(host, of: NSSegmentedControl.self).first
            return picker != nil
        }
        guard let picker else { return Check.that("the version choice exists in a short review pane", false) }
        picker.scrollToVisible(picker.bounds)
        try? await Task.sleep(for: .milliseconds(300))
        let visible = !picker.visibleRect.isEmpty
        picker.setSelected(true, forSegment: 0)
        _ = picker.sendAction(picker.action, to: picker.target)
        _ = await settle { version == .original }
        Check.that("the version choice scrolls into view below a long summary and remains selectable",
                   visible && version == .original)
        if let dir = snapshots { snapshot(host, to: dir + "/review-version-scrolled.png") }
    }

    static func folderPickerResolvesPaths(_ model: AppModel) {
        guard let library = model.library else {
            Check.that("a library to resolve chosen folders against", false)
            return
        }
        let root = library.root
        func relative(_ url: URL) -> String? { FolderPicker.relativePath(for: url, in: library) }

        Check.that("the library root itself is the empty path", relative(root) == "",
                   relative(root).map { "\"\($0)\"" } ?? "refused")
        let statements = root.appendingPathComponent("Finances", isDirectory: true)
            .appendingPathComponent("Statements", isDirectory: true)
        Check.that("a folder inside the library comes back relative to the root",
                   relative(statements) == "Finances/Statements", relative(statements) ?? "refused")

        let roundabout = root.appendingPathComponent("Finances", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("Personal", isDirectory: true)
        Check.that("a path that doubles back is resolved before it is made relative",
                   relative(roundabout) == "Personal", relative(roundabout) ?? "refused")

        Check.that("a folder outside the library is refused",
                   relative(root.deletingLastPathComponent()) == nil)
        Check.that("a sibling folder whose name merely starts with the root's is refused",
                   relative(URL(fileURLWithPath: root.path + "-elsewhere", isDirectory: true)) == nil)

        let container = root.appendingPathComponent("library.doctopus", isDirectory: true)
        Check.that("the library's own container is refused", relative(container) == nil)
        Check.that("and so is a folder inside it",
                   relative(container.appendingPathComponent("thumbnails", isDirectory: true)) == nil)

        if root.path.hasPrefix("/private/var/") {
            let throughSymlink = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)),
                                     isDirectory: true)
                .appendingPathComponent("Work", isDirectory: true)
            Check.that("a folder reached through the /var symlink is still owned",
                       relative(throughSymlink) == "Work", relative(throughSymlink) ?? "refused")
        }
    }

    static func reviewPanelFiles(_ model: AppModel, snapshots: String?) async {
        guard let lib = model.library else { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("doctopus-review-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var copies: [URL] = []
        for row in model.documents where ["scan 003.pdf", "IMG_4821.pdf"].contains(row.filename) {
            let copy = staging.appendingPathComponent("review-" + row.filename)
            if copyAsNew(row.url, to: copy) { copies.append(copy) }
        }
        model.selection = .all
        model.importFiles(copies, into: nil)

        model.selection = .needsReview
        var candidate: DocumentRow?
        var detail: DocumentDetail?
        let found = await settle({
            candidate = model.documents.first { $0.filename.hasPrefix("review-") }
            return candidate != nil
        }, timeout: 60)
        if found, let candidate {
            model.selectedIDs = [candidate.id]
            _ = await settle({
                detail = model.detail
                return detail?.row.id == candidate.id && !(detail?.pathSuggestions.isEmpty ?? true)
            }, timeout: 20)
        }
        Check.that("a new document waits in Needs Review with suggested folders",
                   detail?.pathSuggestions.isEmpty == false,
                   candidate.map { "\($0.filename): \(detail?.pathSuggestions.map { ($0.path as NSString).lastPathComponent } ?? [])" } ?? "none waiting")
        guard let candidate, let detail,
              let primary = detail.pathSuggestions.first(where: { $0.path != candidate.directory })
        else {
            Check.that("a suggestion other than where it already is", false)
            return
        }

        let size = NSSize(width: 900, height: 660)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/review.png") }
        Check.that("the approval view draws the review under the list", inkedRows(host) > 100,
                   "\(inkedRows(host)) rows with ink")

        let (narrowWindow, narrowHost) = Self.host(ReviewPanel().environment(model),
                                              size: NSSize(width: 420, height: 500))
        try? await Task.sleep(for: .seconds(1))
        Check.that("a single-document review fits a narrow center pane",
                   narrowHost.fittingSize.width <= 420 && inkedRows(narrowHost) > 30,
                   "minimum width \(narrowHost.fittingSize.width), inked rows \(inkedRows(narrowHost))")
        if let dir = snapshots { snapshot(narrowHost, to: dir + "/review-narrow.png") }
        narrowWindow.orderOut(nil)

        let secondary = lib.root.appendingPathComponent("Work").path
        model.file(candidate, in: URL(fileURLWithPath: primary.path), alsoIn: [secondary],
                   approve: true, advance: true)
        let filed = await poll(timeout: 20, { await model.loadDetail(candidate.id) }) {
            (loaded: DocumentDetail?) -> Bool in
            guard let loaded, loaded.row.directory == primary.path, loaded.row.approved else { return false }
            return loaded.folderAliases.contains { ($0 as NSString).deletingLastPathComponent == secondary }
        }
        let moved = filed?.row.directory == primary.path && filed?.row.approved == true
        Check.that("filing moves it to the chosen folder, aliases it into another and approves it", moved,
                   filed.map { "\($0.row.directory) · aliases \($0.folderAliases) · approved \($0.row.approved)" } ?? "gone")
        Check.that("filing leaves the aliased original findable",
                   filed.map { fm.fileExists(atPath: $0.row.path) } ?? false)

        model.discardGeneratedInfo([filed?.row ?? candidate])
        let discarded = await poll(timeout: 10, { await model.loadDetail(candidate.id) }) {
            (loaded: DocumentDetail?) -> Bool in
            guard let loaded else { return false }
            return loaded.row.title == nil && loaded.row.docType == nil && loaded.pathSuggestions.isEmpty
        }
        let cleared = discarded != nil && discarded?.row.title == nil && discarded?.pathSuggestions.isEmpty == true
        Check.that("discarding generated info clears it and keeps the file", cleared
                   && fm.fileExists(atPath: discarded?.row.path ?? ""))
        model.selection = .all
    }

    static func reviewBatchTreatsEachKindApart(_ model: AppModel, snapshots: String?) async {
        guard let lib = model.library else { return }
        let fm = FileManager.default
        model.selection = .all
        var sample: DocumentRow?
        _ = await settle({
            sample = model.documents.first {
                $0.ext.lowercased() == "pdf" && !$0.filename.hasPrefix("review-")
            }
            return sample != nil
        }, timeout: 10)
        guard let sample else {
            Check.that("a document to stage a batch from", false)
            return
        }
        let staging = fm.temporaryDirectory.appendingPathComponent("doctopus-batch-\(UUID().uuidString)")
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let outside = staging.appendingPathComponent("batch-new.pdf")
        let inside = lib.root.appendingPathComponent("Work/batch-found.pdf")
        try? fm.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard copyAsNew(sample.url, to: outside), copyAsNew(sample.url, to: inside) else {
            Check.that("a batch could be staged", false)
            return
        }
        model.importFiles([outside, inside], into: nil)

        model.selection = .needsReview
        var rows: [DocumentRow] = []
        // Both can be listed before the import is done — a rule that already
        // matches puts one in Needs Review — and only the import's own entry
        // says it arrived from outside, so wait for that rather than the listing.
        _ = await settle({
            rows = model.documents.filter { $0.filename.hasPrefix("batch-") }
            return rows.count == 2 && rows.contains { $0.filename.hasPrefix("batch-new") && $0.fromOutside }
        }, timeout: 60)
        let newRow = rows.first { $0.filename.hasPrefix("batch-new") }
        let foundRow = rows.first { $0.filename.hasPrefix("batch-found") }
        Check.that("a batch in review tells new arrivals from files already in the library",
                   newRow?.fromOutside == true && foundRow?.fromOutside == false,
                   rows.map { "\($0.filename): \($0.fromOutside ? "new" : "in library")" }.joined(separator: ", "))
        guard let newRow, let foundRow else { return }

        model.selectedIDs = [newRow.id, foundRow.id]
        let size = NSSize(width: 900, height: 660)
        let (window, host) = host(DocumentListView().environment(model), size: size)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(host, to: dir + "/review-batch.png") }
        Check.that("the batch review draws under the list", inkedRows(host) > 100,
                   "\(inkedRows(host)) rows with ink")

        let (narrowWindow, narrowHost) = Self.host(ReviewPanel().environment(model),
                                                  size: NSSize(width: 420, height: 500))
        try? await Task.sleep(for: .seconds(1))
        Check.that("a mixed batch review fits a narrow center pane",
                   narrowHost.fittingSize.width <= 420 && inkedRows(narrowHost) > 30,
                   "minimum width \(narrowHost.fittingSize.width), inked rows \(inkedRows(narrowHost))")
        if let dir = snapshots { snapshot(narrowHost, to: dir + "/review-batch-narrow.png") }
        narrowWindow.orderOut(nil)

        let planned = await model.suggestedFolder(for: newRow) ?? newRow.directory
        let foundHash = FileScanner.hash(foundRow.url)
        model.approve([newRow, foundRow], newArrivals: .default(fromOutside: true),
                      alreadyInLibrary: .default(fromOutside: false))
        let after = await poll(timeout: 30, {
            (await model.loadDetail(newRow.id), await model.loadDetail(foundRow.id))
        }) { $0.0?.row.approved == true && $0.1?.row.approved == true }
        Check.that("approving the batch approves both",
                   after.0?.row.approved == true && after.1?.row.approved == true)
        Check.that("…files the new arrival in its best suggestion",
                   after.0?.row.directory == planned, after.0?.row.directory ?? "gone")
        Check.that("…and leaves the file already in the library where it was, byte for byte",
                   after.1?.row.path == foundRow.path && foundHash != nil
                       && after.1.flatMap { FileScanner.hash($0.row.url) } == foundHash,
                   after.1?.row.path ?? "gone")
        model.selection = .all
    }
}
