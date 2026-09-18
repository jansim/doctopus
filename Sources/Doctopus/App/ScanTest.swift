import AppKit

/// `--scantest [menu|fire|loop]` — a headless probe for the Continuity Camera
/// wiring, which cannot be exercised from the UI without a device in the room.
///
/// `menu` reports which devices the system offers and whether the responder
/// chain terminates somewhere that can take a capture. `fire` additionally
/// starts a document scan and reports what comes back, which is the only way
/// to check the delivery half end to end. `loop` keeps going — it asks for the
/// next capture as soon as one lands — and times each round, which is what
/// continuous scanning is built on: whether a device honours a fire that
/// arrives moments after it finished the last one, and how long to wait first
/// (`AppModel.scanRearm`).
///
/// This is also the harness that established the two rules ScanCoordinator is
/// built on: the import item must be in the main menu before launch finishes,
/// and only that one item is ever expanded.
///
/// Delivery here goes to a plain AppKit requestor, which is *not* how the app
/// receives it: SwiftUI's hosting views answer the responder chain first, so
/// the real app takes captures through `acceptsScans()`. A clean `fire` run
/// says nothing about that half — scan into the app itself to check it.
@MainActor
enum ScanTest {
    final class Delegate: NSObject, NSApplicationDelegate, NSServicesMenuRequestor {
        var magic: NSMenuItem?
        /// Rounds still to run after this delivery. Zero outside `loop`.
        var remaining = 0
        var round = 0
        var firedAt = Date()

        func applicationWillFinishLaunching(_ note: Notification) {
            let file = NSMenu(title: "File")
            let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
            item.identifier = NSMenuItem.importFromDeviceIdentifier
            file.addItem(item)
            let fileItem = NSMenuItem()
            fileItem.submenu = file
            let main = NSMenu()
            let appItem = NSMenuItem()
            let appMenu = NSMenu(title: "Doctopus")
            appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            main.addItem(appItem)
            main.addItem(fileItem)
            NSApp.mainMenu = main
            magic = item
        }

        @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                  returnType: NSPasteboard.PasteboardType?) -> Any? {
            guard let returnType, ScanCoordinator.accepts(returnType) else { return nil }
            return self
        }

        func readSelection(from pasteboard: NSPasteboard) -> Bool {
            let elapsed = String(format: "%.1fs", Date().timeIntervalSince(firedAt))
            log("DELIVERED after \(elapsed) types=\(pasteboard.types?.map(\.rawValue) ?? [])")
            for type in pasteboard.types ?? [] {
                log("  \(type.rawValue): \(pasteboard.data(forType: type)?.count ?? 0) bytes")
            }
            remaining -= 1
            guard remaining > 0 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                return true
            }
            // Not from here: this runs inside the system's callback, and the
            // pasteboard the capture came on is still alive until it returns.
            // The delay is the one the app uses between rounds.
            log("\(remaining) round(s) to go")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if !ScanTest.fire() {
                    log("the device stopped offering it — out of range?")
                    exit(1)
                }
            }
            return true
        }

        func writeSelection(to pasteboard: NSPasteboard,
                            types: [NSPasteboard.PasteboardType]) -> Bool { false }
    }

    nonisolated static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    private static let delegate = Delegate()

    static func run(mode: String) {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.registerServicesMenuSendTypes([], returnTypes: ScanCoordinator.returnTypes)

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "scantest"
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for type in ["public.jpeg", "public.png", "com.adobe.pdf"] {
                let requestor = window.validRequestor(forSendType: nil,
                                                      returnType: NSPasteboard.PasteboardType(type))
                log("chain \(type) -> \(requestor.map { String(describing: type_of($0)) } ?? "nil")")
            }
            guard let live = delegate.magic?.submenu else {
                log("no submenu: the system never expanded the import item")
                exit(1)
            }
            live.update()
            for (i, item) in live.items.enumerated() where !item.isSeparatorItem {
                log("[\(i)] \(item.representedObject == nil ? "device" : "action") '\(item.title)'"
                    + (item.isEnabled ? "" : " (disabled)"))
            }
            guard mode == "fire" || mode == "loop" else { exit(0) }

            delegate.remaining = mode == "loop" ? 3 : 1
            log("\(delegate.remaining) round(s) — complete each scan on the device; 300s per round")
            guard fire() else {
                log("nothing to fire — no device in range?")
                exit(1)
            }
        }
        app.run()
    }

    /// Fires the document-scan entry, found afresh each time: the system
    /// rebuilds that submenu between rounds.
    @discardableResult
    static func fire(_ title: String = "Scan Documents") -> Bool {
        guard let live = delegate.magic?.submenu else { return false }
        live.update()
        guard let index = live.items.firstIndex(where: {
            $0.title == title && $0.representedObject != nil && $0.isEnabled
        }) else { return false }
        log("firing [\(index)] '\(title)'")
        delegate.firedAt = Date()
        delegate.round += 1
        let round = delegate.round
        live.performActionForItem(at: index)
        // One watchdog per round, rather than one for the run: a capture that
        // never lands is the interesting failure, and which round gave up is
        // the whole answer — the second one failing where the first worked is
        // exactly what this mode is looking for.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            guard delegate.round == round, delegate.remaining > 0 else { return }
            log("round \(round) timed out with no delivery")
            exit(1)
        }
        return true
    }

    private static func type_of(_ v: Any) -> String { String(describing: type(of: v)) }
}
