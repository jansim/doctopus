import AppKit
import QuickLookUI
import SwiftUI

/// Drives `QLPreviewPanel` directly: `.quickLookPreview` takes a single URL
/// and does not reliably follow selection changes.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
                                 @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private var startIndex = 0

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(urls: [URL], startingAt url: URL? = nil) {
        guard !urls.isEmpty else { return }
        if isOpen, self.urls == urls {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        show(urls: urls, startingAt: url)
    }

    private func show(urls: [URL], startingAt url: URL? = nil) {
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

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.charactersIgnoringModifiers == " " {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}

@MainActor
enum SpacePreview {
    private static var preview: @MainActor () -> Void = {}

    static func install(_ preview: @escaping @MainActor () -> Void) {
        self.preview = preview
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let previewed = MainActor.assumeIsolated { () -> Bool in
                guard shouldPreview(characters: characters, modifiers: modifiers,
                                    panelIsVisible: QuickLookController.shared.isOpen,
                                    editingText: NSApp.keyWindow?.firstResponder is NSText)
                else { return false }
                Self.preview()
                return true
            }
            return previewed ? nil : event
        }
    }

    private static func shouldPreview(characters: String?, modifiers: NSEvent.ModifierFlags,
                                      panelIsVisible: Bool, editingText: Bool) -> Bool {
        guard characters == " " else { return false }
        guard modifiers.intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.command, .option, .control, .shift]) else { return false }
        return !panelIsVisible && !editingText
    }
}
