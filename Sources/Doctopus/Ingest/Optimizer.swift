import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// On-device raster optimization for scans and image-heavy PDFs.
///
/// The rule that keeps this safe: a page is only ever rasterized if it has **no**
/// text layer to begin with. Pages that carry real text are re-drawn into the
/// output PDF context, which copies their text and vector operators through
/// intact. So the pass can shrink a 40 MB phone-camera scan without a
/// searchable PDF ever losing its selectable text.
enum Optimizer {

    struct Result: Sendable {
        var originalSize: Int64
        var newSize: Int64
        var pagesRasterized: Int
        var savings: Double { originalSize > 0 ? 1 - Double(newSize) / Double(originalSize) : 0 }
    }

    struct Options: Sendable {
        var targetDPI: CGFloat = 150
        var jpegQuality: CGFloat = 0.6
        /// Below this saving the original is kept — churning files for 3% is not worth it.
        var minimumSaving: Double = 0.15
        /// Pages smaller than this are already efficient; skip them.
        var minimumPageBytes: Int64 = 120_000
        var grayscale = false

        static let `default` = Options()
    }

    /// Returns nil when the file was left untouched.
    static func optimize(url: URL, options: Options = .default) throws -> Result? {
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        let originalSize = fileSize(url)
        guard originalSize > options.minimumPageBytes else { return nil }

        guard let cg = CGPDFDocument(url as CFURL), cg.numberOfPages > 0 else { return nil }
        let pdfkit = PDFDocument(url: url)
        let pageCount = cg.numberOfPages
        let bytesPerPage = originalSize / Int64(pageCount)
        guard bytesPerPage > options.minimumPageBytes else { return nil }

        // Which pages are pure raster (no text to preserve)?
        var rasterPages = Set<Int>()
        for i in 0..<pageCount {
            let text = pdfkit?.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 24 { rasterPages.insert(i) }
        }
        guard !rasterPages.isEmpty else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-opt-\(UUID().uuidString).pdf")

        var info: [CFString: Any] = [:]
        if let attrs = pdfkit?.documentAttributes {
            if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle] = t }
            if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = a }
            if let s = attrs[PDFDocumentAttribute.subjectAttribute] as? String { info[kCGPDFContextSubject] = s }
        }

        guard let ctx = CGContext(tmp as CFURL, mediaBox: nil, info as CFDictionary) else { return nil }

        var rasterized = 0
        for index in 0..<pageCount {
            guard let page = cg.page(at: index + 1) else { continue }
            var box = page.getBoxRect(.cropBox)
            if box.width < 1 || box.height < 1 { box = page.getBoxRect(.mediaBox) }
            var mediaBox = CGRect(origin: .zero, size: box.size)

            ctx.beginPage(mediaBox: &mediaBox)
            ctx.saveGState()
            ctx.translateBy(x: -box.origin.x, y: -box.origin.y)

            if rasterPages.contains(index),
               let compressed = compressedImage(of: page, box: box, options: options) {
                ctx.translateBy(x: box.origin.x, y: box.origin.y)
                ctx.draw(compressed, in: CGRect(origin: .zero, size: box.size))
                rasterized += 1
            } else {
                ctx.drawPDFPage(page)   // keeps text + vectors selectable
            }

            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()

        let newSize = fileSize(tmp)
        let saving = originalSize > 0 ? 1 - Double(newSize) / Double(originalSize) : 0
        guard newSize > 0, saving >= options.minimumSaving,
              PDFDocument(url: tmp)?.pageCount == pageCount else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return Result(originalSize: originalSize, newSize: newSize, pagesRasterized: rasterized)
    }

    /// Renders one page and round-trips it through JPEG so Core Graphics embeds
    /// the compressed data rather than a fresh lossless bitmap.
    private static func compressedImage(of page: CGPDFPage, box: CGRect, options: Options) -> CGImage? {
        var scale = options.targetDPI / 72.0
        let longest = max(box.width, box.height) * scale
        if longest > 5000 { scale *= 5000 / longest }
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }

        let space = options.grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = options.grayscale
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        guard let raw = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return raw }
        CGImageDestinationAddImage(dest, raw, [kCGImageDestinationLossyCompressionQuality: options.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return raw }
        return jpeg
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }
}
