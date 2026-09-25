import Foundation
import AppKit
import os

extension AppModel {

    var defaultImportDirectory: URL? {
        guard let lib = library else { return nil }
        return lib.root.appendingPathComponent(lib.settings.scanDestination, isDirectory: true)
    }

    var explicitImportDirectory: URL? {
        if case .folder(let path) = selection { return URL(fileURLWithPath: path) }
        return nil
    }

    var contextImportDirectory: URL? {
        explicitImportDirectory ?? defaultImportDirectory
    }

    /// With no `destination`, files go to the Inbox and are auto-routed: the only
    /// case where Doctopus moves a file on its own, and only one it just brought in.
    func importFiles(_ urls: [URL], into destination: URL?, movingSource: Bool = false) {
        let chosen = destination ?? explicitImportDirectory
        guard let dest = chosen ?? defaultImportDirectory else {
            errorMessage = "Open a library before importing."
            return
        }
        guard let lib = library else {
            errorMessage = "Open a library before importing."
            return
        }
        guard lib.owns(path: dest.path) else {
            errorMessage = "“\(dest.lastPathComponent)” is outside \(lib.displayName). Import into a folder of the library in this window."
            return
        }
        Task {
            let result = await lib.indexer.importFiles(urls, into: dest, movingSource: movingSource,
                                                       route: chosen == nil)
            if result.imported == 0, result.duplicates > 0, result.alreadyInLibrary == 0, result.failed == 0 {
                notify(result.duplicates == 1
                       ? "Skipped “\(result.duplicateNames.first ?? "file")” — already in library."
                       : "Skipped \(result.duplicates) duplicate files already in library.", .info)
            } else if result.imported == 0, result.alreadyInLibrary == 0, result.failed == 0 {
                notify(urls.count == 1
                       ? "There are no PDFs or images in “\(urls[0].lastPathComponent)”."
                       : "There are no PDFs or images in those folders.", .info)
            } else if result.imported == 0, result.alreadyInLibrary > 0 {
                notify(result.alreadyInLibrary == 1
                       ? "That file is already in the library, so it was indexed where it is."
                       : "Those files are already in the library, so they were indexed where they are.", .info)
            } else if result.imported == 0 {
                errorMessage = "Nothing could be imported from \(urls.count == 1 ? "that file" : "those files")."
                    + (result.failures.isEmpty ? "" : "\n\n" + result.failures.prefix(5).joined(separator: "\n"))
            } else {
                let n = result.imported
                let what = movingSource ? "Scanned" : "Imported"
                var text = "\(what) \(n) document\(n == 1 ? "" : "s")"
                if chosen == nil, lib.settings.autoRouteImports {
                    let waiting = n - result.routed
                    text += result.routed == n ? " and filed \(n == 1 ? "it" : "them all")"
                        : result.routed == 0 ? " — \(n == 1 ? "it is" : "they are") waiting in Needs Review"
                        : ", filed \(result.routed) — \(waiting) waiting in Needs Review"
                } else {
                    text += " into “\(dest.lastPathComponent)”"
                }
                notify(text + (result.failed > 0
                               ? " — \(result.failed) could not be imported. \(result.failures.first ?? "")"
                               : "."),
                       result.failed > 0 ? .warning : .success)
            }
        }
    }

    func importScanned(_ delivery: ScanDelivery, into destination: URL?) {
        let items = delivery.items
        guard !items.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var urls: [URL] = []
        let stamp = DateFormatter.filenameSafe.string(from: Date())
        for (i, item) in items.enumerated() {
            let name = items.count == 1 ? "Scan \(stamp).\(item.ext)" : "Scan \(stamp) \(i + 1).\(item.ext)"
            let url = tmp.appendingPathComponent(name)
            if (try? item.data.write(to: url)) != nil { urls.append(url) }
        }
        if !urls.isEmpty { importFiles(urls, into: destination, movingSource: true) }

        let lost = delivery.offered - urls.count
        guard lost > 0 else { return }
        ScanCapture.log.error("\(lost, privacy: .public) of \(delivery.offered, privacy: .public) capture(s) never reached the library")
        scanIncomplete(urls.isEmpty
            ? "Nothing your iPhone or iPad sent could be read. Scan it again."
            : "\(lost) of the \(delivery.offered) captures your iPhone or iPad sent could not be read. What arrived has been filed — scan the rest again.")
    }

