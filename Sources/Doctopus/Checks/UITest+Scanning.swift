import Foundation

extension UITest {
    /// The toolbar shows a continuous run for exactly as long as `scanSession`
    /// is set, so a cancel has to clear it and take every timer with it.
    static func cancelEndsAScanRun(_ model: AppModel) {
        let capture = ScanDelivery(offered: 1, items: [ScannedItem(data: Data(), ext: "pdf")])
        model.scanSession = ScanSession(device: "iPhone", action: "Scan Documents", destination: nil)
        model.scanDelivered(capture)
        let rearm = model.scanRound
        model.appResignedActive()
        let focusCheck = model.scanFocusCheck
        Check.that("a capture mid-run re-arms for the next one",
                   rearm != nil && model.scanSession?.count == 1)

        model.scanCancelled()
        Check.that("a cancel ends the run, so the toolbar stops showing it",
                   model.scanSession == nil)
        Check.that("…and nothing is left to fire the next round",
                   model.scanRound == nil && rearm?.isCancelled == true)
        Check.that("…or to pause a run that is gone",
                   model.scanFocusCheck == nil && focusCheck?.isCancelled == true)
        Check.that("…and the cancel is said", model.notice?.text.contains("cancelled") == true,
                   model.notice?.text ?? "nothing")

        model.scanSession = ScanSession(device: "iPhone", action: "Scan Documents", destination: nil)
        model.scanFailed("The last capture could not be read.")
        Check.that("a capture that fails pauses the run for Resume instead",
                   model.scanSession?.paused == .failed && model.scanRound == nil,
                   model.scanSession?.label ?? "no run")
        model.scanCancelled()
        Check.that("…and a cancel while paused ends it all the same", model.scanSession == nil)
        model.dismissNotice()
    }
}
