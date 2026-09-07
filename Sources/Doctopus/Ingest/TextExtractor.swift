import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import NaturalLanguage

/// Extracted text plus the provenance the inspector shows.
struct ExtractedText: Sendable {
    var text: String = ""
    var confidence: Double = 0
    var words: Int = 0
    var source: String = "vision"   // pdf-layer | vision | mixed
    var pageCount: Int?
    var language: String?
    var elapsedMS: Int = 0
}

/// Pulls text out of PDFs and images.
///
/// PDFs are tried through their embedded text layer first — that is close to
/// free and lossless — and only pages that come back empty are rasterized and
/// sent through Vision. Most real-world archives are mostly digital-origin PDFs,
/// so this avoids OCR entirely for the majority of a library.
enum TextExtractor {

    /// Pages whose text layer yields fewer characters than this are treated as scans.
    private static let textLayerThreshold = 24
    /// Rasterization target. 200 DPI is the sweet spot for Vision accuracy vs. speed.
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

    // MARK: - PDF

    private static func extractPDF(_ url: URL) throws -> ExtractedText {
        guard let doc = PDFDocument(url: url) else {
            return ExtractedText(source: "unreadable")
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

        var confidences: [Double] = []
        if !scanned.isEmpty, let cg = CGPDFDocument(url as CFURL) {
            for index in scanned {
                guard let image = render(page: cg.page(at: index + 1)) else { continue }
                let ocr = recognize(image)
                pieces[index] = ocr.text
                if ocr.confidence > 0 { confidences.append(ocr.confidence) }
            }
        }

        let text = pieces.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let source: String
        if scanned.isEmpty { source = "pdf-layer" }
        else if scanned.count == count { source = "vision" }
        else { source = "mixed" }

        let confidence: Double
        if confidences.isEmpty { confidence = text.isEmpty ? 0 : 1.0 }
        else if source == "mixed" {
            let digital = Double(count - scanned.count)
            confidence = (digital + confidences.reduce(0, +)) / Double(count)
        } else {
            confidence = confidences.reduce(0, +) / Double(confidences.count)
        }

        return ExtractedText(text: text, confidence: confidence, source: source, pageCount: count)
    }

    /// Rasterizes one PDF page into a bitmap sized for OCR.
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

        // Grayscale: Vision does not need colour and this cuts memory 4x.
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

    // MARK: - Images

    private static func extractImage(_ url: URL) throws -> ExtractedText {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return ExtractedText(source: "unreadable") }
        let ocr = recognize(image)
        return ExtractedText(text: ocr.text, confidence: ocr.confidence, source: "vision", pageCount: 1)
    }

    // MARK: - Vision

    private static func recognize(_ image: CGImage) -> (text: String, confidence: Double) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return ("", 0) }

        guard let observations = request.results, !observations.isEmpty else { return ("", 0) }

        // Reading order: Vision returns observations top-to-bottom already, but
        // normalized origin is bottom-left, so sort descending on y then x.
        let sorted = observations.sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            if abs(a.midY - b.midY) > 0.012 { return a.midY > b.midY }
            return a.minX < b.minX
        }

        var lines: [String] = []
        var total = 0.0
        var n = 0
        for obs in sorted {
            guard let best = obs.topCandidates(1).first else { continue }
            lines.append(best.string)
            total += Double(best.confidence)
            n += 1
        }
        return (lines.joined(separator: "\n"), n == 0 ? 0 : total / Double(n))
    }

    // MARK: - Language

    private static func detectLanguage(_ text: String) -> String? {
        guard text.count > 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let lang = recognizer.dominantLanguage, lang != .undetermined else { return nil }
        // Only trust a confident call; short OCR noise loves to look like Romanian.
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard (hypotheses[lang] ?? 0) > 0.55 else { return nil }
        return lang.rawValue
    }
}
