import SwiftUI
import AppKit

/// Closing the inspector and opening it again gives it back at the width it
/// had, rather than whatever the split view settles on.
extension UITest {
    static func inspectorKeepsItsWidth(_ model: AppModel) async {
        model.selection = .all
        model.viewMode = .list
        let columns = model.listColumns
        defer { model.listColumns = columns }
        let window = libraryWindow(model)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))

        guard let toggle = inspectorButton(in: window) else {
            let labels = (window.toolbar?.items ?? []).map { "\($0.itemIdentifier.rawValue)=\($0.label)" }
            return Check.that("the toolbar has an Inspector button", false, labels.joined(separator: ", "))
        }
        func widths() -> String {
            splitViews(in: window.contentView).map { split in
                split.arrangedSubviews.map { $0.isHidden ? "hidden" : "\(Int($0.frame.width.rounded()))" }
                    .joined(separator: "|")
            }.joined(separator: "  ")
        }
        func inspectorWidth() -> CGFloat? {
            // The inspector is the trailing item of the split that holds it.
            splitViews(in: window.contentView)
                .first { $0.arrangedSubviews.count >= 2 && $0.isVertical && $0.arrangedSubviews.last?.frame.minX ?? 0 > 400 }?
                .arrangedSubviews.last.map { $0.isHidden ? 0 : $0.frame.width }
        }
        func toggleTwice() async {
            for _ in 0..<2 {
                toggle()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }

        let first = widths(), firstWidth = inspectorWidth()
        await toggleTwice()
        let second = widths(), secondWidth = inspectorWidth()
        await toggleTwice()
        let third = widths(), thirdWidth = inspectorWidth()
        Check.that("closing and opening the inspector keeps its width",
                   firstWidth != nil && firstWidth == secondWidth && secondWidth == thirdWidth
                       && window.frame.width == 1100,
                   "\(first) → \(second) → \(third), window \(Int(window.frame.width))")

        // A width dragged to by hand should come back too.
        if let split = splitViews(in: window.contentView)
            .first(where: { $0.isVertical && $0.arrangedSubviews.count >= 2
                            && $0.arrangedSubviews.last?.frame.minX ?? 0 > 400 }) {
            let divider = split.arrangedSubviews.count - 2
            let target = split.bounds.width - 420
            split.setPosition(target, ofDividerAt: divider)
            try? await Task.sleep(for: .seconds(1))
            let dragged = widths(), draggedWidth = inspectorWidth()
            await toggleTwice()
            let reopened = widths(), reopenedWidth = inspectorWidth()
            Check.that("a width dragged to by hand survives closing and opening",
                       draggedWidth != nil && draggedWidth == reopenedWidth,
                       "\(dragged) → \(reopened)")
        }
        yieldFocus()
    }

    private static func splitViews(in view: NSView?) -> [NSSplitView] {
        guard let view else { return [] }
        return ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { splitViews(in: $0) }
    }

    /// Clicks the toolbar's Inspector button, wherever SwiftUI put it.
    private static func inspectorButton(in window: NSWindow) -> (() -> Void)? {
        let frame = window.contentView?.superview ?? window.contentView
        let candidates = (window.toolbar?.items ?? []).compactMap(\.view).flatMap { controls(in: $0) }
            + (frame.map { controls(in: $0) } ?? [])
        func named(_ control: NSControl) -> Bool {
            [control.accessibilityLabel(), control.toolTip, control.accessibilityTitle(),
             (control as? NSButton)?.title, control.accessibilityIdentifier()]
                .contains { $0?.localizedCaseInsensitiveContains("Inspector") == true }
        }
        if let button = candidates.first(where: named) {
            return { button.performClick(nil) }
        }
        print("  controls in the window frame: "
              + candidates.map { "\(type(of: $0))(\($0.accessibilityLabel() ?? "-"))" }.joined(separator: ", "))
        return nil
    }

    private static func controls(in view: NSView) -> [NSControl] {
        ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap { controls(in: $0) }
    }
}
