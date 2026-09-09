import SwiftUI
import AppKit
import QuickLookUI

/// Entry point. A hidden `--selftest` mode drives the whole ingest pipeline
/// headlessly, which is how the indexing path is verified without a UI session.
@main
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
            SelfTest.run(path: path)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--new-library"),
           CommandLine.arguments.count > i + 1 {
            SelfTest.newLibrary(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--scantest") {
            let mode = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "menu"
            MainActor.assumeIsolated { ScanTest.run(mode: mode) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--uitest") {
            let args = CommandLine.arguments
            let root = args.count > i + 1 ? args[i + 1] : "Testing/DemoLibrary"
            MainActor.assumeIsolated {
                UITest.run(root: root, snapshots: args.count > i + 2 ? args[i + 2] : nil)
            }
            return
        }
        DoctopusApp.main()
    }
}

struct DoctopusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Doctopus", id: "main") {
            RootView()
                .environment(model)
                .task {
                    delegate.model = model
                    ScanCoordinator.shared.onScan = { items, destination in
                        model.importScanned(items, into: destination)
                    }
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1320, height: 840)
        .commands { DoctopusCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSServicesMenuRequestor {
    var model: AppModel?

    // Continuity Camera. The system looks for an import item in the main menu
    // exactly once, while the app is still launching: installed any later —
    // applicationDidFinishLaunching included — the item stays a dead, disabled
    // leaf. SwiftUI has already built its menus by now, so File is there to
    // amend. See ScanCoordinator and `--scantest`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        ScanCoordinator.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    /// Opening a `library.doctopus` (or a folder holding one) from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        for url in urls where url.hasDirectoryPath {
            model.openLibrary(at: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // The app delegate sits at the end of the responder chain, which is where
    // AppKit looks for somewhere to put a capture. Only the return type
    // matters: the send type says what we could hand *out*, and we hand out
    // nothing.
    @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                              returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard let returnType, ScanCoordinator.accepts(returnType) else { return nil }
        return self
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        MainActor.assumeIsolated { ScanCoordinator.shared.accept(pasteboard) }
    }

    func writeSelection(to pasteboard: NSPasteboard,
                        types: [NSPasteboard.PasteboardType]) -> Bool { false }

    // Quick Look asks the responder chain who owns the panel. SwiftUI views are
    // not in that chain, so the app delegate — which always is — claims it.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookController.shared
            panel.delegate = QuickLookController.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

struct DoctopusCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Library from Folder…") { model.addLibrary() }
                .keyboardShortcut("n", modifiers: [.command])
            Button("Open Library…") { model.openLibraryPicker() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Import Files…") { importPanel() }
                .keyboardShortcut("i", modifiers: [.command])
        }

        CommandGroup(after: .toolbar) {
            Button("Rescan All Folders") { model.reindex() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
        }

        CommandMenu("Document") {
            Button("Quick Look") { model.quickLook() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedIDs.isEmpty)
            Button("Open in Default App") { model.open(model.selectedRows) }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(model.selectedIDs.isEmpty)
            Button("Reveal in Finder") { model.reveal(model.selectedRows) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedIDs.isEmpty)
            Divider()
            Button("Rename with Template…") { NotificationCenter.default.post(name: .showRenameSheet, object: nil) }
                .disabled(model.selectedIDs.isEmpty)
            Button("Move to Folder…") { model.moveToFolderPicker(model.selectedRows) }
                .disabled(model.selectedIDs.isEmpty)
            Divider()
            Button("Reprocess") { model.reprocess(model.selectedRows) }
                .disabled(model.selectedIDs.isEmpty)
            Button("Analyze with Model") { model.analyze(model.selectedRows) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model.selectedIDs.isEmpty || !model.modelStatus.isReady)
            Button("Optimize") { model.optimize(model.selectedRows) }
                .disabled(model.selectedIDs.isEmpty)
            Divider()
            Button("Move to Trash") { model.moveToTrash(model.selectedRows) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedIDs.isEmpty)
        }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls, into: nil)
    }
}

extension Notification.Name {
    static let showRenameSheet = Notification.Name("io.doctopus.showRenameSheet")
}
