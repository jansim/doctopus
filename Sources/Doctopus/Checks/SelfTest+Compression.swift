import Foundation
import PDFKit

extension SelfTest {
    static func externalCompression(rows: [DocumentRow]) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("doctopus-compression-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            guard let row = rows.first(where: { $0.ext.lowercased() == "pdf" }),
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
            for (name, body) in [
                ("a failed external compressor", "exit 1"),
                ("invalid external output", "while [ \"$1\" != '-o' ]; do shift; done\nprintf broken > \"$2/document.pdf\""),
                ("an external compressor that produces nothing", "exit 0")
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
