import Foundation

/// How a continuous run ends, as against the interruptions it waits out.
extension SelfTest {
    static func continuousScanEnds() {
        print("\nENDING A CONTINUOUS RUN")
        Check.that("a reply with nothing in it is a cancel",
                   ScanCapture.reply(offered: 0, readable: 0) == .cancelled)
        Check.that("…one offering only what cannot be read is a failure, and is answered as one",
                   ScanCapture.reply(offered: 2, readable: 0) == .unreadable)
        Check.that("…and one with anything readable is a capture",
                   ScanCapture.reply(offered: 2, readable: 1) == .capture)

        var session = ScanSession(device: "iPhone", action: "Scan Documents", destination: nil)
        Check.that("a capture asks for the next one",
                   session.record(.delivered(documents: 1, pages: 2)) == .scanAgain, session.label)
        Check.that("a cancel mid-run ends it rather than re-arming",
                   session.record(.cancelled) == .end)
        Check.that("…and says how far it got",
                   session.summary(cancelled: true)?.contains("Scanned 1 document") == true,
                   session.summary(cancelled: true) ?? "nothing")

        let fresh = ScanSession(device: "iPhone", action: "Scan Documents", destination: nil)
        var first = fresh
        Check.that("a cancel before the first capture ends the run too",
                   first.record(.cancelled) == .end)
        Check.that("…and is still said, since nobody here clicked Stop",
                   first.summary(cancelled: true) != nil)
        Check.that("stopping a run that scanned nothing says nothing",
                   fresh.summary(cancelled: false) == nil)

        let pauses: [ScanSession.Pause] = [.lostFocus, .timedOut, .failed, .incomplete, .deviceGone]
        for pause in pauses {
            var paused = fresh
            let waits = paused.record(.interrupted(pause)) == .wait && !paused.isRunning
            Check.that("\(pause) pauses the run rather than ending it", waits, paused.label)
            Check.that("…and a cancel while paused ends it",
                       paused.record(.cancelled) == .end)
        }

        var late = fresh
        _ = late.record(.interrupted(.timedOut))
        Check.that("a run that timed out resumes by itself when the capture turns up",
                   late.record(.delivered(documents: 1, pages: 1)) == .scanAgain && late.isRunning,
                   late.label)
        var away = fresh
        _ = away.record(.interrupted(.lostFocus))
        Check.that("a run that lost focus files a late capture but does not fire the next one",
                   away.record(.delivered(documents: 1, pages: 1)) == .wait
                       && !away.isRunning && away.count == 1,
                   away.label)
    }
}
