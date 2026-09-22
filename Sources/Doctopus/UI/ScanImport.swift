import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

struct ScanOption: Identifiable, Hashable, Sendable {
    var id: Int { index }
    var index: Int
    var title: String
}

struct ScanDevice: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var options: [ScanOption]
}

struct ScanSession: Equatable, Sendable {
    enum Pause: Equatable, Sendable {
        case lostFocus
        case timedOut
        case failed
        case incomplete
        case deviceGone

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

        var isResolvedByDelivery: Bool { self != .lostFocus }
    }

    var device: String
    var action: String
    var destination: URL?
    var count: Int = 0
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

enum AppRelauncher {
    @MainActor
    static func confirmAndRelaunch() {
        let alert = NSAlert()
        alert.messageText = "Relaunch Doctopus?"
        alert.informativeText = "Everything here is already saved, so nothing is lost. Only a fresh launch can make Doctopus visible to Continuity Camera again."
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }
}

/// Continuity Camera bridge. Two constraints, both established with `--scantest`:
/// the import item must be in the main menu before launch finishes, and only
/// that item is ever expanded — context menus mirror its entries instead.
@MainActor
final class ScanCoordinator: NSObject {
    static let shared = ScanCoordinator()

    var pendingDestination: URL?
    var onScan: ((ScanDelivery, URL?) -> Void)?
    var onScanFailed: ((String) -> Void)?

    private weak var deviceItem: NSMenuItem?

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

        let file = NSApp.mainMenu?.items.lazy.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.title.hasPrefix("Add Folder to Index") }
        } ?? NSApp.mainMenu?.item(at: 1)?.submenu
        guard let file else { return }

        let item = NSMenuItem()
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        item.title = "Import from iPhone or iPad"
        let index = file.items.firstIndex { $0.title.hasPrefix("Import Files") }.map { $0 + 1 }
            ?? file.items.count
        file.insertItem(item, at: index)
        deviceItem = item
    }

    func devices() -> [ScanDevice] {
        guard let item = deviceItem else { return [] }
        item.menu?.update()
        guard let live = item.submenu else { return [] }
        live.update()

        var devices: [ScanDevice] = []
        for (i, entry) in live.items.enumerated() where !entry.isSeparatorItem {
            if entry.representedObject == nil {
                devices.append(ScanDevice(name: entry.title, options: []))
            } else if !devices.isEmpty, entry.isEnabled {
                devices[devices.count - 1].options.append(
                    ScanOption(index: i, title: entry.title))
            }
        }
        return devices.filter { !$0.options.isEmpty }
    }

    @discardableResult
    func scan(_ option: ScanOption, into destination: URL?) -> Bool {
        guard let live = deviceItem?.submenu else { return false }
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

    @discardableResult
    func scan(device: String, action: String, into destination: URL?) -> Bool {
        guard let match = devices().first(where: { $0.name == device }),
              let option = match.options.first(where: { $0.title == action })
        else { return false }
        return scan(option, into: destination)
    }

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
        DispatchQueue.main.async { [self] in
            if items.isEmpty {
                onScanFailed?("The scan from your iPhone or iPad could not be read.")
            } else {
                onScan?(delivery, destination)
            }
        }
        return true
    }

    private final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [Data??]

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func finish(_ index: Int, with data: Data?) { lock.withLock { slots[index] = .some(data) } }
        var isComplete: Bool { lock.withLock { !slots.contains { $0 == nil } } }
        var unfinished: Int { lock.withLock { slots.filter { $0 == nil }.count } }
        var results: [Data?] { lock.withLock { slots.map { $0 ?? nil } } }
    }
}

extension View {
    /// Needed on every NavigationSplitView column: each is its own `NSHostingView`,
    /// and one with no importing view answers `validRequestor` with nil, failing
    /// the capture with Cocoa error 66563.
    func acceptsScans() -> some View {
        importsItemProviders(ScanCapture.importTypes) { ScanCoordinator.shared.accept($0) }
    }
}

struct ScanMenu: View {
    @Environment(AppModel.self) private var model
    var destination: URL?

    var body: some View {
        let devices = ScanCoordinator.shared.devices()
        Menu("Import from iPhone or iPad") {
            if devices.isEmpty {
                Button("No iPhone or iPad Nearby") {}.disabled(true)
                Divider()
                Button("Relaunch to Check Again…") { AppRelauncher.confirmAndRelaunch() }
            } else {
                ForEach(devices) { device in
                    Section(device.name) {
                        ForEach(device.options) { option in
                            Button(option.title) {
                                ScanCoordinator.shared.scan(option, into: destination)
                            }
                        }
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
