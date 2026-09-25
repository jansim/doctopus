import SwiftUI
import AppKit

/// The naming highlight: a filename the template would not give is pointed
/// out once the setting asks for it, in orange, and Suppress takes it off
/// the list.
extension UITest {
    static func namingMismatchDraws(_ model: AppModel, snapshots: String?) async {
        let before = model.settings.namingEnforcement
        model.settings.namingEnforcement = .highlight
        defer { model.settings.namingEnforcement = before }
        if model.selection != .all { model.selection = .all }

        let pointedOut = await settle({ model.documents.contains { model.pendingNamingMismatch(for: $0) != nil } })
        Check.that("a filename the template would not give is pointed out", pointedOut)
        guard pointedOut,
              let row = model.documents.first(where: { model.pendingNamingMismatch(for: $0) != nil })
        else { return }

        let card = NamingMismatchSection(row: row).environment(model)
            .padding(14)
            .frame(width: 300, alignment: .topLeading)
        let (window, host) = host(card, size: NSSize(width: 300, height: 150))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(500))
        if let dir = snapshots { snapshot(host, to: dir + "/naming-mismatch.png") }
        let orange = orangePixels(host)
        Check.that("the naming highlight draws its card in orange",
                   inkedRows(host) > 10 && orange > 10, "\(orange) orange pixels")

        model.setNamingSuppressed(true, for: row)
        let suppressed = await settle({ model.pendingNamingMismatch(for: row) == nil
                                        && model.namingMismatch(for: row)?.suppressed == true })
        model.setNamingSuppressed(false, for: row)
        let handedBack = await settle({ model.pendingNamingMismatch(for: row) != nil })
        Check.that("suppressing a name takes its highlight off, and it can be handed back",
                   suppressed && handedBack)
    }

    /// Pixels close to the system orange, which neither the rule highlight's
    /// purple nor the window chrome comes near.
    private static func orangePixels(_ view: NSView) -> Int {
        guard let rep = bitmap(view) else { return 0 }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.85, c.greenComponent > 0.4, c.greenComponent < 0.75,
                   c.blueComponent < 0.3 { count += 1 }
            }
        }
        return count
    }
}
