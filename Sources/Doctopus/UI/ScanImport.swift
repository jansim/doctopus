import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScannedItem: Sendable {
    var data: Data
    var ext: String
}

/// One capture action offered by a nearby device.
struct ScanOption: Identifiable, Hashable, Sendable {
    var id: Int { index }
    /// Position in the system-maintained submenu, which is what gets fired.
    var index: Int
    var title: String
}

struct ScanDevice: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var options: [ScanOption]
}

/// Continuity Camera bridge.
///
/// The mechanism is a single `NSMenuItem` carrying
/// `NSMenuItem.importFromDeviceIdentifier`, which the system replaces with a
/// live submenu of nearby devices and their capture actions. Two constraints
/// govern everything here, both established with `--scantest`:
///
/// 1. The item has to be in the **main menu** before the app finishes
///    launching. Installed from `applicationDidFinishLaunching` — let alone
///    later — it stays a dead, disabled leaf, which is exactly what the
///    previous version shipped.
/// 2. The expansion only ever happens to *that* item. A second item with the
///    same identifier in a context menu is never expanded, so context menus
///    mirror the live entries instead and fire the originals.
@MainActor
final class ScanCoordinator: NSObject {
    static let shared = ScanCoordinator()

    /// Folder the next scan must land in. Set before firing so scan-in-place
    /// bypasses auto-routing entirely.
    var pendingDestination: URL?
    var onScan: (([ScannedItem], URL?) -> Void)?
    /// A capture arrived but none of it could be read.
    var onScanFailed: ((String) -> Void)?

    private weak var deviceItem: NSMenuItem?

    /// Everything Continuity Camera can hand back: still images in whatever
    /// format the device chooses, plus PDF for multi-page document scans.
    nonisolated static var returnTypes: [NSPasteboard.PasteboardType] {
        (NSImage.imageTypes + [UTType.pdf.identifier, UTType.fileURL.identifier])
            .map(NSPasteboard.PasteboardType.init(rawValue:))
    }

    nonisolated static func accepts(_ type: NSPasteboard.PasteboardType) -> Bool {
        returnTypes.contains(type)
    }

