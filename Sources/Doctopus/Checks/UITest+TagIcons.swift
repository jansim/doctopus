import SwiftUI
import AppKit

extension UITest {
    /// An icon picked for a tag is what the sidebar draws for it, and it goes
    /// along when the tag is renamed.
    static func tagIconsReachTheSidebar(_ model: AppModel, snapshots: String?) async {
        let name = "Iconic in the sidebar"
        model.createTag(named: name)
        guard await settle({ model.tags.contains { $0.name == name } }),
              let tag = model.tags.first(where: { $0.name == name }) else {
            Check.that("a tag to pick an icon for", false); return
        }
        func current() -> Tag? { model.tags.first { $0.tagID == tag.tagID } }

        let (window, sidebar) = host(SidebarView().environment(model), size: NSSize(width: 260, height: 1600))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(2))
        let before = bitmap(sidebar)?.representation(using: .png, properties: [:])

        model.setTagIcon(tag, "star")
        let stored = await settle { current()?.icon == "star" }
        Check.that("an icon picked for a tag reaches the sidebar's tags", stored,
                   current()?.icon ?? "no icon")
        try? await Task.sleep(for: .seconds(1))
        let after = bitmap(sidebar)?.representation(using: .png, properties: [:])
        if let dir = snapshots { snapshot(sidebar, to: dir + "/sidebar-tag-icon.png") }
        Check.that("the sidebar draws the tag's icon in place of the default one",
                   before != nil && after != nil && before != after)

        model.renameTag(tag, to: name + " renamed")
        let kept = await settle { current()?.name == name + " renamed" && current()?.icon == "star" }
        Check.that("renaming the tag keeps its icon", kept, current().map { "\($0.name): \($0.icon ?? "none")" } ?? "gone")

        if let renamed = current() {
            model.setTagIcon(renamed, nil)
            let reset = await settle { current()?.icon == nil }
            Check.that("Reset to Default takes the icon off again", reset)
            model.deleteTag(renamed)
        }
        _ = await settle { current() == nil }
    }
}
