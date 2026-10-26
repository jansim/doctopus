import SwiftUI
import AppKit

/// Libraries and their windows: one apart from another, and one whose folder moves.
extension UITest {
    static func creatingFolderKeepsTheCurrentView(_ model: AppModel) async {
        guard let lib = model.library else { return }
        model.selection = .all
        model.searchText = ""
        model.reloadDocuments()
        _ = await settle { !model.documents.isEmpty }
        guard let row = model.documents.first else { return }
        model.selectedIDs = [row.id]
        let folder = lib.root.appendingPathComponent("Created \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        model.createFolder(named: folder.lastPathComponent, in: lib.root)
        _ = await settle { lib.folders.first?.children.contains(where: { $0.path == folder.path }) == true }
        Check.that("creating a folder keeps the current view and selected document",
                   model.selection == .all && model.selectedIDs == [row.id]
                       && FileManager.default.fileExists(atPath: folder.path))
    }

    /// A library whose folder is renamed while open reopens where it went,
    /// and one whose folder is deleted closes, rather than going on handing
    /// out paths that no longer exist.
    static func libraryFollowsItsFolder(_ model: AppModel, fixture: URL) async {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("doctopus-uitest-moved-\(UUID().uuidString)", isDirectory: true)
        let before = parent.appendingPathComponent("Before", isDirectory: true)
        let after = parent.appendingPathComponent("After", isDirectory: true)
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try? fm.copyItem(at: fixture, to: before)
        defer { try? fm.removeItem(at: parent) }

        let workspace = Workspace.shared
        workspace.register(model)
        let moving = AppModel()
        workspace.register(moving)
        defer {
            moving.windowClosed()
            workspace.current = model
        }
        _ = await moving.openLibrary(container: before.appendingPathComponent("library.doctopus"), quietly: true)
        guard await settle({ moving.library != nil && !moving.documents.isEmpty }) else {
            Check.that("a library to move is open", false)
            return
        }

        try? fm.moveItem(at: before, to: after)
        let followed = await settle { moving.library?.root.lastPathComponent == "After" }
        Check.that("a library whose folder is renamed while open reopens where it went", followed,
                   moving.library?.root.path ?? "closed: \(moving.errorMessage ?? "no reason")")

        try? fm.removeItem(at: after)
        let closed = await settle { moving.library == nil }
        Check.that("…and one whose folder is deleted closes, saying why",
                   closed && moving.errorMessage?.contains("After") == true,
                   moving.errorMessage ?? "no message")
    }

    /// A second library gets a window, and a model, of its own; the first
    /// one's panes never see it.
    static func secondLibraryOpensApart(_ model: AppModel, alongside fixture: URL,
                                        snapshots: String?) async {
        let alone = model.documents.count
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-uitest-2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: second) }
        try? FileManager.default.copyItem(at: fixture, to: second)
        let container = second.appendingPathComponent("library.doctopus", isDirectory: true)

        let workspace = Workspace.shared
        workspace.register(model)
        let other = AppModel()
        workspace.register(other)
        defer {
            other.windowClosed()
            workspace.current = model
        }

        model.selection = .all
        let handedOn = await model.openLibrary(container: container)
        let opened = await settle { other.library != nil && !other.documents.isEmpty }
        Check.that("a window showing a library hands a second one to an empty window",
                   handedOn == .elsewhere && opened && model.documents.count == alone,
                   "\(handedOn), \(model.documents.count) and \(other.documents.count) documents")
        guard opened, let first = model.library, let newer = other.library else { return }
        Check.that("each window lists only its own library",
                   other.documents.count == alone && model.documents.count == alone,
                   "\(model.documents.count) and \(other.documents.count) of \(alone)")

        let spare = AppModel()
        workspace.register(spare)
        defer { spare.windowClosed() }
        let again = await spare.openLibrary(container: container)
        Check.that("a library already open in one window is not opened in another",
                   again == .elsewhere && spare.library == nil, "\(again)")

        guard let row = other.documents.first else { return }
        other.addTag("OnlyHere", to: [row])
        _ = await settle { newer.tags.contains { $0.name == "OnlyHere" } }
        Check.that("a tag is made in the library of the window it was added in",
                   newer.tags.contains { $0.name == "OnlyHere" }
                       && !first.tags.contains { $0.name == "OnlyHere" },
                   "first: \(first.tags.map(\.name)), second: \(newer.tags.map(\.name))")

        let size = model.settings.galleryThumbnailSize
        other.settings.galleryThumbnailSize = size + 20
        let shared = await settle { model.settings.galleryThumbnailSize == size + 20 }
        Check.that("an app-wide setting changed in one window reaches the others", shared,
                   "\(model.settings.galleryThumbnailSize)")
        model.settings.galleryThumbnailSize = size
        let libraryOnly = model.settings.namingTemplate
        other.settings.namingTemplate = "{title} elsewhere"
        try? await Task.sleep(for: .milliseconds(300))
        Check.that("a library setting stays with its own library",
                   model.settings.namingTemplate == libraryOnly,
                   model.settings.namingTemplate)

        let (sidebarWindow, sidebar) = host(SidebarView().environment(other),
                                            size: NSSize(width: 260, height: 700))
        defer { sidebarWindow.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        if let dir = snapshots { snapshot(sidebar, to: dir + "/sidebar-second-window.png") }
        Check.that("the second window's sidebar draws", inkedRows(sidebar) > 20,
                   "\(inkedRows(sidebar)) rows with ink")

        other.closeLibrary()
        let closed = await settle { other.library == nil && other.documents.isEmpty }
        Check.that("closing a library empties its window", closed,
                   "\(other.documents.count) documents left")
        Check.that("closing a library leaves the other window alone",
                   model.library === first && model.documents.count == alone)
        Check.that("closing a library leaves its folder on disk",
                   FileManager.default.fileExists(atPath: container.path))
    }
}
