import AppKit
import UniformTypeIdentifiers

struct ScannedItem: Sendable {
    var data: Data
    var ext: String
}

/// Continuity Camera bridge.
///
/// AppKit expands any `NSMenuItem` carrying `NSMenuItem.importFromDeviceIdentifier`
/// into the live "Import from iPhone or iPad" entries, provided something in the
/// responder chain is an `NSServicesMenuRequestor` that accepts the relevant
/// return types. That identifier is the whole mechanism — an earlier attempt
/// went through `NSApp.servicesMenu`, which is why unrelated system services
/// such as Activity Monitor turned up in the menu.
@MainActor
final class ScanCoordinator: NSObject {
    static let shared = ScanCoordinator()

    /// Folder the next scan must land in. Set before the menu is shown so
    /// scan-in-place bypasses auto-routing entirely.
    var pendingDestination: URL?
    var onScan: (([ScannedItem], URL?) -> Void)?
    var onImportFiles: (([URL], URL?) -> Void)?

    nonisolated static let returnTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .pdf, .png, .tiff,
    ]

    func register() {
        NSApp.registerServicesMenuSendTypes([], returnTypes: Self.returnTypes)
        installMainMenuItem()
    }

    private var installAttempts = 0

    /// A menu whose first item AppKit replaces with the device entries.
    /// Rebuilt per presentation: the expansion is done at display time and a
    /// reused menu can hold on to entries for a device that has since left.
    func makeImportMenu(destination: URL?) -> NSMenu {
        let menu = NSMenu(title: "Import")
        let device = NSMenuItem()
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        device.title = "Import from iPhone or iPad"
        menu.addItem(device)
        menu.addItem(.separator())

        let files = NSMenuItem(title: destination.map { "Import Files into “\($0.lastPathComponent)”…" }
                                        ?? "Import Files…",
                               action: #selector(importFiles(_:)), keyEquivalent: "")
        files.target = self
        menu.addItem(files)
        return menu
    }

    /// Pops the scanner menu next to the caller.
    func presentMenu(destination: URL?, at point: NSPoint? = nil, in view: NSView? = nil) {
        pendingDestination = destination
        guard let window = view?.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let target = view ?? window.contentView
        let location = point ?? window.mouseLocationOutsideOfEventStream
        makeImportMenu(destination: destination).popUp(positioning: nil, at: location, in: target)
    }

    /// Adds "Import from iPhone or iPad" to the File menu. SwiftUI's command
    /// builders cannot express a menu item identifier, so the main menu is
    /// amended once, after AppKit has built it.
    private func installMainMenuItem() {
        // Locate the menu by the command we know we put there rather than by
        // title, which is localized. SwiftUI may not have finished assembling
        // the main menu yet, so retry briefly.
        let file = NSApp.mainMenu?.items.lazy.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.title.hasPrefix("Add Folder to Index") }
        }
        guard let file else {
            installAttempts += 1
            if installAttempts < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.installMainMenuItem()
                }
            }
            return
        }
        guard !file.items.contains(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier })
        else { return }

        let device = NSMenuItem()
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        device.title = "Import from iPhone or iPad"
        let index = file.items.firstIndex { $0.title.hasPrefix("Scan from iPhone") }.map { $0 + 1 }
            ?? file.items.count
        file.insertItem(device, at: index)
        file.insertItem(.separator(), at: index + 1)
    }

    @objc private func importFiles(_ sender: Any?) {
        let destination = pendingDestination
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        onImportFiles?(panel.urls, destination)
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
        case "pdf", "png", "jpg": return ext
        case "jpeg": return "jpg"
        case "tif", "tiff", "heic": return "png"
        default: return "pdf"
        }
    }
}
