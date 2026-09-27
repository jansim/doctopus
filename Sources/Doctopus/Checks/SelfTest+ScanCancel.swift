import Foundation

/// How a continuous run ends: by a cancel, a Stop, or anything else that interrupts a round.
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
                   session.record(.stopped(.cancelled)) == .end)
        Check.that("…and says how far it got",
                   session.summary(stopped: .cancelled)?.contains("Scanned 1 document") == true,
                   session.summary(stopped: .cancelled) ?? "nothing")

        let fresh = ScanSession(device: "iPhone", action: "Scan Documents", destination: nil)
        var first = fresh
        Check.that("a cancel before the first capture ends the run too",
                   first.record(.stopped(.cancelled)) == .end)
        Check.that("…and is still said, since nobody here clicked Stop",
                   first.summary(stopped: .cancelled) != nil)
        Check.that("stopping a run that scanned nothing says nothing",
                   fresh.summary(stopped: nil) == nil)

        let stops: [ScanSession.Stop] = [.lostFocus, .timedOut, .failed, .incomplete, .deviceGone]
        for stop in stops {
            var stopped = fresh
            Check.that("\(stop) ends the run rather than pausing it",
                       stopped.record(.stopped(stop)) == .end, stopped.label)
            Check.that("…and says so", stopped.summary(stopped: stop)?.hasPrefix("Scanning stopped") == true,
                       stopped.summary(stopped: stop) ?? "nothing")
        }
    }
}
