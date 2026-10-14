import Foundation

struct IndexProgress: Sendable, Equatable {
    var phase: String = ""
    var done = 0
    var total = 0
    var current: String?
    var isRunning: Bool { total > 0 && done < total }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Orchestrates scan → hash → OCR → analyze → enrich → optimize → route.
/// Concurrency is bounded: oversubscribing OCR slows the machine, not the batch.
actor Indexer {
    let store: Store
    let intelligence: Intelligence
    let classifier = DocumentClassifier()
    var settings: AppSettings
    var cancelled = false
    private var running = false

    let onProgress: @Sendable (IndexProgress) -> Void
    let onDataChanged: @Sendable () -> Void
    /// A scan that could not do its job, said rather than passed off as a clean one.
    private let onProblem: @Sendable (String) -> Void

    // Indexer+Pipeline
    var languageCache: String??
    var entityRuleCache: [Entity]?

    init(store: Store, intelligence: Intelligence, settings: AppSettings,
         onProgress: @escaping @Sendable (IndexProgress) -> Void,
         onDataChanged: @escaping @Sendable () -> Void,
         onProblem: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.intelligence = intelligence
        self.settings = settings
        self.onProgress = onProgress
        self.onDataChanged = onDataChanged
        self.onProblem = onProblem
    }

    func update(settings: AppSettings) async {
        self.settings = settings
        languageCache = nil
        entityRuleCache = nil
        await intelligence.update(settings: settings)
    }
    func cancel() { cancelled = true }
    var isRunning: Bool { running }

    @discardableResult
    func indexAll() async -> Int? {
        guard !running else { return nil }
        running = true
        cancelled = false
        defer { running = false; onProgress(IndexProgress()); onDataChanged() }

        onProgress(IndexProgress(phase: "Scanning", done: 0, total: 1))

        let name = store.root.lastPathComponent
        // A new library's first pass is its existing archive, not new arrivals.
        // An index that cannot say how much it holds cannot say which that is.
        let firstPass: Bool
        let upserted: [(id: Int64, path: String, isNew: Bool, changed: Bool)]
        var scan = FileScanner.scan(root: store.root)
        let found = scan.found.map { Self.facts($0) }
        do {
            firstPass = try await store.documentCount() == 0
            if cancelled { return nil }
            await relinkMoved(found)
            upserted = try await store.upsertDocuments(found)
        } catch {
            onProblem("Could not index \(name): \(error.localizedDescription)")
            return nil
        }
        var toProcess = upserted.filter(\.changed).map { ($0.id, $0.path) }
        let fresh = firstPass ? [] : Set(upserted.filter(\.isNew).map(\.id))

        var skipped: [String] = []
        // A library that reads as empty while its index still holds documents is
        // far likelier unmounted or unreadable than emptied, so it is not taken
        // at its word. A file deleted for real is still heard by the watcher.
        let indexed = (try? await store.allDocumentIDs(limit: 1))?.isEmpty == false
        let readAsEmpty = scan.found.isEmpty && indexed
        if readAsEmpty { scan.unreadable.append(store.root) }
        do { _ = try await store.reconcileMissing(scan) }
        catch { skipped.append("marking files that are gone as missing (\(error.localizedDescription))") }
        // Forgetting a document forgets everything anyone ever typed about it,
        // so it waits for a scan that saw the whole library.
        if scan.isComplete {
            do {
                _ = try await store.purgeMissing()
                _ = try await store.purgeDeleted()
            } catch { skipped.append("forgetting files gone for good (\(error.localizedDescription))") }
        } else {
            onProblem(Self.unreadableProblem(scan, in: store.root, readAsEmpty: readAsEmpty))
        }
        do {
            let pending = try await store.documentIDsNeedingOCR()
            let known = Set(toProcess.map(\.0))
            toProcess.append(contentsOf: pending.filter { !known.contains($0.id) }.map { ($0.id, $0.path) })
        } catch { skipped.append("finding documents still waiting for their text (\(error.localizedDescription))") }
        if !skipped.isEmpty {
            onProblem("Indexing \(name) skipped " + skipped.joined(separator: "; ") + ".")
        }

        onDataChanged()
        return await process(documents: toProcess, phase: "Indexing", isImport: false, found: fresh)
    }

    /// `rescanning`: folders FSEvents could only say *something* changed in.
    /// Those are walked again and reconciled, as a full scan would — whatever
    /// was deleted in there went by without an event of its own.
    func handleChanges(paths: [String], rescanning: [String] = []) async {
        let rootPrefix = store.root.path + "/"
        let fm = FileManager.default

        var toProcess: [(Int64, String)] = []
        var fresh: Set<Int64> = []
        var touched = false

        for directory in rescanning {
            let path = Store.canonical(directory)
            guard path == store.root.path || path.hasPrefix(rootPrefix),
                  !FileScanner.isInsideLibraryContainer(URL(fileURLWithPath: path)) else { continue }
            // A root that is gone is the library leaving, not its documents.
            guard fm.fileExists(atPath: store.root.path) else { continue }
            await resync(directory: URL(fileURLWithPath: path), into: &toProcess, fresh: &fresh)
            touched = true
        }

        for path in paths {
            guard path == store.root.path || path.hasPrefix(rootPrefix) else { continue }
            if FileScanner.isInsideLibraryContainer(URL(fileURLWithPath: path)) { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

            if isDir.boolValue {
                await rescan(directory: URL(fileURLWithPath: path), into: &toProcess, fresh: &fresh)
                touched = true
                continue
            }

            let url = URL(fileURLWithPath: path)
            guard FileScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }

            if !exists {
                try? await store.markMissing(path: path)
                touched = true
                continue
            }

            guard let v = try? url.resourceValues(forKeys: Set(Self.factKeys + [.isAliasFileKey])),
                  v.isAliasFile != true else { continue }
            let facts = Self.facts(path: path, v)

            // After a file-ID relink the upsert still runs, to catch an edit made on the way.
            if (try? await store.relinkByFileID(facts)) == nil,
               let hash = FileScanner.hash(url),
               (try? await store.relinkByHash(hash: hash, newPath: path)) != nil {
                touched = true
                continue
            }

            if let result = try? await store.upsertDocument(facts, origin: .inLibrary), result.changed {
                toProcess.append((result.id, path))
                if result.isNew { fresh.insert(result.id) }
            }
            touched = true
        }

        if touched { onDataChanged() }
        if !toProcess.isEmpty {
            await process(documents: toProcess, phase: "Indexing", isImport: false, found: fresh)
        }
    }

    private func rescan(directory: URL, into toProcess: inout [(Int64, String)],
                        fresh: inout Set<Int64>) async {
        let found = FileScanner.scan(root: directory).found.map { Self.facts($0) }
        await relinkMoved(found)
        for facts in found {
            if let r = try? await store.upsertDocument(facts, origin: .inLibrary), r.changed {
                toProcess.append((r.id, facts.path))
                if r.isNew { fresh.insert(r.id) }
            }
        }
    }

    private func resync(directory: URL, into toProcess: inout [(Int64, String)],
                        fresh: inout Set<Int64>) async {
        var isDir: ObjCBool = false
        let scan = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) && isDir.boolValue
            ? FileScanner.scan(root: directory) : FileScanner.Scan()
        let found = scan.found.map { Self.facts($0) }
        await relinkMoved(found)
        for facts in found {
            if let r = try? await store.upsertDocument(facts, origin: .inLibrary), r.changed {
                toProcess.append((r.id, facts.path))
                if r.isNew { fresh.insert(r.id) }
            }
        }
        do { _ = try await store.reconcileMissing(scan, within: directory.path) }
        catch { onProblem("Could not check \(directory.lastPathComponent) for removed files: \(error.localizedDescription)") }
        if !scan.isComplete {
            onProblem(Self.unreadableProblem(scan, in: store.root, readAsEmpty: false))
        }
    }

