import Foundation
import PDFKit
import Darwin

/// Runs an optional, locally installed compressor on a scratch copy. The live
/// document is replaced only after the same savings and readability checks.
enum SmolPDFOptimizer {
    static func executable(searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let folders = (searchPath ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        let candidates = folders.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent("smolpdf")
        } + [URL(fileURLWithPath: "/Applications/smol-pdf.app/Contents/Resources/smolpdf"),
             home.appendingPathComponent("Applications/smol-pdf.app/Contents/Resources/smolpdf")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func optimize(url: URL, options: Optimizer.Options, executable: URL,
                         timeout: TimeInterval = 120) throws -> Optimizer.Result? {
        guard url.pathExtension.lowercased() == "pdf",
              let source = PDFDocument(url: url), !source.isEncrypted, source.pageCount > 0 else { return nil }
        let fm = FileManager.default
        let originalSize = size(url)
        guard originalSize > options.minimumPageBytes else { return nil }
        let scratch = fm.temporaryDirectory.appendingPathComponent("doctopus-smol-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("document.pdf")
        let output = scratch.appendingPathComponent("output", isDirectory: true)
        try fm.copyItem(at: url, to: input)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        // Low preserves metadata and editing data. Quality and DPI then take
        // the values chosen in Doctopus; no strip or replace options are used.
        process.arguments = ["-p", "low", "-q", "\(Int((options.jpegQuality * 100).rounded()))",
                             "-r", "\(Int(options.targetDPI.rounded()))", "-o", output.path]
            + (options.grayscale ? ["-g"] : []) + [input.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        let result = output.appendingPathComponent("document.pdf")
        let newSize = size(result)
        guard newSize > 0, originalSize > 0,
              1 - Double(newSize) / Double(originalSize) >= options.minimumSaving,
              let compressed = PDFDocument(url: result), !compressed.isEncrypted,
              compressed.pageCount == source.pageCount else { return nil }
        for i in 0..<source.pageCount {
            guard let before = source.page(at: i), let after = compressed.page(at: i),
                  before.bounds(for: .mediaBox) == after.bounds(for: .mediaBox),
                  before.rotation == after.rotation,
                  (before.string ?? "") == (after.string ?? "") else { return nil }
        }
        _ = try fm.replaceItemAt(url, withItemAt: result)
        return Optimizer.Result(originalSize: originalSize, newSize: newSize, pagesRasterized: 0)
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
