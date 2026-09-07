import AppKit
import QuickLookUI
import SwiftUI

/// Quick Look over the current selection.
///
/// The SwiftUI `.quickLookPreview` modifier only takes a single URL and does not
/// reliably follow selection changes, so this drives `QLPreviewPanel` directly:
/// the whole selection becomes the panel's data source, arrow keys page through
/// it, and pressing Space again closes it.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
                                 @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private var startIndex = 0

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Opens (or retargets) the panel. Called again with the same content it
    /// toggles closed, which is what Space is expected to do.
    func toggle(urls: [URL], startingAt url: URL? = nil) {
        guard !urls.isEmpty else { return }
        if isOpen, self.urls == urls {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        show(urls: urls, startingAt: url)
    }

    func show(urls: [URL], startingAt url: URL? = nil) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        self.urls = existing
        self.startIndex = url.flatMap { existing.firstIndex(of: $0) } ?? 0

        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = startIndex
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.currentPreviewItemIndex = startIndex
        }
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    /// Let the panel keep receiving arrow keys, and close on a second Space.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.charactersIgnoringModifiers == " " {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}