    private static let scanTimeout = Duration.seconds(120)
    /// A beat between a capture landing and asking for the next one, while the
    /// device is still putting its scanner away. A guess, and the one number
    /// here that wants a real device: `--scantest loop` reports the round trip
    /// and whether a fire this soon is honoured at all.
    private static let scanRearm = Duration.milliseconds(800)
    private static let scanRetry = Duration.seconds(2)
    private static let scanFocusGrace = Duration.milliseconds(1500)

    private var canReceiveScans: Bool { NSApp?.isActive ?? true }

    func startContinuousScan(device: String, action: String, into destination: URL?) {
        endScanRun()
        scanSession = ScanSession(device: device, action: action, destination: destination)
        fireNextScan()
    }

    func resumeContinuousScan() {
        guard scanSession != nil else { return }
        scanSession?.resume()
        fireNextScan()
    }

    func stopContinuousScan() {
        guard let summary = endScanRun()?.summary(cancelled: false) else { return }
        notify(summary)
    }

    func scanDelivered(_ delivery: ScanDelivery) {
        follow(.delivered(documents: delivery.items.count, pages: delivery.pages))
    }

    func scanCancelled() {
        follow(.cancelled)
    }

    func scanFailed(_ message: String) {
        guard scanSession != nil else {
            errorMessage = message
            return
        }
        suspendScan(.failed)
        notify(message, .warning)
    }

    func scanIncomplete(_ message: String) {
        guard scanSession != nil else {
            errorMessage = message
            return
        }
        suspendScan(.incomplete)
        notify(message, .warning)
    }

    func appResignedActive() {
        guard scanSession?.isRunning == true else { return }
        scanFocusCheck?.cancel()
        scanFocusCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.scanFocusGrace)
            guard !Task.isCancelled, let self, self.scanSession?.isRunning == true,
                  !self.canReceiveScans else { return }
            self.suspendScan(.lostFocus)
        }
    }

    private func suspendScan(_ reason: ScanSession.Pause) {
        follow(.interrupted(reason))
    }

    private func follow(_ event: ScanSession.Event) {
        guard var session = scanSession else { return }
        scanRound?.cancel()
        scanRound = nil
        switch session.record(event) {
        case .scanAgain:
            scanSession = session
            fireNextScan(after: Self.scanRearm)
        case .wait:
            scanFocusCheck?.cancel()
            scanFocusCheck = nil
            scanSession = session
        case .end:
            endScanRun()
            if let summary = session.summary(cancelled: event == .cancelled) {
                notify(summary, .info)
            }
        }
    }

    /// Everything a run leaves running goes with it, so the toolbar is cleared
    /// and a run started next does not inherit a timer from this one.
    @discardableResult
    private func endScanRun() -> ScanSession? {
        scanRound?.cancel()
        scanRound = nil
        scanFocusCheck?.cancel()
        scanFocusCheck = nil
        defer { scanSession = nil }
        return scanSession
    }

    private func fireNextScan(after delay: Duration = .zero) {
        scanRound?.cancel()
        scanRound = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Never wake the device while another app is in front: the capture
            // would come back to a key window that is not ours and be refused,
            // and the user would have been sent to their phone for nothing.
            guard self.canReceiveScans else {
                self.suspendScan(.lostFocus)
                return
            }

            var fired = false
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: Self.scanRetry) }
                guard !Task.isCancelled,
                      let session = self.scanSession, session.isRunning else { return }
                if ScanCoordinator.shared.scan(device: session.device, action: session.action,
                                               into: session.destination) {
                    fired = true
                    break
                }
            }
            guard fired else {
                self.suspendScan(.deviceGone)
                return
            }

            try? await Task.sleep(for: Self.scanTimeout)
            guard !Task.isCancelled, self.scanSession?.isRunning == true else { return }
            self.suspendScan(.timedOut)
        }
    }
}
