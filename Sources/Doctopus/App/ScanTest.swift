import AppKit

/// `--scantest [menu|fire]` — a headless probe for the Continuity Camera
/// wiring, which cannot be exercised from the UI without a device in the room.
///
/// `menu` reports which devices the system offers and whether the responder
/// chain terminates somewhere that can take a capture. `fire` additionally
/// starts a document scan and reports what comes back, which is the only way
/// to check the delivery half end to end.
///
/// This is also the harness that established the two rules ScanCoordinator is
/// built on: the import item must be in the main menu before launch finishes,
/// and only that one item is ever expanded.
@MainActor
enum ScanTest {
    final class Delegate: NSObject, NSApplicationDelegate, NSServicesMenuRequestor {
        var magic: NSMenuItem?

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
            log("DELIVERED types=\(pasteboard.types?.map(\.rawValue) ?? [])")
            for type in pasteboard.types ?? [] {
                log("  \(type.rawValue): \(pasteboard.data(forType: type)?.count ?? 0) bytes")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
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
            guard mode == "fire" else { exit(0) }

            guard let index = live.items.firstIndex(where: {
                $0.title == "Scan Documents" && $0.representedObject != nil && $0.isEnabled
            }) else {
                log("nothing to fire — no device in range?")
                exit(1)
            }
            log("firing [\(index)] — complete the scan on the device; 300s timeout")
            live.performActionForItem(at: index)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                log("timed out with no delivery")
                exit(1)
            }
        }
        app.run()
    }

    private static func type_of(_ v: Any) -> String { String(describing: type(of: v)) }
}
