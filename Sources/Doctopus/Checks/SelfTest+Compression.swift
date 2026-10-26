import Foundation
import PDFKit

extension SelfTest {
    static func mixedPDFCompression(rows: [DocumentRow]) {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("doctopus-mixed-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: file) }
        guard let text = rows.compactMap({ PDFDocument(url: $0.url) }).first(where: {
            ($0.string ?? "").count > 100
        })?.page(at: 0) else {
            Check.that("a text page for mixed PDF compression", false); return
        }
        let mixed = PDFDocument()
        mixed.insert(PDFPage(), at: 0)
        for i in 1...30 {
            guard let page = text.copy() as? PDFPage else { return }
            mixed.insert(page, at: i)
        }
        guard mixed.write(to: file) else { return }
        do {
            var bytes = try Data(contentsOf: file)
            bytes.append(Data(("\n%" + String(repeating: "padding", count: 100_000) + "\n").utf8))
            try bytes.write(to: file)
            Check.that("a long mixed PDF falls below the old average-page cutoff",
                       Int64(bytes.count / mixed.pageCount) < Optimizer.Options.default.minimumPageBytes)
            let result = try Optimizer.optimize(url: file)
            let after = PDFDocument(url: file)
            Check.that("long mixed PDFs can offer an optimized version without losing pages or text",
                       result != nil && after?.pageCount == mixed.pageCount
                        && after?.page(at: 1)?.string == text.string)
        } catch { Check.that("mixed PDF compression completes", false, error.localizedDescription) }
    }

    static func externalCompression(rows: [DocumentRow]) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("doctopus-compression-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            guard let row = rows.first(where: {
                $0.ext.lowercased() == "pdf" && PDFDocument(url: $0.url)?.string?.nilIfBlank != nil
            }),
                  let document = PDFDocument(url: row.url), document.pageCount > 0 else {
                Check.that("a PDF fixture for external compression", false); return
            }
            let small = scratch.appendingPathComponent("small.pdf")
            guard document.write(to: small) else {
                Check.that("a PDF fixture for external compression can be written", false); return
            }
            let compact = try Data(contentsOf: small)
            var padded = compact
            padded.append(Data(("\n%" + String(repeating: "padding", count: 100_000) + "\n").utf8))
            let input = scratch.appendingPathComponent("input.pdf")
            let tool = scratch.appendingPathComponent("smolpdf")
            func script(_ body: String) throws {
                try ("#!/bin/sh\n" + body + "\n").write(to: tool, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
            }
            func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var options = Optimizer.Options()
            options.minimumPageBytes = 0
            try script("while [ \"$1\" != '-o' ]; do shift; done\ncp " + quoted(small.path) + " \"$2/document.pdf\"")
            Check.that("smolpdf is discovered in an explicit search path",
                       SmolPDFOptimizer.executable(searchPath: scratch.path)?.path == tool.path)
            try padded.write(to: input)
            let result = try SmolPDFOptimizer.optimize(url: input, options: options, executable: tool)
            let acceptedBytes = try Data(contentsOf: input)
            Check.that("external compression accepts smaller PDFs while preserving selectable text",
                       result != nil && acceptedBytes == compact
                           && PDFDocument(url: input)?.string == document.string)
            let blank = PDFDocument()
            for i in 0..<document.pageCount {
                let page = PDFPage()
                guard let sourcePage = document.page(at: i) else {
                    Check.that("the source PDF pages can be read", false); return
                }
                page.setBounds(sourcePage.bounds(for: .mediaBox), for: .mediaBox)
                blank.insert(page, at: i)
            }
            let missingText = scratch.appendingPathComponent("missing-text.pdf")
            guard blank.write(to: missingText) else {
                Check.that("a PDF fixture with missing text can be written", false); return
            }
            for (name, body) in [
                ("a failed external compressor", "exit 1"),
                ("invalid external output", "while [ \"$1\" != '-o' ]; do shift; done\nprintf broken > \"$2/document.pdf\""),
                ("an external compressor that produces nothing", "exit 0"),
                ("external output without enough savings", "while [ \"$1\" != '-o' ]; do shift; done\ncp \"$3\" \"$2/document.pdf\""),
                ("external output that loses selectable text", "while [ \"$1\" != '-o' ]; do shift; done\ncp " + quoted(missingText.path) + " \"$2/document.pdf\"")
            ] {
                try padded.write(to: input)
                try script(body)
                let rejected = try SmolPDFOptimizer.optimize(url: input, options: options, executable: tool)
                let unchangedBytes = try Data(contentsOf: input)
                Check.that("\(name) leaves the document untouched",
                           rejected == nil && unchangedBytes == padded)
            }
            try script("exec /bin/sleep 30")
            let timedOut = try SmolPDFOptimizer.optimize(url: input, options: options, executable: tool, timeout: 0.1)
            let timeoutBytes = try Data(contentsOf: input)
            Check.that("an external compressor that times out leaves the document untouched",
                       timedOut == nil && timeoutBytes == padded)
        } catch {
            Check.that("external compression checks complete", false, error.localizedDescription)
        }
    }
}
