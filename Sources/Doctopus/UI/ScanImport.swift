import AppKit
import UniformTypeIdentifiers

struct ScannedItem: Sendable {
    var data: Data
    var ext: String
}

/// Continuity Camera bridge.
///
/// macOS surfaces "Scan Documents" / "Take Photo" as *services* that return data
/// without taking any input. Registering an empty send-type set with image and
/// PDF return types is what filters the Services menu down to exactly those
/// Continuity Camera entries — which is why the menu we pop up next to a folder
/// contains the scanner and nothing else.
@MainActor
final class ScanCoordinator: NSObject {
    static let shared = ScanCoordinator()

    /// Folder the next scan must land in. Set by the folder context menu so
    /// scan-in-place bypasses auto-routing entirely.
    var pendingDestination: URL?
    var onScan: (([ScannedItem], URL?) -> Void)?

    private(set) var menu = NSMenu(title: "Import from iPhone or iPad")

    nonisolated static let returnTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .pdf, .png, .tiff,
    ]

    func register() {
        NSApp.registerServicesMenuSendTypes([], returnTypes: Self.returnTypes)
        menu.autoenablesItems = true
        NSApp.servicesMenu = menu
    }

    /// Pops the system-populated scanner menu next to the caller.
    func presentMenu(destination: URL?, at point: NSPoint? = nil, in view: NSView? = nil) {
        pendingDestination = destination
        let target = view ?? NSApp.keyWindow?.contentView
        let location = point ?? NSApp.keyWindow?.mouseLocationOutsideOfEventStream ?? .zero
        if menu.numberOfItems == 0 {
            menu.addItem(withTitle: "No nearby iPhone or iPad", action: nil, keyEquivalent: "")
                .isEnabled = false
        }
        menu.popUp(positioning: nil, at: location, in: target)
    }

    /// Called by AppKit when the scan finishes on the device.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        var items: [ScannedItem] = []

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.isEmpty ? "pdf" : url.pathExtension.lowercased()
                items.append(ScannedItem(data: data, ext: normalize(ext)))
            }
        }
        if items.isEmpty, let pdf = pasteboard.data(forType: .pdf) {
            items.append(ScannedItem(data: pdf, ext: "pdf"))
        }
        if items.isEmpty, let png = pasteboard.data(forType: .png) {
            items.append(ScannedItem(data: png, ext: "png"))
        }
        if items.isEmpty, let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            items.append(ScannedItem(data: png, ext: "png"))
        }
        guard !items.isEmpty else { return false }

        let destination = pendingDestination
        pendingDestination = nil
        onScan?(items, destination)
        return true
    }

    /// Only the formats the index actually supports get through.
    private func normalize(_ ext: String) -> String {
        switch ext {
        case "pdf", "png", "jpg", "jpeg": return ext == "jpeg" ? "jpg" : ext
        case "tif", "tiff", "heic": return "png"
        default: return "pdf"
        }
    }
}
