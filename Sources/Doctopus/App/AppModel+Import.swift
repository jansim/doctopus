import Foundation
import AppKit

extension AppModel {

    // MARK: - Import

    var defaultImportDirectory: URL? {
        guard let lib = activeLibrary else { return nil }
        return lib.root.appendingPathComponent(lib.settings.scanDestination, isDirectory: true)
    }

    /// The folder the sidebar has selected, if any. Importing or scanning while
    /// looking at a folder puts the result in that folder and leaves it there.
    var explicitImportDirectory: URL? {
        if case .folder(let path) = selection { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Where a scan or import triggered from the center pane should land: the
    /// folder currently selected in the sidebar, if any, else the inbox.
    var contextImportDirectory: URL? {
        explicitImportDirectory ?? defaultImportDirectory
    }

    /// Brings files into a library.
    ///
    /// `destination` is where someone chose to put them — a folder's "Import
    /// Files Here…" or "Scan Documents", or a drop while that folder is
    /// selected — and they stay there. With no destination they go to the
    /// Inbox and are auto-routed from it: the one case where Doctopus moves a
    /// file on its own, and only ever a file it just brought in. A file that is
    /// already in the library is indexed where it is either way.
    func importFiles(_ urls: [URL], into destination: URL?, movingSource: Bool = false) {
        let chosen = destination ?? explicitImportDirectory
        guard let dest = chosen ?? defaultImportDirectory else {
            errorMessage = "Open a library before importing."
            return
        }
        // Files land in whichever library owns the destination, so a drop into
        // one library's folder never ends up indexed by another.
        guard let lib = libraries.first(where: { $0.owns(path: dest.path) }) ?? activeLibrary else {
            errorMessage = "Open a library before importing."
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
                // Only a folder can come to nothing: files are filtered by type
                // before they get this far.
                notify(urls.count == 1
                       ? "There are no PDFs or images in “\(urls[0].lastPathComponent)”."
                       : "There are no PDFs or images in those folders.", .info)
            } else if result.imported == 0, result.alreadyInLibrary > 0 {
                notify(result.alreadyInLibrary == 1
                       ? "That file is already in the library, so it was indexed where it is."
                       : "Those files are already in the library, so they were indexed where they are.", .info)
            } else if result.imported == 0 {
                errorMessage = "Nothing could be imported from \(urls.count == 1 ? "that file" : "those files")."
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
                notify(text + (result.failed > 0 ? " — \(result.failed) could not be read." : "."),
                       result.failed > 0 ? .warning : .success)
            }
        }
    }

    /// Writes scanner output into a folder and runs it through the pipeline.
    func importScanned(_ items: [ScannedItem], into destination: URL?) {
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
        // The scan was staged in the temporary directory by this app, so it is
        // ours to move rather than copy.
        importFiles(urls, into: destination, movingSource: true)
    }

    // MARK: - Continuous scanning

    /// How long a fired capture may go undelivered before the run pauses.
    /// Cancelling on the device tells the Mac nothing at all, so without this
    /// the toolbar would claim to be scanning until someone noticed. Long
    /// enough to line up an awkward page; short enough to not be a lie.
    private static let scanTimeout = Duration.seconds(120)
    /// A beat between a capture landing and asking for the next one, while the
    /// device is still putting its scanner away. A guess, and the one number
    /// here that wants a real device: `--scantest loop` reports the round trip
    /// and whether a fire this soon is honoured at all.
    private static let scanRearm = Duration.milliseconds(800)
    /// How long to leave the submenu to come back before believing the device
    /// is gone.
    private static let scanRetry = Duration.seconds(2)
    /// How long the app has to be out of front before a run gives up on it.
    private static let scanFocusGrace = Duration.milliseconds(1500)

    /// Whether a capture fired now could be delivered at all. It is handed to
    /// the key window's first responder, and there is no such window while
    /// another app is in front. (Nothing to ask in the headless checks, which
    /// never start a run.)
    private var canReceiveScans: Bool { NSApp?.isActive ?? true }

    func startContinuousScan(device: String, action: String, into destination: URL?) {
        scanSession = ScanSession(device: device, action: action, destination: destination)
        fireNextScan()
    }

    func resumeContinuousScan() {
        guard scanSession != nil else { return }
        scanSession?.resume()
        fireNextScan()
    }

    /// Ends the run. A capture already in flight still arrives and is still
    /// filed — the user scanned it, and it is not this app's to throw away —
    /// it just does not ask for another.
    func stopContinuousScan() {
        scanRound?.cancel()
        scanRound = nil
        scanFocusCheck?.cancel()
        scanFocusCheck = nil
        let finished = scanSession
        scanSession = nil
        guard let finished, finished.count > 0 else { return }
        notify(finished.count == 1 ? "Scanned 1 document." : "Scanned \(finished.count) documents.")
    }

    /// A capture landed. Counts it, then asks for the next one.
    func scanDelivered(_ documents: Int) {
        guard scanSession != nil else { return }
        scanRound?.cancel()
        scanRound = nil
        scanSession?.received(documents)
        guard scanSession?.isRunning == true else { return }
        fireNextScan(after: Self.scanRearm)
    }

    /// A capture arrived that could not be read. Mid-run an alert would sit in
    /// front of the next scan, so the run pauses and says so in a toast
    /// instead; on a one-off scan it is still an alert.
    func scanFailed(_ message: String) {
        guard scanSession != nil else {
            errorMessage = message
            return
        }
        suspendScan(.failed)
        notify(message, .warning)
    }

    /// Doctopus stopped being the active app. A capture is handed to the key
    /// window's first responder, so one fired now would be refused and the
    /// device would have been woken for nothing. The run pauses with its count
    /// intact, ready to carry on with one click.
    ///
    /// Confirmed after a beat rather than acted on at once: if the system's
    /// own capture UI takes the app out of front for a moment mid-round, a run
    /// would otherwise end after its first document. Nothing rests on the
    /// delay — a capture is never fired without checking `canReceiveScans`
    /// first — it only decides when to say so.
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
        scanRound?.cancel()
        scanRound = nil
        scanFocusCheck?.cancel()
        scanFocusCheck = nil
        scanSession?.suspend(reason)
    }

    /// Fires one round and waits for it. Deferred onto its own task rather
    /// than run inline because the caller is usually the delivery of the
    /// previous capture, which is still holding the pasteboard that capture
    /// came on.
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

            // The system rebuilds that submenu on its own schedule, so an
            // entry missing at this instant may only mean it has not been put
            // back yet. One retry tells a rebuild apart from a device that has
            // really left the room.
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
