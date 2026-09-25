import Foundation

/// Bringing files in from outside the library.
extension SelfTest {
    static func importAFile(store: Store, indexer: Indexer, settings: AppSettings, root: URL,
                            rows: [DocumentRow]) async {
        print("\nIMPORT (a file from outside the library)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-import-\(UUID().uuidString).pdf")
        if let sample = rows.first, var data = try? Data(contentsOf: sample.url) {
            data.append(Data("\n% unique-\(UUID().uuidString)\n".utf8))
            try? data.write(to: outside)
            var quiet = settings
            quiet.autoRouteImports = false
            quiet.deriveWhenNoRule = false
            await indexer.update(settings: quiet)
            await indexer.importFiles([outside], into: root.appendingPathComponent("Inbox"))
            let copied = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                          sort: .added, ascending: false)) ?? [])
                .first { $0.filename == outside.lastPathComponent }
            print("  imported \(outside.lastPathComponent) → \(copied?.directory ?? "nowhere")")
            Check.that("importing copies and leaves the original alone",
                       FileManager.default.fileExists(atPath: outside.path) && copied != nil)

            let source = Store.canonical(outside.standardizedFileURL.path)
            let importedOrigin = try? await store.history(for: copied?.doc ?? 0, limit: 10_000)
                .last { $0.action == .added }
            Check.that("an import records where it was imported from",
                       importedOrigin?.fromPath == source,
                       importedOrigin?.detail ?? "no origin")
            let scannedOrigin = try? await store.history(for: sample.doc, limit: 10_000)
                .last { $0.action == .added }
            Check.that("a file first seen in the library records where it was",
                       scannedOrigin?.detail == "In library at \(store.relPath(sample.url.path))",
                       scannedOrigin?.detail ?? "no origin")

            let dupResult = await indexer.importFiles([outside], into: root.appendingPathComponent("Inbox"))
            Check.that("re-importing a byte-identical document is skipped as duplicate",
                       dupResult.imported == 0 && dupResult.duplicates == 1)

            if let copied {
                try? FileManager.default.removeItem(at: copied.url)
                try? await store.deleteDocument(copied.doc)
            }
            try? FileManager.default.removeItem(at: outside)
        }
    }

    static func importAFolder(store: Store, indexer: Indexer, root: URL, rows: [DocumentRow]) async {
        print("\nIMPORT (a folder from outside the library)")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("doctopus-folder-\(UUID().uuidString)", isDirectory: true)
        let deeper = folder.appendingPathComponent("Receipts/2025", isDirectory: true)
        try? FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        let tag = UUID().uuidString.prefix(6)
        let top = folder.appendingPathComponent("top-\(tag).pdf")
        let nested = deeper.appendingPathComponent("nested-\(tag).pdf")
        if rows.count >= 2, var one = try? Data(contentsOf: rows[0].url),
           var two = try? Data(contentsOf: rows[1].url) {
            one.append(Data("\n% unique-top-\(tag)\n".utf8))
            two.append(Data("\n% unique-nested-\(tag)\n".utf8))
            try? one.write(to: top)
            try? two.write(to: nested)
            try? Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
            try? one.write(to: deeper.appendingPathComponent(".hidden-\(tag).pdf"))

            let inbox = root.appendingPathComponent("Inbox")
            let result = await indexer.importFiles([folder], into: inbox)
            let arrived = ((try? await store.listDocuments(selection: .all, query: SearchQuery(""),
                                                           sort: .added, ascending: false)) ?? [])
                .filter { $0.filename.contains(tag) }
            print("  imported \(result.imported): \(arrived.map(\.filename).sorted().joined(separator: ", "))")
            Check.that("importing a folder brings in the documents at every depth, and only those",
                       result.imported == 2 && arrived.count == 2
                           && arrived.allSatisfy { $0.directory == Store.canonical(inbox.path) },
                       "\(result.imported) imported, \(arrived.count) indexed")
            Check.that("importing a folder leaves the folder alone",
                       [top, nested].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            for row in arrived {
                try? FileManager.default.removeItem(at: row.url)
                try? await store.deleteDocument(row.doc)
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