    /// Before any upsert, so a new file at an old path cannot claim the moved row.
    private func relinkMoved(_ found: [Store.FileFacts]) async {
        for facts in found where facts.fileID != nil {
            _ = try? await store.relinkByFileID(facts)
        }
    }

    /// `found`: new to the index, but already in the library.
    @discardableResult
    func process(documents: [(Int64, String)], phase: String, isImport: Bool,
                 route: Bool = false, scanned: Bool = false, found: Set<Int64> = []) async -> Int {
        guard !documents.isEmpty else { return 0 }
        let total = documents.count
        var done = 0
        onProgress(IndexProgress(phase: phase, done: 0, total: total))

        let width = settings.effectiveConcurrency
        var iterator = documents.makeIterator()

        await withTaskGroup(of: String?.self) { group in
            var inFlight = 0
            while inFlight < width, let next = iterator.next() {
                group.addTask { [weak self] in
                    await self?.pipeline(id: next.0, path: next.1, isImport: isImport, route: route,
                                         scanned: scanned,
                                         isNew: found.contains(next.0))
                }
                inFlight += 1
            }
            while let finished = await group.next() {
                done += 1
                onProgress(IndexProgress(phase: phase, done: done, total: total, current: finished))
                if done % 8 == 0 { onDataChanged() }
                if cancelled { group.cancelAll(); break }
                if let next = iterator.next() {
                    group.addTask { [weak self] in
                        await self?.pipeline(id: next.0, path: next.1, isImport: isImport, route: route,
                                         scanned: scanned,
                                         isNew: found.contains(next.0))
                    }
                }
            }
        }
        onProgress(IndexProgress())
        onDataChanged()
        return done
    }

    private static let factKeys: [URLResourceKey] =
        [.fileSizeKey, .contentModificationDateKey, .creationDateKey] + FileScanner.identityKeys

    static func unreadableProblem(_ scan: FileScanner.Scan, in root: URL, readAsEmpty: Bool) -> String {
        let name = root.lastPathComponent
        if readAsEmpty {
            return "\(name) looked empty, although documents are indexed in it. "
                + "Nothing was marked missing; if the folder is on a drive or a share, check that it is connected."
        }
        let places = scan.unreadable.map { url in
            url.path == root.path ? name : String(url.path.dropFirst(root.path.count + 1))
        }
        let shown = places.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            + (places.count > 3 ? " and \(places.count - 3) more" : "")
        return "Doctopus could not read \(shown) in \(name). "
            + "Documents there were left as they were, and nothing will be forgotten until it can read them again."
    }

    static func facts(_ url: URL) -> Store.FileFacts? {
        guard let v = try? url.resourceValues(forKeys: Set(factKeys)) else { return nil }
        return facts(path: url.path, v)
    }

    static func facts(path: String, _ v: URLResourceValues) -> Store.FileFacts {
        Store.FileFacts(path: path, size: Int64(v.fileSize ?? 0),
                        mtime: v.contentModificationDate ?? Date(),
                        created: v.creationDate ?? Date(),
                        fileID: FileScanner.fileID(v))
    }

    static func facts(_ f: FileScanner.Found) -> Store.FileFacts {
        Store.FileFacts(path: f.url.path, size: f.size, mtime: f.mtime,
                        created: f.created, fileID: f.fileID)
    }
}
