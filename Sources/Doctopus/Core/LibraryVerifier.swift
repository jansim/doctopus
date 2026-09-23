import Foundation

struct VerificationReport: Sendable {
    struct Issue: Sendable, Identifiable {
        enum Severity: String, Sendable { case error, warning, info }
        var id = UUID()
        var severity: Severity
        var title: String
        var detail: String?
    }
    var issues: [Issue] = []
    var isClean: Bool { issues.isEmpty }
    var errorsCount: Int { issues.filter { $0.severity == .error }.count }
    var warningsCount: Int { issues.filter { $0.severity == .warning }.count }
    var infoCount: Int { issues.filter { $0.severity == .info }.count }
}

enum LibraryVerifier {
    static func verify(library root: URL) async throws -> VerificationReport {
        let container = root.appendingPathComponent("library.doctopus")
        let store = try Store(directory: container)
        return try await verify(store: store)
    }

    static func verify(store: Store) async throws -> VerificationReport {
        var report = VerificationReport()
        let fm = FileManager.default

        let allDocs = try await store.verificationDocumentInfos()
        for doc in allDocs {
            if !fm.fileExists(atPath: doc.path) {
                report.issues.append(VerificationReport.Issue(
                    severity: .error,
                    title: "Missing file on disk",
                    detail: "\(doc.filename) (id #\(doc.id)) is in the database but missing on disk at \(doc.path)."
                ))
            } else {
                if let storedHash = doc.hash,
                   let currentHash = FileScanner.hash(URL(fileURLWithPath: doc.path)),
                   storedHash != currentHash {
                    report.issues.append(VerificationReport.Issue(
                        severity: .warning,
                        title: "Checksum mismatch",
                        detail: "\(doc.filename) was modified on disk outside Doctopus (hash \(storedHash.prefix(8))… vs \(currentHash.prefix(8))…)."
                    ))
                }
            }

            if doc.ocrState == .done {
                let text = (try? await store.ocrText(doc.id)) ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report.issues.append(VerificationReport.Issue(
                        severity: .warning,
                        title: "Empty extracted text",
                        detail: "\(doc.filename) has OCR marked as done, but its indexed text is empty."
                    ))
                }
            }
        }

        let scanned = FileScanner.scan(root: store.root)
        let indexedPaths = Set(allDocs.map { Store.canonical($0.path) })
        for file in scanned {
            let path = Store.canonical(file.url.path)
            if !indexedPaths.contains(path) {
                report.issues.append(VerificationReport.Issue(
                    severity: .warning,
                    title: "Unindexed file on disk",
                    detail: "\(file.url.lastPathComponent) exists on disk but is not indexed in the database."
                ))
            }
        }

        let aliases = try await store.allAliasRecords()
        for alias in aliases {
            if !fm.fileExists(atPath: alias.path) {
                report.issues.append(VerificationReport.Issue(
                    severity: .warning,
                    title: "Broken alias",
                    detail: "Alias at \(alias.path) does not exist on disk."
                ))
            }
        }

        let orphanedSuggestions = try await store.orphanedSuggestionsCount()
        if orphanedSuggestions > 0 {
            report.issues.append(VerificationReport.Issue(
                severity: .info,
                title: "Orphaned suggestions",
                detail: "\(orphanedSuggestions) tag suggestion(s) belong to deleted documents."
            ))
        }

        let orphanedIcons = try await store.orphanedIconsCount()
        if orphanedIcons > 0 {
            report.issues.append(VerificationReport.Issue(
                severity: .info,
                title: "Orphaned value icons",
                detail: "\(orphanedIcons) custom icon(s) belong to removed fields."
            ))
        }

        let orphanedFTS = try await store.orphanedFTSCount()
        if orphanedFTS > 0 {
            report.issues.append(VerificationReport.Issue(
                severity: .error,
                title: "Orphaned search rows",
                detail: "\(orphanedFTS) search index entry(ies) have no corresponding document."
            ))
        }

        return report
    }
}

extension Store {

    struct VerificationDocInfo: Sendable {
        var id: Int64
        var path: String
        var filename: String
        var hash: String?
        var ocrState: OCRState
    }

    func verificationDocumentInfos() throws -> [VerificationDocInfo] {
        try db.map("""
            SELECT id, path, filename, hash, ocr_state
            FROM documents WHERE deleted_at IS NULL
            """) {
            VerificationDocInfo(id: $0.int(0), path: absPath($0.string(1)), filename: $0.string(2),
                                hash: $0.stringOrNil(3),
                                ocrState: OCRState(rawValue: $0.int(4)) ?? .pending)
        }
    }

    func allAliasRecords() throws -> [(id: Int64, docID: Int64, path: String)] {
        try db.map("SELECT id, doc_id, path FROM aliases") { ($0.int(0), $0.int(1), absPath($0.string(2))) }
    }

    func orphanedSuggestionsCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM tag_suggestions WHERE doc_id NOT IN (SELECT id FROM documents)") {
            Int($0.int(0))
        } ?? 0
    }

    func orphanedIconsCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM value_icons WHERE field_id NOT IN (SELECT id FROM fields)") {
            Int($0.int(0))
        } ?? 0
    }

    func orphanedFTSCount() throws -> Int {
        try db.first("SELECT COUNT(*) FROM doc_fts WHERE rowid NOT IN (SELECT id FROM documents)") {
            Int($0.int(0))
        } ?? 0
    }
}
