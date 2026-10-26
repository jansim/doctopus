import Foundation

extension Indexer {
    struct ImportSummary: Sendable {
        var imported = 0
        var routed = 0
        var alreadyInLibrary = 0
        var duplicates = 0
        var duplicateNames: [String] = []
        var failed = 0
        /// Why, one line per file that failed.
        var failures: [String] = []

        mutating func fail(_ name: String, _ reason: String) {
            failed += 1
            failures.append("“\(name)”: \(reason)")
        }
    }

    struct ImportBatch: Sendable {
        var summary: ImportSummary
        var imported: [(Int64, String)]
        var inPlace: [(Int64, String)]
        var fresh: Set<Int64>
        var route: Bool
        var scanned: Bool
    }

    @discardableResult
    func importFiles(_ urls: [URL], into destination: URL,
                     movingSource: Bool = false, route: Bool = false) async -> ImportSummary {
        let batch = await receiveFiles(urls, into: destination, movingSource: movingSource, route: route)
        return await processImport(batch)
    }

    /// A file from outside the library is copied in and the original left alone —
    /// `movingSource` is only for files the app itself produced. A file already in
    /// the library is indexed in place, never optimized or moved.
    func receiveFiles(_ urls: [URL], into destination: URL,
                      movingSource: Bool = false, route: Bool = false) async -> ImportBatch {
        var summary = ImportSummary()
        var imported: [(Int64, String)] = []
        var inPlace: [(Int64, String)] = []
        var fresh: Set<Int64> = []
        let rootPath = store.root.path
        var madeDestination = false

        for url in FileScanner.importable(urls) {
            let path = Store.canonical(url.standardizedFileURL.path)
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                guard let facts = Self.facts(URL(fileURLWithPath: path)) else {
                    summary.fail(url.lastPathComponent, "it could not be read"); continue
                }
                let r: (id: Int64, isNew: Bool, changed: Bool)
                do { r = try await store.upsertDocument(facts, origin: .inLibrary) }
                catch { summary.fail(url.lastPathComponent, error.localizedDescription); continue }
                summary.alreadyInLibrary += 1
                if r.changed { inPlace.append((r.id, path)) }
                if r.isNew { fresh.insert(r.id) }
                continue
            }
            let sourceHash = FileScanner.hash(url)
            if let sourceHash,
               (try? await store.findDuplicate(hash: sourceHash)) != nil {
                summary.duplicates += 1
                summary.duplicateNames.append(url.lastPathComponent)
                // `movingSource` files are the app's own scratch copies, so this is the only
                // chance to clean one up. A plain import's source is never touched.
                if movingSource { try? FileManager.default.removeItem(at: url) }
                continue
            }
            do {
                if !madeDestination {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    madeDestination = true
                }
                let target = Naming.uniqueURL(in: destination, filename: url.lastPathComponent)
                if movingSource {
                    try FileManager.default.moveItem(at: url, to: target)
                } else {
                    try FileManager.default.copyItem(at: url, to: target)
                }
                let origin: DocumentOrigin = movingSource ? .scanned : .imported(from: path)
                guard let facts = Self.facts(target) else {
                    summary.fail(url.lastPathComponent, "its copy could not be read"); continue
                }
                let r = try await store.upsertDocument(facts, origin: origin)
                if let sourceHash { try await store.setHash(r.id, hash: sourceHash, isOriginal: true) }
                imported.append((r.id, target.path))
                summary.imported += 1
            } catch {
                summary.fail(url.lastPathComponent, error.localizedDescription)
            }
        }
        for (id, path) in imported {
            try? await store.logProcessing(docID: id, action: .imported,
                                           detail: "Received — waiting for text extraction and analysis",
                                           rule: nil, from: nil, to: path, approved: false)
        }
        onDataChanged()
        return ImportBatch(summary: summary, imported: imported, inPlace: inPlace,
                           fresh: fresh, route: route, scanned: movingSource)
    }

    @discardableResult
    func processImport(_ batch: ImportBatch) async -> ImportSummary {
        var summary = batch.summary
        let imported = batch.imported
        let route = batch.route
        await process(documents: batch.inPlace, phase: "Indexing", isImport: false, found: batch.fresh)
        await process(documents: imported, phase: "Processing", isImport: true, route: route,
                      scanned: batch.scanned)
        if route {
            for (id, path) in imported {
                if let now = try? await store.documentPath(id), now != path { summary.routed += 1 }
            }
        }
        return summary
    }
}
