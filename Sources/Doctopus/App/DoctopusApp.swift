import SwiftUI
import AppKit
import QuickLookUI

@main
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
            SelfTest.run(path: path)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--check") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
            runCheck(path: path)
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

    private static func runCheck(path: String) {
        let url = URL(fileURLWithPath: path)
        print("Verifying library at \(url.path)...")
        Task {
            do {
                let report = try await LibraryVerifier.verify(library: url)
                if report.isClean {
                    print("✓ Library is healthy: 0 errors, 0 warnings.")
                    exit(0)
                } else {
                    print("\nIssues found:")
                    for issue in report.issues {
                        let prefix = issue.severity == .error ? "✗ ERROR" : issue.severity == .warning ? "⚠ WARNING" : "ℹ INFO"
                        print("  \(prefix): \(issue.title)")
                        if let detail = issue.detail { print("    \(detail)") }
                    }
                    print("\nSummary: \(report.errorsCount) error(s), \(report.warningsCount) warning(s), \(report.infoCount) info.")
                    exit(report.errorsCount > 0 ? 1 : 0)
                }
            } catch {
                print("✗ Failed to verify library: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
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
                    ScanCoordinator.shared.onScan = { delivery, destination in
                        model.importScanned(delivery, into: destination)
                        model.scanDelivered(delivery)
                    }
                    ScanCoordinator.shared.onScanFailed = { model.scanFailed($0) }
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            SidebarCommands()
            InspectorCommands()
            DoctopusCommands(model: model)
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? { didSet { openPending() } }
    private var pendingOpens: [URL] = []

    // Continuity Camera: the import item must be in the main menu before launch
    // finishes, or it stays a dead, disabled leaf. See ScanCoordinator.
    func applicationWillFinishLaunching(_ notification: Notification) {
        ScanCoordinator.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        SpacePreview.install { [weak self] in self?.model?.quickLook() }
        OptionReveal.install { [weak self] held in self?.model?.revealingFolders = held }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpens += urls
        openPending()
    }

    private func openPending() {
        guard let model else { return }
        let urls = pendingOpens
        pendingOpens = []
        // Checked on disk: a URL handed over for a package need not end in a
        // slash, so `hasDirectoryPath` would turn it away.
        for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            MainActor.assumeIsolated { model.openLibrary(at: url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
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
            Menu("Open Recent") {
                let recent = NSDocumentController.shared.recentDocumentURLs
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                ForEach(recent, id: \.self) { url in
                    Button(url.deletingLastPathComponent().path.abbreviatingHome) { model.openLibrary(at: url) }
                }
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
                    .disabled(recent.isEmpty)
            }
            Button("Quick Open…") { model.sheet = .quickOpen }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Import Files…") { importPanel() }
                .keyboardShortcut("i", modifiers: [.command])
            if let session = model.scanSession {
                if session.isRunning {
                    Button("Stop Continuous Scanning") { model.stopContinuousScan() }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                } else {
                    Button("Resume Continuous Scanning") { model.resumeContinuousScan() }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                }
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Rescan All Folders") { model.reindex() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Verify Library…") { model.verifyLibrary() }
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
            Button("Rename with Template…") { model.sheet = .rename }
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
            Button("Revert to Original") { model.revertOptimization(model.selectedRows) }
                .disabled(model.selectedIDs.isEmpty || !model.selectedRows.contains { $0.originalSize != nil })
            Divider()
            Button("Move to Trash") { model.moveToTrash(model.selectedRows) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedIDs.isEmpty)
        }
    }

    private func importPanel() {
        guard let urls = ImportPanel.choose() else { return }
        model.importFiles(urls, into: nil)
    }
}
