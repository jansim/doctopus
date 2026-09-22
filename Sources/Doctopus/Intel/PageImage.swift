import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum PageImage {

    struct Rendered: Sendable, Equatable {
        var jpeg: Data
        var width: Int
        var height: Int
        var pageCount: Int?

        var dataURL: String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
        var kilobytes: Int { (jpeg.count + 512) / 1024 }
    }

    static let jpegQuality: CGFloat = 0.72

    private static let maxUpscale: CGFloat = 3

    static func firstPage(of url: URL, maxDimension: Int) -> Rendered? {
        guard maxDimension > 0 else { return nil }
        switch url.pathExtension.lowercased() {
        case "pdf":
            return pdfFirstPage(url, maxDimension: maxDimension)
        case "png", "jpg", "jpeg", "heic", "tiff", "tif":
            return imageFile(url, maxDimension: maxDimension)
        default:
            return nil
        }
    }

    private static func pdfFirstPage(_ url: URL, maxDimension: Int) -> Rendered? {
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0,
              let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 1, box.height > 1 else { return nil }

        // A page that declares a rotation is displayed rotated, so the long
        // edge of what the model sees is not always the long edge of the box.
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let quarterTurned = rotation == 90 || rotation == 270
        let shownWidth = quarterTurned ? box.height : box.width
        let shownHeight = quarterTurned ? box.width : box.height

        let scale = min(CGFloat(maxDimension) / max(shownWidth, shownHeight), maxUpscale)
        let w = Int((shownWidth * scale).rounded()), h = Int((shownHeight * scale).rounded())
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.concatenate(page.getDrawingTransform(.cropBox,
                                                 rect: CGRect(x: 0, y: 0, width: w, height: h),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)

        guard let image = ctx.makeImage(), let data = encode(image) else { return nil }
        return Rendered(jpeg: data, width: w, height: h, pageCount: doc.numberOfPages)
    }

    private static func imageFile(_ url: URL, maxDimension: Int) -> Rendered? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Downsampled by ImageIO rather than after the fact, so a 40-megapixel
        // scan never has to be decoded at full size. `WithTransform` applies
        // the EXIF orientation a phone photo arrives with.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              let data = encode(image) else { return nil }
        return Rendered(jpeg: data, width: image.width, height: image.height, pageCount: 1)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), data.length > 0 else { return nil }
        return data as Data
    }
}
