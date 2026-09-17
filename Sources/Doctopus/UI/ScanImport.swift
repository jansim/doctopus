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

/// A run of back-to-back captures from one device: fire, the user scans and
/// submits on the device, the capture lands, fire again — until they stop.
/// Each round is one document, which is what suits the router; the multi-page
/// case is already the device's own scanner, which returns a single PDF.
///
/// The bookkeeping lives here, apart from the menu firing, so every transition
/// can be checked without a device in the room — see `--selftest`.
struct ScanSession: Equatable, Sendable {
    /// Why a run is not currently asking for captures. A paused run keeps its
    /// device, its destination and its count, so carrying on is one click.
    enum Pause: Equatable, Sendable {
        /// Doctopus stopped being the active app. A capture is handed to the
        /// key window's first responder, so one fired now would have nowhere
        /// to land.
        case lostFocus
        /// Nothing came back in time. Cancelling on the device sends no signal
        /// at all, so a long silence is the only thing there is to read.
        case timedOut
        /// A capture arrived and none of it could be read.
        case failed
        /// The device stopped offering the action, usually by going out of range.
        case deviceGone

        /// Short enough for the toolbar.
        var summary: String {
            switch self {
            case .deviceGone: return "Device gone"
            default: return "Paused"
            }
        }

        var detail: String {
            switch self {
            case .lostFocus:
                return "Paused because Doctopus is not the active app — a scan has nowhere to land. Click Resume to carry on."
            case .timedOut:
                return "Nothing arrived from the device, so the scan was probably cancelled there. Click Resume to ask again."
            case .failed:
                return "The last capture could not be read. Click Resume to try again."
            case .deviceGone:
                return "The device is no longer offering that. Bring it back in range and click Resume."
            }
        }

        /// Whether a capture landing while paused means the run can carry on by
        /// itself. Everything here has plainly resolved itself by the time
        /// something arrives — except losing focus, where the user is off in
        /// another app and the next capture is not ours to start.
        var isResolvedByDelivery: Bool { self != .lostFocus }
    }

    /// Named rather than held by menu position: the system rebuilds that
    /// submenu as devices come and go, so a run going for any length of time
    /// has to find its entry again every round.
    var device: String
    var action: String
    /// Pinned for the whole run, since `pendingDestination` is consumed by
    /// each delivery.
    var destination: URL?
    /// Documents received so far.
    var count: Int = 0
    var paused: Pause? = nil

    var isRunning: Bool { paused == nil }

    mutating func received(_ documents: Int) {
        count += documents
        if paused?.isResolvedByDelivery == true { paused = nil }
    }

    mutating func suspend(_ reason: Pause) { paused = reason }
    mutating func resume() { paused = nil }

    /// What the toolbar reads.
    var label: String {
        let scanned = count == 1 ? "1 document" : "\(count) documents"
        guard let reason = paused else {
            return count == 0 ? "Waiting for the first scan…" : "Scanning · \(scanned)"
        }
        return count == 0 ? reason.summary : "\(reason.summary) · \(scanned)"
    }

    var help: String {
        paused?.detail ?? "“\(action)” on \(device), one document after another. Each is filed as it arrives."
    }
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

    /// Starts a capture, pinning where the result must land. `false` when the
    /// row has gone from the menu, which a continuous run needs to hear about
    /// — nothing else comes back to say the capture never started.
    @discardableResult
    func scan(_ option: ScanOption, into destination: URL?) -> Bool {
        guard let live = deviceItem?.submenu else { return false }
        // The system rebuilds this menu as devices come and go, so confirm the
        // row is still the one the user picked before firing it.
        var index = option.index
        if index >= live.numberOfItems || live.items[index].title != option.title {
            guard let found = live.items.firstIndex(where: {
                $0.title == option.title && $0.representedObject != nil
            }) else { return false }
            index = found
        }
        pendingDestination = destination
        live.performActionForItem(at: index)
        return true
    }

    /// Starts a capture named by device and action rather than by menu
    /// position, which is what a continuous run has to do: between one round
    /// and the next the submenu may have been rebuilt, or the device may have
    /// left the room entirely.
    @discardableResult
    func scan(device: String, action: String, into destination: URL?) -> Bool {
        guard let match = devices().first(where: { $0.name == device }),
              let option = match.options.first(where: { $0.title == action })
        else { return false }
        return scan(option, into: destination)
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
    @Environment(AppModel.self) private var model
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
                        // The same actions again, each starting a run that
                        // asks for the next document as soon as one lands.
                        // Offered per action rather than guessing which entry
                        // is the document scanner: those titles are the
                        // system's, and localized.
                        Menu("Continuously") {
                            ForEach(device.options) { option in
                                Button(option.title) {
                                    model.startContinuousScan(device: device.name,
                                                              action: option.title,
                                                              into: destination)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A continuous run, in the toolbar: what has come in so far, a way to stop,
/// and — since a run pauses the moment Doctopus stops being the active app —
/// a way to pick it back up.
struct ScanSessionStatus: View {
    @Environment(AppModel.self) private var model
    let session: ScanSession

    var body: some View {
        HStack(spacing: 8) {
            if session.isRunning {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
            }
            Text(session.label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !session.isRunning {
                Button("Resume") { model.resumeContinuousScan() }
                    .controlSize(.small)
            }
            Button { model.stopContinuousScan() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop scanning")
        }
        .help(session.help)
    }
}
