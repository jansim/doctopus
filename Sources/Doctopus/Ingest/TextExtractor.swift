import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import NaturalLanguage

struct ExtractedText: Sendable {
    var text: String = ""
    var words: Int = 0
    var source: String = "vision"
    var pageCount: Int?
    var language: String?
    var elapsedMS: Int = 0
}

/// PDFs use their embedded text layer first; only pages that come back empty
/// are rasterized and sent through Vision.
enum TextExtractor {

    private static let textLayerThreshold = 24
    private static let ocrDPI: CGFloat = 200
    private static let maxPixelDimension: CGFloat = 4000

    static func extract(url: URL) throws -> ExtractedText {
        let start = DispatchTime.now().uptimeNanoseconds
        var result: ExtractedText
        switch url.pathExtension.lowercased() {
        case "pdf":
            result = try extractPDF(url)
        case "png", "jpg", "jpeg", "heic", "tiff", "tif":
            result = try extractImage(url)
        default:
            result = ExtractedText(source: "unsupported")
        }
        result.elapsedMS = Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
        result.words = result.text.split(whereSeparator: \.isWhitespace).count
        result.language = detectLanguage(result.text)
        return result
    }

    private static func extractPDF(_ url: URL) throws -> ExtractedText {
        guard let doc = PDFDocument(url: url) else {
            return ExtractedText(source: "unreadable")
        }
        // Behind a password to open (PDFKit has already tried an empty one),
        // every page reads as blank: rendering them for Vision would record a
        // scan with no words rather than a document nobody can read.
        if doc.isLocked {
            return ExtractedText(source: TextSource.locked, pageCount: doc.pageCount)
        }
        var pieces: [String] = []
        var scanned: [Int] = []
        let count = doc.pageCount

        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if layer.count >= textLayerThreshold {
                pieces.append(layer)
            } else {
                pieces.append("")
                scanned.append(i)
            }
        }

        if !scanned.isEmpty, let cg = CGPDFDocument(url as CFURL) {
            for index in scanned {
                guard let image = render(page: cg.page(at: index + 1)) else { continue }
                pieces[index] = recognize(image)
            }
        }

        let text = pieces.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let source: String
        if scanned.isEmpty { source = "pdf-layer" }
        else if scanned.count == count { source = "vision" }
        else { source = "mixed" }

        return ExtractedText(text: text, source: source, pageCount: count)
    }

    private static func render(page: CGPDFPage?) -> CGImage? {
        guard let page else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 1, box.height > 1 else { return nil }

        var scale = ocrDPI / 72.0
        let longest = max(box.width, box.height) * scale
        if longest > maxPixelDimension { scale *= maxPixelDimension / longest }

        let w = Int((box.width * scale).rounded())
        let h = Int((box.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    private static func extractImage(_ url: URL) throws -> ExtractedText {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return ExtractedText(source: "unreadable") }
        return ExtractedText(text: recognize(image), source: "vision", pageCount: 1)
    }

    private static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return "" }

        guard let observations = request.results, !observations.isEmpty else { return "" }

        // Reading order: Vision returns observations top-to-bottom already, but
        // normalized origin is bottom-left, so sort descending on y then x.
        let sorted = observations.sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            if abs(a.midY - b.midY) > 0.012 { return a.midY > b.midY }
            return a.minX < b.minX
        }

        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func detectLanguage(_ text: String) -> String? {
        guard text.count > 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let lang = recognizer.dominantLanguage, lang != .undetermined else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard (hypotheses[lang] ?? 0) > 0.55 else { return nil }
        return lang.rawValue
    }
}
