import SwiftUI
import AppKit

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
        if let i = CommandLine.arguments.firstIndex(of: "--add-root"),
           CommandLine.arguments.count > i + 1 {
            SelfTest.addRoot(CommandLine.arguments[i + 1])
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainActor.assumeIsolated { ScanCoordinator.shared.register() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // The app delegate sits at the end of the responder chain, which is where
    // AppKit looks for a Continuity Camera destination.
    @objc func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                              returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, ScanCoordinator.returnTypes.contains(returnType), sendType == nil {
            return self
        }
        return nil
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        MainActor.assumeIsolated { ScanCoordinator.shared.accept(pasteboard) }
    }

    func writeSelection(to pasteboard: NSPasteboard,
                        types: [NSPasteboard.PasteboardType]) -> Bool { false }
}

struct DoctopusCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder to Index…") { model.addRoot() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("Import Files…") { importPanel() }
                .keyboardShortcut("i", modifiers: [.command])
            Button("Import from iPhone or iPad") {
                ScanCoordinator.shared.presentMenu(destination: model.defaultImportDirectory)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Rescan All Folders") { model.reindex() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
        }

        CommandMenu("Document") {
            Button("Quick Look") { model.isQuickLookOpen.toggle() }
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
