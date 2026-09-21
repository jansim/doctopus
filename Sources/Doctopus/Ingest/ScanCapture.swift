import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// One capture, decoded and ready to be written into a library.
struct ScannedItem: Sendable {
    var data: Data
    var ext: String
    /// Pages the decoded capture carries. A scan arriving one short is the
    /// whole of issue #43, so the number is carried from the moment it is
    /// known rather than recovered from the file later.
    var pages: Int = 1
}

/// What one delivery from a device amounted to: what the system offered, and
/// what survived being read.
///
/// The difference between the two is the point. A capture that cannot be read
/// is gone — the pasteboard it came on is discarded moments later and nothing
/// asks the device again — so the one thing that must not happen is filing
/// part of a scan and calling it a scan.
struct ScanDelivery: Sendable {
    /// Captures the system handed over, before any were lost.
    var offered: Int
    var items: [ScannedItem]

    var pages: Int { items.reduce(0) { $0 + $1.pages } }
    /// Captures that never became items: an unreadable type, a load that
    /// errored, a load still in flight when the wait ran out.
    var unread: Int { max(0, offered - items.count) }
    var isComplete: Bool { unread == 0 }
}

/// Turns what a device puts on the pasteboard into documents.
///
/// Decoding is kept apart from the Continuity Camera plumbing in
/// `ScanCoordinator` so the part that can lose pages is a pure function over
/// bytes, and can be checked in `--selftest` without a device in the room.
enum ScanCapture {

    /// Delivery is rare, unreproducible on demand, and over before anyone
    /// notices anything is wrong with it, so the record has to exist already:
    ///
    ///     log show --last 1h --predicate 'subsystem == "io.doctopus"'
    static let log = Logger(subsystem: "io.doctopus", category: "scan")

    /// What the app takes from a capture: PDF for document scans, and still
    /// images in whatever format the device chooses.
    ///
    /// Concrete image types are spelled out: SwiftUI turns these into pasteboard
    /// types literally, so `.image` alone is not offered `public.jpeg`. The
    /// order is the preference order `preferredType(among:accepting:)` applies.
    ///
    /// A file URL is last, and is here because `ScanCoordinator.returnTypes`
    /// tells the system this app takes one: a capture handed over as a file
    /// rather than as bytes was being refused outright, and a form the app
    /// asked for has to be a form it can read.
    static let importTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff, .image, .fileURL]

    /// The type to ask a capture for, in the order this app prefers them —
    /// which is not the order the capture happens to advertise.
    ///
    /// A multi-page document scan is a PDF and any raster form of it is one
    /// page, so taking whichever type comes first loses every page but one
    /// when a device lists an image type ahead of PDF.
    static func preferredType(among registered: [UTType], accepting preferences: [UTType]) -> UTType? {
        for preference in preferences {
            if let match = registered.first(where: { $0.conforms(to: preference) }) { return match }
        }
        return nil
    }

    /// Decodes one capture, or nil if none of it can be read.
    ///
    /// Nil rather than a shortened document is the rule here: a caller can say
    /// a capture was lost, and the user can scan it again, but nobody can spot
    /// a page that was quietly dropped on the way in.
    static func item(from data: Data, declared: UTType) -> ScannedItem? {
        // A capture can arrive as a reference to a file instead of its bytes.
        // The file is the system's, in a temporary place of its choosing, and
        // goes when the pasteboard does — so it is read here and now, and left
        // where it is.
        if declared.conforms(to: .fileURL) {
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL,
                  let bytes = try? Data(contentsOf: url) else { return nil }
            return item(from: bytes,
                        declared: UTType(filenameExtension: url.pathExtension) ?? .data)
        }
        // Read from the bytes rather than the label: a capture that says PDF
        // and is not one, or says nothing at all, is still whatever it is.
        if data.starts(with: Array("%PDF".utf8)) {
            guard let pages = pdfPageCount(data), pages > 0 else { return nil }
            return ScannedItem(data: data, ext: "pdf", pages: pages)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        if count > 1 {
            // A multi-image container — a multi-page TIFF, a HEIC sequence —
            // is a document with pages in it, and `NSBitmapImageRep(data:)`
            // would hand back the first of them as if it were the whole thing.
            guard let pdf = pdf(from: source, count: count) else { return nil }
            return ScannedItem(data: pdf, ext: "pdf", pages: count)
        }

        // The index handles PDF, JPEG and PNG; anything else a device might
        // send is transcoded rather than just renamed.
        let kind = CGImageSourceGetType(source).flatMap { UTType($0 as String) } ?? declared
        if kind.conforms(to: .png) { return ScannedItem(data: data, ext: "png") }
        if kind.conforms(to: .jpeg) { return ScannedItem(data: data, ext: "jpg") }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let jpeg = jpeg(image) else { return nil }
        return ScannedItem(data: jpeg, ext: "jpg")
    }

    static func pdfPageCount(_ data: Data) -> Int? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return nil }
        return document.numberOfPages
    }

    // MARK: - Assembly

    /// Every image in a container, one per page, as a PDF.
    ///
    /// All or nothing: a page that cannot be drawn fails the whole capture,
    /// because a document silently one page shorter is the failure this is
    /// here to prevent.
    private static func pdf(from source: CGImageSource, count: Int) -> Data? {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
        // Replaced per page below; a PDF context needs a box to be created at all.
        var initial = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initial, nil) else { return nil }

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(
                source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var box = CGRect(origin: .zero, size: pageSize(of: image, in: source, at: index))
            guard box.width >= 1, box.height >= 1 else { return nil }
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            // Round-tripped through JPEG so Core Graphics embeds the compressed
            // bytes rather than a fresh lossless bitmap per page.
            ctx.draw(compressed(image) ?? image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()

        let data = out as Data
        // Trust the file, not the loop: this is the last place the page count
        // can still be checked against what went in.
        guard pdfPageCount(data) == count else { return nil }
        return data
    }

    /// The image at its own resolution. Without a stated one, 72 dpi leaves
    /// the pixels where they are rather than guessing at a paper size.
    private static func pageSize(of image: CGImage, in source: CGImageSource, at index: Int) -> CGSize {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dpiX = properties?[kCGImagePropertyDPIWidth] as? Double ?? 0
        let dpiY = properties?[kCGImagePropertyDPIHeight] as? Double ?? 0
        let width = Double(image.width) * 72 / (dpiX > 1 ? dpiX : 72)
        let height = Double(image.height) * 72 / (dpiY > 1 ? dpiY : 72)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private static func compressed(_ image: CGImage) -> CGImage? {
        guard let data = jpeg(image, quality: 0.85),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func jpeg(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