    /// Must run from `applicationWillFinishLaunching`. SwiftUI has assembled
    /// its menus by then, and the system has not yet gone looking for import
    /// items — the one window in which this works.
    func install() {
        NSApp.registerServicesMenuSendTypes([], returnTypes: Self.returnTypes)

        // Locate the File menu by a command we know we put there rather than by
        // its localized title.
        let file = NSApp.mainMenu?.items.lazy.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.title.hasPrefix("Add Folder to Index") }
        } ?? NSApp.mainMenu?.item(at: 1)?.submenu
        guard let file else { return }

        let item = NSMenuItem()
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        item.title = "Import from iPhone or iPad"  // AppKit relabels it itself
        let index = file.items.firstIndex { $0.title.hasPrefix("Import Files") }.map { $0 + 1 }
            ?? file.items.count
        file.insertItem(item, at: index)
        deviceItem = item
    }

    /// Nearby devices and what each can capture, read out of the live submenu.
    /// Empty when no device is in range or the system has not populated it yet.
    func devices() -> [ScanDevice] {
        guard let item = deviceItem else { return [] }
        item.menu?.update()
        guard let live = item.submenu else { return [] }
        live.update()

        var devices: [ScanDevice] = []
        for (i, entry) in live.items.enumerated() where !entry.isSeparatorItem {
            // Device names head each section and carry no service action.
            if entry.representedObject == nil {
                devices.append(ScanDevice(name: entry.title, options: []))
            } else if !devices.isEmpty, entry.isEnabled {
                devices[devices.count - 1].options.append(
                    ScanOption(index: i, title: entry.title))
            }
        }
        return devices.filter { !$0.options.isEmpty }
    }

    /// Starts a capture, pinning where the result must land.
    func scan(_ option: ScanOption, into destination: URL?) {
        guard let live = deviceItem?.submenu else { return }
        // The system rebuilds this menu as devices come and go, so confirm the
        // row is still the one the user picked before firing it.
        var index = option.index
        if index >= live.numberOfItems || live.items[index].title != option.title {
            guard let found = live.items.firstIndex(where: {
                $0.title == option.title && $0.representedObject != nil
            }) else { return }
            index = found
        }
        pendingDestination = destination
        live.performActionForItem(at: index)
    }

    /// What the app takes from a capture: PDF for document scans, and still
    /// images in whatever format the device chooses.
    ///
    /// Concrete image types are spelled out: SwiftUI turns these into pasteboard
    /// types literally, so `.image` alone is not offered `public.jpeg`.
    static let importTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff, .image]

    /// Called by SwiftUI once the capture arrives, via `acceptsScans()` on
    /// whichever pane has focus.
    ///
    /// Not an `NSServicesMenuRequestor` on the app delegate, which is what
    /// `--scantest` exercises: in the SwiftUI app `NSHostingView` and the
    /// delegate proxy SwiftUI installs answer `validRequestor` themselves, so
    /// an AppKit requestor further up the chain is never asked.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let captures = providers.compactMap { provider in
            provider.registeredContentTypes
                .first { type in Self.importTypes.contains { type.conforms(to: $0) } }
                .map { (provider, $0) }
        }
        guard !captures.isEmpty else { return false }

        // The capture sits on a pasteboard the system discards the moment this
        // returns, and the providers read from it lazily: loaded any later,
        // they fail with NSItemProvider error -1000. So wait for them here,
        // keeping the run loop turning in case a loader calls back on main.
        let loads = Loads(count: captures.count)
        for (i, (provider, type)) in captures.enumerated() {
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                loads.finish(i, with: data)
            }
        }
        let deadline = Date(timeIntervalSinceNow: 30)
        while !loads.isComplete, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        let items = zip(captures, loads.results).compactMap { capture, data in
            data.flatMap { item(from: $0, ext: capture.1.preferredFilenameExtension ?? "") }
        }
        let destination = pendingDestination
        pendingDestination = nil
        // Importing can wait until the system's callback has returned.
        DispatchQueue.main.async { [self] in
            if items.isEmpty {
                onScanFailed?("The scan from your iPhone or iPad could not be read.")
            } else {
                onScan?(items, destination)
            }
        }
        // Taken either way: an unreadable scan gets our own message rather
        // than the system's bare Cocoa error on top of it.
        return true
    }

    /// Provider loads, which finish on arbitrary queues.
    private final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [Data??]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func finish(_ index: Int, with data: Data?) { lock.withLock { slots[index] = .some(data) } }
        var isComplete: Bool { lock.withLock { !slots.contains { $0 == nil } } }
        var results: [Data?] { lock.withLock { slots.map { $0 ?? nil } } }
    }

    /// The index handles PDF, JPEG and PNG. Anything else a device might send
    /// — HEIC above all — is transcoded rather than just renamed.
    private func item(from data: Data, ext: String) -> ScannedItem? {
        switch ext.lowercased() {
        case "pdf", "png", "jpg": return ScannedItem(data: data, ext: ext.lowercased())
        case "jpeg": return ScannedItem(data: data, ext: "jpg")
        default:
            if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return ScannedItem(data: data, ext: "pdf") }
            guard let rep = NSBitmapImageRep(data: data),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            else { return nil }
            return ScannedItem(data: jpg, ext: "jpg")
        }
    }
}

extension View {
    /// Makes this view somewhere a Continuity Camera capture can land.
    ///
    /// Needed on every NavigationSplitView column, not just around the split
    /// view: each column is its own `NSHostingView`, and a hosting view with no
    /// importing view in its own hierarchy answers `validRequestor` with nil
    /// rather than passing the question up the responder chain. The system
    /// asks only the key window's first responder — which almost always sits
    /// inside a column — so without this it finds no requestor and fails the
    /// capture with Cocoa error 66563.
    func acceptsScans() -> some View {
        importsItemProviders(ScanCoordinator.importTypes) { ScanCoordinator.shared.accept($0) }
    }
}

/// The device entries, mirrored into a SwiftUI menu. Rebuilt every time the
/// enclosing menu opens, so it always reflects what is actually in range.
struct ScanMenu: View {
    /// Where the capture lands. `nil` follows the sidebar selection.
    var destination: URL?

    var body: some View {
        let devices = ScanCoordinator.shared.devices()
        Menu("Import from iPhone or iPad") {
            if devices.isEmpty {
                Button("No iPhone or iPad Nearby") {}.disabled(true)
            } else {
                ForEach(devices) { device in
                    Section(device.name) {
                        ForEach(device.options) { option in
                            Button(option.title) {
                                ScanCoordinator.shared.scan(option, into: destination)
                            }
                        }
                    }
                }
            }
        }
    }
}
