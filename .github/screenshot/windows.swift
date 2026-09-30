// Lists the on-screen windows of a process, front to back, one per line:
// `id<TAB>x<TAB>y<TAB>width<TAB>height<TAB>title`. Usage: windows <process name>
//
// CGWindowList is the only source that has both the stacking order and the
// bounds without Accessibility access; titles need Screen Recording, which the
// hosted runners grant.
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Doctopus"
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []

for window in info where window[kCGWindowOwnerName as String] as? String == owner {
    // Layer 0 is ordinary windows; menus, tooltips and the status item sit above it.
    guard window[kCGWindowLayer as String] as? Int == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          let width = bounds["Width"], let height = bounds["Height"],
          width > 1, height > 1 else { continue }
    let title = (window[kCGWindowName as String] as? String ?? "")
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    print([id, Int(bounds["X"] ?? 0), Int(bounds["Y"] ?? 0), Int(width), Int(height)]
        .map(String.init).joined(separator: "\t") + "\t" + title)
}
