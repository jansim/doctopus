import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

struct ScannedItem: Sendable {
    var data: Data
    var ext: String
    var pages: Int = 1
}

struct ScanDelivery: Sendable {
    var offered: Int
    var items: [ScannedItem]

    var pages: Int { items.reduce(0) { $0 + $1.pages } }
    var unread: Int { max(0, offered - items.count) }
    var isComplete: Bool { unread == 0 }
}

enum ScanCapture {

    /// log show --last 1h --predicate 'subsystem == "io.doctopus"'
    static let log = Logger(subsystem: "io.doctopus", category: "scan")

    /// Concrete image types are spelled out: SwiftUI turns these into pasteboard
    /// types literally, so `.image` alone is not offered `public.jpeg`.
    static let importTypes: [UTType] = [.pdf, .jpeg, .png, .heic, .tiff, .image, .fileURL]

    /// In this app's order rather than the capture's: any raster form of a
    /// multi-page scan is one page.
    static func preferredType(among registered: [UTType], accepting preferences: [UTType]) -> UTType? {
        for preference in preferences {
            if let match = registered.first(where: { $0.conforms(to: preference) }) { return match }
        }
        return nil
    }

    static func item(from data: Data, declared: UTType) -> ScannedItem? {
        if declared.conforms(to: .fileURL) {
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL,
                  let bytes = try? Data(contentsOf: url) else { return nil }
            return item(from: bytes,
                        declared: UTType(filenameExtension: url.pathExtension) ?? .data)
        }
        if data.starts(with: Array("%PDF".utf8)) {
            guard let pages = pdfPageCount(data), pages > 0 else { return nil }
            return ScannedItem(data: data, ext: "pdf", pages: pages)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        if count > 1 {
            guard let pdf = pdf(from: source, count: count) else { return nil }
            return ScannedItem(data: pdf, ext: "pdf", pages: count)
        }

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

    private static func pdf(from source: CGImageSource, count: Int) -> Data? {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
        var initial = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initial, nil) else { return nil }

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(
                source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var box = CGRect(origin: .zero, size: pageSize(of: image, in: source, at: index))
            guard box.width >= 1, box.height >= 1 else { return nil }
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(compressed(image) ?? image, in: box)
            ctx.endPage()
        }
        ctx.closePDF()

        let data = out as Data
        guard pdfPageCount(data) == count else { return nil }
        return data
    }

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
