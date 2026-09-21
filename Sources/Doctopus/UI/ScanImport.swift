import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

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
        /// Part of a delivery could not be read. The run stops rather than
        /// carry on: whatever is losing captures is still losing them, and a
        /// stack scanned into a gap is worse than a stack half scanned.
        case incomplete
        /// The device stopped offering the action, usually by going out of range.
        case deviceGone

        /// Short enough for the toolbar.
        var summary: String {
            switch self {
            case .deviceGone: return "Device gone"
            case .incomplete: return "Incomplete"
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
            case .incomplete:
                return "Part of the last scan could not be read, so the run stopped rather than carry on. Check what arrived, then click Resume."
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
    /// Pages inside those documents, which is not the same number the moment a
    /// device scanner returns a multi-page PDF — and is the number that gives
    /// a short delivery away while the stack is still in the room.
    var pages: Int = 0
    var paused: Pause? = nil

    var isRunning: Bool { paused == nil }

    mutating func received(_ documents: Int, pages: Int) {
        count += documents
        self.pages += pages
        if paused?.isResolvedByDelivery == true { paused = nil }
    }

    mutating func suspend(_ reason: Pause) { paused = reason }
    mutating func resume() { paused = nil }

    /// What the toolbar reads.
    var label: String {
        var scanned = count == 1 ? "1 document" : "\(count) documents"
        if pages > count { scanned += " · \(pages) pages" }
        guard let reason = paused else {
            return count == 0 ? "Waiting for the first scan…" : "Scanning · \(scanned)"
        }
        return count == 0 ? reason.summary : "\(reason.summary) · \(scanned)"
    }

    var help: String {
        paused?.detail ?? "“\(action)” on \(device), one document after another. Each is filed as it arrives."
    }
}

/// Quits and reopens Doctopus — the only way back once the Continuity Camera
/// item has stopped offering a device it plainly ought to see. It is
/// installed exactly once, from `applicationDidFinishLaunching`; nothing
/// later in the app's life can put it through that step again, and a fresh
/// launch is the whole fix.
enum AppRelauncher {
    @MainActor
    static func confirmAndRelaunch() {
        let alert = NSAlert()
        alert.messageText = "Relaunch Doctopus?"
        alert.informativeText = "Everything here is already saved, so nothing is lost. Only a fresh launch can make Doctopus visible to Continuity Camera again."
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Forced, since the instance being asked to open a new one is the very
        // one about to quit — without it the request could just as easily
        // activate the instance now terminating instead of starting a fresh one.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
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
    var onScan: ((ScanDelivery, URL?) -> Void)?
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

    /// Called by SwiftUI once the capture arrives, via `acceptsScans()` on
    /// whichever pane has focus.
    ///
    /// Not an `NSServicesMenuRequestor` on the app delegate, which is what
    /// `--scantest` exercises: in the SwiftUI app `NSHostingView` and the
    /// delegate proxy SwiftUI installs answer `validRequestor` themselves, so
    /// an AppKit requestor further up the chain is never asked.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let captures = providers.compactMap { provider in
            ScanCapture.preferredType(among: provider.registeredContentTypes,
                                      accepting: ScanCapture.importTypes)
                .map { (provider, $0) }
        }
        for (index, provider) in providers.enumerated() {
            let offered = provider.registeredContentTypes.map(\.identifier).joined(separator: ", ")
            ScanCapture.log.notice("capture \(index + 1, privacy: .public) of \(providers.count, privacy: .public) offers [\(offered, privacy: .public)]")
        }
        guard !captures.isEmpty else {
            ScanCapture.log.error("nothing offered could be read — the delivery was refused")
            return false
        }
        if captures.count < providers.count {
            // Counted as lost below, along with everything else that does not
            // make it: guessing that an item in a form this app cannot read is
            // not part of the scan is exactly the guess that loses pages.
            ScanCapture.log.error("\(providers.count - captures.count, privacy: .public) item(s) offered nothing this app can read")
        }

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
        if loads.unfinished > 0 {
            // Nothing can be done about it here — the pasteboard goes with this
            // return — but a capture that times out used to be dropped without
            // a word, which is how a scan could come up short in silence.
            ScanCapture.log.error("\(loads.unfinished, privacy: .public) capture(s) still loading after 30s")
        }

        let items = zip(captures, loads.results).compactMap { capture, data -> ScannedItem? in
            guard let data else {
                ScanCapture.log.error("\(capture.1.identifier, privacy: .public) came back with no data")
                return nil
            }
            guard let item = ScanCapture.item(from: data, declared: capture.1) else {
                ScanCapture.log.error("\(capture.1.identifier, privacy: .public), \(data.count, privacy: .public) bytes: could not be read")
                return nil
            }
            ScanCapture.log.notice("\(capture.1.identifier, privacy: .public), \(data.count, privacy: .public) bytes -> \(item.ext, privacy: .public), \(item.pages, privacy: .public) page(s)")
            return item
        }
        let delivery = ScanDelivery(offered: providers.count, items: items)
        ScanCapture.log.notice("delivered \(delivery.items.count, privacy: .public) of \(delivery.offered, privacy: .public) capture(s), \(delivery.pages, privacy: .public) page(s)")

        let destination = pendingDestination
        pendingDestination = nil
        // Importing can wait until the system's callback has returned.
        DispatchQueue.main.async { [self] in
            if items.isEmpty {
                onScanFailed?("The scan from your iPhone or iPad could not be read.")
            } else {
                onScan?(delivery, destination)
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
        /// Loads that never called back, as opposed to ones that failed.
        var unfinished: Int { lock.withLock { slots.filter { $0 == nil }.count } }
        var results: [Data?] { lock.withLock { slots.map { $0 ?? nil } } }
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
        importsItemProviders(ScanCapture.importTypes) { ScanCoordinator.shared.accept($0) }
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
                Divider()
                // The live submenu this reads is rebuilt by the system on its
                // own schedule; when it has stopped finding a device that is
                // plainly in range, nothing short of relaunching brings the
                // Continuity Camera item back to life — see `ScanCoordinator`.
                Button("Relaunch to Check Again…") { AppRelauncher.confirmAndRelaunch() }
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
