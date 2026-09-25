import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Documents arriving from a scanner or a phone.
extension SelfTest {
    static func scanCaptures() {
        let fm = FileManager.default
        print("\nSCAN CAPTURES")
        Check.that("a capture offering an image ahead of PDF is still taken as PDF",
                   ScanCapture.preferredType(among: [.tiff, .pdf, .jpeg],
                                             accepting: ScanCapture.importTypes) == .pdf)
        Check.that("a capture with no PDF on it is taken as the image it has",
                   ScanCapture.preferredType(among: [.tiff, .plainText],
                                             accepting: ScanCapture.importTypes) == .tiff)
        Check.that("a capture with nothing readable on it is declined",
                   ScanCapture.preferredType(among: [.plainText],
                                             accepting: ScanCapture.importTypes) == nil)

        func page(_ shade: Double) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: 120, height: 160, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.setFillColor(gray: shade, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
            return ctx.makeImage()
        }
        func container(_ type: UTType, _ shades: [Double]) -> Data {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                out, type.identifier as CFString, shades.count, nil) else { return Data() }
            for shade in shades {
                guard let image = page(shade) else { continue }
                CGImageDestinationAddImage(dest, image, nil)
            }
            return CGImageDestinationFinalize(dest) ? out as Data : Data()
        }

        let threePageTIFF = ScanCapture.item(from: container(.tiff, [0.2, 0.5, 0.8]), declared: .tiff)
        Check.that("a three-page capture keeps all three pages",
                   threePageTIFF?.pages == 3, "\(threePageTIFF?.pages ?? 0) page(s)")
        Check.that("…and becomes a document the index can read",
                   threePageTIFF?.ext == "pdf"
                       && threePageTIFF.flatMap { ScanCapture.pdfPageCount($0.data) } == 3)

        let onePageJPEG = ScanCapture.item(from: container(.jpeg, [0.4]), declared: .jpeg)
        Check.that("a single image is passed through as it arrived",
                   onePageJPEG?.ext == "jpg" && onePageJPEG?.pages == 1)
        Check.that("a capture that is not a document at all is declined rather than filed",
                   ScanCapture.item(from: Data("not a scan".utf8), declared: .pdf) == nil)

        let staged = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try? container(.jpeg, [0.6]).write(to: staged)
        let byReference = ScanCapture.item(from: staged.dataRepresentation, declared: .fileURL)
        Check.that("a capture handed over as a file is read rather than refused",
                   byReference?.ext == "jpg" && byReference?.pages == 1)
        Check.that("…and the file it points at is left where it is",
                   fm.fileExists(atPath: staged.path))
        try? fm.removeItem(at: staged)
        Check.that("a file reference to nothing is declined",
                   ScanCapture.item(from: staged.dataRepresentation, declared: .fileURL) == nil)

        let full = ScanDelivery(offered: 2, items: [ScannedItem(data: Data(), ext: "pdf", pages: 3),
                                                    ScannedItem(data: Data(), ext: "jpg")])
        Check.that("a delivery that lost nothing says so, and counts its pages",
                   full.isComplete && full.unread == 0 && full.pages == 4)
        let short = ScanDelivery(offered: 3, items: [ScannedItem(data: Data(), ext: "pdf")])
        Check.that("a delivery that came up short says how much is missing",
                   !short.isComplete && short.unread == 2)
    }

    static func continuousScanning() {
        print("\nCONTINUOUS SCANNING")
        var session = ScanSession(device: "iPhone", action: "Scan Documents", destination: nil)
        Check.that("a run starts with nothing scanned, and running",
                   session.count == 0 && session.isRunning, session.label)
        session.received(1, pages: 1)
        session.received(1, pages: 3)
        Check.that("each capture counts the documents it carried",
                   session.count == 2, session.label)
        Check.that("…and the pages inside them, which is what a short scan shows up in",
                   session.pages == 4 && session.label.contains("4 pages"), session.label)
        session.suspend(.lostFocus)
        Check.that("losing focus pauses the run and keeps the count",
                   !session.isRunning && session.count == 2, session.label)
        session.received(1, pages: 1)
        Check.that("a capture that lands after focus went is still filed, and the run stays paused",
                   session.count == 3 && !session.isRunning)
        session.resume()
        Check.that("resuming carries on from the count it had",
                   session.isRunning && session.count == 3)
        session.suspend(.timedOut)
        session.received(1, pages: 1)
        Check.that("a capture that arrives late un-pauses a run that had given up on it",
                   session.isRunning && session.count == 4, session.label)
        session.suspend(.deviceGone)
        Check.that("a device that left says so rather than just “paused”",
                   session.paused?.summary == "Device gone", session.label)
        session.suspend(.incomplete)
        Check.that("a run that lost part of a capture stops and says so rather than scanning on",
                   !session.isRunning && session.paused?.summary == "Incomplete", session.label)
    }
}
