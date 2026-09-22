import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScannedItem: Sendable {
    var data: Data
    var ext: String
}

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
        case deviceGone

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

        var isResolvedByDelivery: Bool { self != .lostFocus }
    }

    var device: String
    var action: String
    var destination: URL?
    var count: Int = 0
    var paused: Pause? = nil

    var isRunning: Bool { paused == nil }

    mutating func received(_ documents: Int) {
        count += documents
        if paused?.isResolvedByDelivery == true { paused = nil }
    }

    mutating func suspend(_ reason: Pause) { paused = reason }
    mutating func resume() { paused = nil }

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
    var onScan: (([ScannedItem], URL?) -> Void)?
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

    /// Concrete image types are spelled out: SwiftUI turns these into pasteboard
    /// types literally, so `.image` alone is not offered `public.jpeg`.
    static let importTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff, .image]

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
        DispatchQueue.main.async { [self] in
            if items.isEmpty {
                onScanFailed?("The scan from your iPhone or iPad could not be read.")
            } else {
                onScan?(items, destination)
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
        var results: [Data?] { lock.withLock { slots.map { $0 ?? nil } } }
    }

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
    /// Needed on every NavigationSplitView column: each is its own `NSHostingView`,
    /// and one with no importing view answers `validRequestor` with nil, failing
    /// the capture with Cocoa error 66563.
    func acceptsScans() -> some View {
        importsItemProviders(ScanCoordinator.importTypes) { ScanCoordinator.shared.accept($0) }
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
